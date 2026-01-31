"""
Netboot Server - Authentication Service

Handles PXE boot authentication with two modes:
- local: Validates against a local users.yml file (bcrypt hashed passwords)
- ldap:  Validates against an LDAP/Active Directory server

Runs on port 8081 (proxied by nginx at /auth/).
When authentication succeeds, returns the iPXE menu script.
When it fails, returns HTTP 401.
"""

import os
import logging
from pathlib import Path

import yaml
import bcrypt
from flask import Flask, request, Response

app = Flask(__name__)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("netboot-auth")

CONFIG_PATH = os.environ.get("AUTH_CONFIG_PATH", "/etc/netboot/auth.yml")
USERS_PATH = os.environ.get("AUTH_USERS_PATH", "/etc/netboot/users.yml")
IPXE_MENU_PATH = os.environ.get("IPXE_MENU_PATH", "/srv/ipxe/menu.ipxe")


def escape_ldap_filter(value):
    """
    Escape special characters in LDAP filter values to prevent injection.

    Per RFC 4515, these characters must be escaped:
      - \\ (backslash)  → \\5c
      - *  (asterisk)   → \\2a
      - (  (open paren) → \\28
      - )  (close paren)→ \\29
      - \\0 (NUL)       → \\00
    """
    if not value:
        return value
    # Order matters: escape backslash first
    value = value.replace("\\", "\\5c")
    value = value.replace("*", "\\2a")
    value = value.replace("(", "\\28")
    value = value.replace(")", "\\29")
    value = value.replace("\0", "\\00")
    return value


def load_config():
    """Load authentication configuration from auth.yml."""
    with open(CONFIG_PATH, "r") as f:
        return yaml.safe_load(f)


def load_local_users():
    """Load local users from users.yml."""
    with open(USERS_PATH, "r") as f:
        data = yaml.safe_load(f)
    return data.get("users", [])


def authenticate_local(username, password):
    """Authenticate against local users.yml file."""
    users = load_local_users()
    for user in users:
        if user["username"] == username:
            stored_hash = user["password_hash"].encode("utf-8")
            if bcrypt.checkpw(password.encode("utf-8"), stored_hash):
                logger.info("Local auth success: %s", username)
                return True
            logger.warning("Local auth failed (bad password): %s", username)
            return False
    logger.warning("Local auth failed (user not found): %s", username)
    return False


def authenticate_ldap(username, password, ldap_config):
    """
    Authenticate against an LDAP/Active Directory server.

    Supports two modes:
    - direct_bind: Constructs the user DN from a pattern and attempts to bind
    - search_bind: Binds with a service account, searches for the user, then re-binds
    """
    try:
        import ldap3
        from ldap3 import Server, Connection, ALL, SUBTREE
        from ldap3.core.exceptions import LDAPBindError, LDAPException
    except ImportError:
        logger.error("ldap3 package not installed. Install with: pip install ldap3")
        return False

    server_url = ldap_config["server"]
    use_ssl = ldap_config.get("use_ssl", server_url.startswith("ldaps://"))
    port = ldap_config.get("port", 636 if use_ssl else 389)

    server = Server(server_url, port=port, use_ssl=use_ssl, get_info=ALL)

    bind_mode = ldap_config.get("bind_mode", "search_bind")

    if bind_mode == "direct_bind":
        # Construct the user DN from the pattern and try to bind directly
        # Escape username to prevent LDAP injection
        safe_username = escape_ldap_filter(username)
        user_dn = ldap_config["user_dn_pattern"].format(username=safe_username)
        try:
            conn = Connection(server, user=user_dn, password=password, auto_bind=True)
            conn.unbind()
            logger.info("LDAP direct_bind auth success: %s", username)
            return True
        except LDAPBindError:
            logger.warning("LDAP direct_bind auth failed: %s", username)
            return False

    elif bind_mode == "search_bind":
        # Step 1: Bind with service account
        service_dn = ldap_config["service_account"]["bind_dn"]
        service_password = ldap_config["service_account"]["bind_password"]

        try:
            conn = Connection(server, user=service_dn, password=service_password, auto_bind=True)
        except LDAPBindError:
            logger.error("LDAP service account bind failed")
            return False

        # Step 2: Search for the user
        # Escape username to prevent LDAP injection
        safe_username = escape_ldap_filter(username)
        search_base = ldap_config["search_base"]
        search_filter = ldap_config["search_filter"].format(username=safe_username)

        conn.search(
            search_base=search_base,
            search_filter=search_filter,
            search_scope=SUBTREE,
            attributes=["distinguishedName"],
        )

        if not conn.entries:
            logger.warning("LDAP search found no user: %s", username)
            conn.unbind()
            return False

        user_dn = str(conn.entries[0].distinguishedName)
        conn.unbind()

        # Step 3: Bind as the found user to validate password
        try:
            user_conn = Connection(server, user=user_dn, password=password, auto_bind=True)
            user_conn.unbind()
            logger.info("LDAP search_bind auth success: %s", username)
            return True
        except LDAPBindError:
            logger.warning("LDAP search_bind auth failed (bad password): %s", username)
            return False

    else:
        logger.error("Unknown LDAP bind_mode: %s", bind_mode)
        return False


def authenticate(username, password):
    """Route authentication to the configured backend."""
    config = load_config()
    mode = config.get("mode", "local")

    if not username or not password:
        logger.warning("Auth attempt with empty credentials")
        return False

    if mode == "local":
        return authenticate_local(username, password)
    elif mode == "ldap":
        return authenticate_ldap(username, password, config["ldap"])
    elif mode == "both":
        # Try local first, fall back to LDAP
        if authenticate_local(username, password):
            return True
        return authenticate_ldap(username, password, config["ldap"])
    else:
        logger.error("Unknown auth mode: %s", mode)
        return False


@app.route("/auth/boot.ipxe", methods=["POST"])
def auth_boot():
    """
    iPXE authentication endpoint.

    Expects POST with 'username' and 'password' form parameters.
    Returns the iPXE menu script on success, 401 on failure.
    """
    username = request.form.get("username", "")
    password = request.form.get("password", "")

    client_ip = request.remote_addr
    logger.info("Auth attempt from %s for user: %s", client_ip, username)

    if authenticate(username, password):
        try:
            menu_content = Path(IPXE_MENU_PATH).read_text()
            return Response(menu_content, mimetype="text/plain")
        except FileNotFoundError:
            logger.error("Menu file not found: %s", IPXE_MENU_PATH)
            return Response("#!ipxe\necho ERROR: Menu not found.\nshell\n", mimetype="text/plain")

    return Response(
        "#!ipxe\necho Authentication failed.\nsleep 3\n",
        status=401,
        mimetype="text/plain",
    )


@app.route("/health", methods=["GET"])
def health():
    """Health check endpoint."""
    return Response("ok", mimetype="text/plain")


if __name__ == "__main__":
    logger.info("Netboot Auth Service starting on port 8081")
    logger.info("Auth config: %s", CONFIG_PATH)
    logger.info("Users file: %s", USERS_PATH)
    app.run(host="0.0.0.0", port=8081)
