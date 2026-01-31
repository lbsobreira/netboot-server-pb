FROM alpine:3.21

# Install runtime dependencies
RUN apk add --no-cache \
    dnsmasq \
    nginx \
    python3 \
    py3-pip \
    py3-bcrypt \
    py3-yaml \
    supervisor \
    curl \
    samba \
    p7zip \
    wimlib \
    unfs3 \
    rpcbind \
    zstd \
    cpio

# Create app directory for auth service
WORKDIR /opt/netboot/auth

# Install Python dependencies (use virtual env to avoid system package conflicts)
COPY auth/requirements.txt .
RUN python3 -m venv /opt/netboot/venv && \
    /opt/netboot/venv/bin/pip install --no-cache-dir -r requirements.txt

# Copy auth service code
COPY auth/ .

# Copy scripts into the container (for future in-container preparation)
COPY scripts/ /opt/netboot/scripts/
RUN chmod +x /opt/netboot/scripts/*.sh && \
    chmod +x /opt/netboot/scripts/lib/*.sh 2>/dev/null || true

# Create directories
RUN mkdir -p \
    /srv/tftp \
    /srv/ipxe \
    /srv/images \
    /etc/netboot \
    /var/log/supervisor \
    /run/nginx \
    /run/samba

# Copy supervisor configuration
COPY config/supervisord.conf /etc/supervisord.conf

# Expose ports (documentation only — using host networking)
# UDP 67/68 - DHCP proxy
# UDP 69   - TFTP
# TCP 445  - SMB (Samba)
# TCP 8080 - HTTP (nginx)
# TCP 8081 - Auth service (internal)
# TCP/UDP 2049 - NFS (unfs3 userspace server)
EXPOSE 67/udp 68/udp 69/udp 445 2049 2049/udp 8080 8081

ENTRYPOINT ["/opt/netboot/scripts/entrypoint.sh"]
