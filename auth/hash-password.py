"""
Utility to generate bcrypt password hashes for users.yml.

Usage:
    python hash-password.py
    python hash-password.py <password>
"""

import sys
import bcrypt
import getpass


def hash_password(password):
    """Generate a bcrypt hash for the given password."""
    salt = bcrypt.gensalt(rounds=12)
    hashed = bcrypt.hashpw(password.encode("utf-8"), salt)
    return hashed.decode("utf-8")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        pwd = sys.argv[1]
    else:
        pwd = getpass.getpass("Enter password to hash: ")

    print(hash_password(pwd))
