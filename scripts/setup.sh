#!/bin/bash
# =============================================================================
# Netboot Server - Setup Script
# =============================================================================
# Downloads iPXE bootloader files and prepares the environment.
# Run this once before starting the service for the first time.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TFTP_DIR="$PROJECT_DIR/tftp"

echo "==========================================="
echo "  Netboot Server - Initial Setup"
echo "==========================================="
echo ""

# ---------------------------------------------------------------------------
# Step 1: Download iPXE bootloader files
# ---------------------------------------------------------------------------
echo "[1/4] Downloading iPXE bootloader files..."

# undionly.kpxe — for BIOS/Legacy boot
if [ ! -f "$TFTP_DIR/undionly.kpxe" ]; then
    echo "  Downloading undionly.kpxe (BIOS)..."
    curl -sSL -o "$TFTP_DIR/undionly.kpxe" \
        "https://boot.ipxe.org/undionly.kpxe"
    echo "  Done."
else
    echo "  undionly.kpxe already exists, skipping."
fi

# ipxe.efi — for UEFI boot
if [ ! -f "$TFTP_DIR/ipxe.efi" ]; then
    echo "  Downloading ipxe.efi (UEFI)..."
    curl -sSL -o "$TFTP_DIR/ipxe.efi" \
        "https://boot.ipxe.org/ipxe.efi"
    echo "  Done."
else
    echo "  ipxe.efi already exists, skipping."
fi

echo ""

# ---------------------------------------------------------------------------
# Step 2: Create .env if it doesn't exist
# ---------------------------------------------------------------------------
echo "[2/4] Checking environment configuration..."

if [ ! -f "$PROJECT_DIR/.env" ]; then
    echo "  Creating .env from .env.example..."
    cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
    echo "  IMPORTANT: Edit .env and set TFTP_SERVER_IP to your host's LAN IP."
    echo "  You can find it with: ip -4 addr show | grep inet"
else
    echo "  .env already exists, skipping."
fi

echo ""

# ---------------------------------------------------------------------------
# Step 3: Update dnsmasq.conf with the server IP from .env
# ---------------------------------------------------------------------------
echo "[3/4] Updating configuration with server IP..."

# Source the .env file to get TFTP_SERVER_IP
if [ -f "$PROJECT_DIR/.env" ]; then
    source "$PROJECT_DIR/.env"
fi

SERVER_IP="${TFTP_SERVER_IP:-192.168.1.100}"
HTTP_PORT_VAL="${HTTP_PORT:-8080}"
IFACE="${DHCP_INTERFACE:-eth0}"

# Update dnsmasq.conf with actual values
DNSMASQ_CONF="$PROJECT_DIR/config/dnsmasq/dnsmasq.conf"
if [ -f "$DNSMASQ_CONF" ]; then
    # Detect subnet from the server IP (assume /24)
    SUBNET=$(echo "$SERVER_IP" | sed 's/\.[0-9]*$/.0/')

    # Update interface
    sed -i "s/^interface=.*/interface=$IFACE/" "$DNSMASQ_CONF"

    # Update proxy DHCP range
    sed -i "s|^dhcp-range=.*,proxy|dhcp-range=$SUBNET,proxy|" "$DNSMASQ_CONF"

    # Update iPXE chain URL with actual server IP and port
    sed -i "s|dhcp-boot=tag:ipxe,http://[^/]*/|dhcp-boot=tag:ipxe,http://$SERVER_IP:$HTTP_PORT_VAL/|" "$DNSMASQ_CONF"

    echo "  Updated dnsmasq.conf:"
    echo "    Interface:  $IFACE"
    echo "    Subnet:     $SUBNET"
    echo "    Server IP:  $SERVER_IP"
    echo "    HTTP Port:  $HTTP_PORT_VAL"
fi

echo ""

# ---------------------------------------------------------------------------
# Step 4: Summary
# ---------------------------------------------------------------------------
echo "[4/4] Setup complete!"
echo ""
echo "==========================================="
echo "  Files downloaded to: $TFTP_DIR/"
ls -la "$TFTP_DIR/" 2>/dev/null | grep -E 'kpxe|efi' || echo "  (no bootloader files found)"
echo ""
echo "  Next steps:"
echo "    1. Edit .env and verify TFTP_SERVER_IP=$SERVER_IP is correct"
echo "    2. Change default password in config/auth/users.yml"
echo "    3. Run: docker compose up -d --build"
echo "    4. Test with a Hyper-V VM set to network boot"
echo "==========================================="
