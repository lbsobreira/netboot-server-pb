#!/bin/bash
# =============================================================================
# Netboot Server - TrueNAS Scale ISO Extraction Functions
# =============================================================================
# Handles TrueNAS Scale ISO preparation for PXE boot.
# TrueNAS Scale is Debian-based with live-boot, can use NFS or HTTP fetch.
# Source this file from prepare-images.sh.
#
# Required variables (set by parent script):
#   IMAGES_DIR, SERVER_IP
#
# Required functions (from logging-and-utils.sh):
#   info, warn, error
#
# TrueNAS live-boot has a bug: the ip= parameter (STATICIP) is parsed but
# never used for fetch= network boot. The networking script always uses DHCP.
# We work around this by creating a supplementary initrd that configures
# networking early, before live-boot's scripts run.
# =============================================================================

# ---------------------------------------------------------------------------
# Create supplementary initrd for early network configuration
# ---------------------------------------------------------------------------
create_network_initrd() {
    local dest="$1"
    local work_dir="/tmp/truenas-net-initrd-$$"

    info "  Creating network configuration initrd..."

    mkdir -p "$work_dir/scripts/init-premount"

    # Create the ORDER file (specifies script execution order)
    cat > "$work_dir/scripts/init-premount/ORDER" << 'ORDEREOF'
/scripts/init-premount/static-net
ORDEREOF

    # Create the network configuration script
    # This runs BEFORE live-boot's networking, allowing us to configure
    # static IP for the fetch= operation
    cat > "$work_dir/scripts/init-premount/static-net" << 'SCRIPTEOF'
#!/bin/sh
# Early network configuration for TrueNAS PXE boot
# Runs before live-boot's networking scripts

PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0;; esac

# Parse parameters from kernel cmdline
# Format: staticip=DEVICE:IP:NETMASK:GATEWAY[:DNS]
# Format: updateurl=http://server:port/path/to/TrueNAS-SCALE.update
for x in $(cat /proc/cmdline); do
    case $x in
        staticip=*) STATICIP="${x#staticip=}" ;;
        updateurl=*) UPDATEURL="${x#updateurl=}" ;;
    esac
done

if [ -n "$STATICIP" ]; then
    DEVICE=$(echo "$STATICIP" | cut -d: -f1)
    IP=$(echo "$STATICIP" | cut -d: -f2)
    NETMASK=$(echo "$STATICIP" | cut -d: -f3)
    GATEWAY=$(echo "$STATICIP" | cut -d: -f4)
    DNS=$(echo "$STATICIP" | cut -d: -f5)

    # Wait for device to appear
    for i in 1 2 3 4 5; do
        [ -e "/sys/class/net/$DEVICE" ] && break
        sleep 1
    done

    if [ -e "/sys/class/net/$DEVICE" ]; then
        echo "Configuring $DEVICE with static IP $IP..."

        # Bring up interface
        ip link set "$DEVICE" up

        # Calculate CIDR prefix from netmask
        case "$NETMASK" in
            255.255.255.0)   PREFIX="24" ;;
            255.255.0.0)     PREFIX="16" ;;
            255.0.0.0)       PREFIX="8" ;;
            255.255.255.128) PREFIX="25" ;;
            255.255.255.192) PREFIX="26" ;;
            255.255.255.224) PREFIX="27" ;;
            255.255.255.240) PREFIX="28" ;;
            255.255.255.248) PREFIX="29" ;;
            255.255.255.252) PREFIX="30" ;;
            255.255.254.0)   PREFIX="23" ;;
            255.255.252.0)   PREFIX="22" ;;
            255.255.248.0)   PREFIX="21" ;;
            255.255.240.0)   PREFIX="20" ;;
            *)               PREFIX="24" ;;
        esac

        # Configure IP address
        ip addr add "$IP/$PREFIX" dev "$DEVICE"

        # Add default route
        if [ -n "$GATEWAY" ]; then
            ip route add default via "$GATEWAY" dev "$DEVICE"
        fi

        # Configure DNS
        if [ -n "$DNS" ] && [ "$DNS" != "0.0.0.0" ]; then
            echo "nameserver $DNS" > /etc/resolv.conf
        else
            echo "nameserver 8.8.8.8" > /etc/resolv.conf
        fi

        echo "Network configured: $IP/$PREFIX via $GATEWAY"
    else
        echo "Warning: Network device $DEVICE not found"
    fi
fi
SCRIPTEOF

    # Create a late script to set up the /cdrom symlink for the update file
    mkdir -p "$work_dir/scripts/live-bottom"
    cat > "$work_dir/scripts/live-bottom/ORDER" << 'ORDEREOF'
/scripts/live-bottom/truenas-update
ORDEREOF

    cat > "$work_dir/scripts/live-bottom/truenas-update" << 'SCRIPTEOF'
#!/bin/sh
# Set up /cdrom symlink for TrueNAS installer to find update file
# Runs after rootfs is mounted

PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0;; esac

# Parse updateurl from kernel cmdline
for x in $(cat /proc/cmdline); do
    case $x in
        updateurl=*) UPDATEURL="${x#updateurl=}" ;;
    esac
done

if [ -n "$UPDATEURL" ]; then
    echo "Setting up TrueNAS update file access..."

    # Create /cdrom directory in the live rootfs
    mkdir -p /root/cdrom

    # Download the update file (this is ~1.6GB, needs RAM)
    echo "Downloading TrueNAS-SCALE.update from $UPDATEURL..."
    echo "This may take several minutes depending on network speed..."

    if wget -q -O /root/cdrom/TrueNAS-SCALE.update "$UPDATEURL"; then
        echo "Update file downloaded successfully"
    else
        echo "Warning: Failed to download update file from $UPDATEURL"
        echo "Installation may fail - try manual download from shell"
    fi
fi
SCRIPTEOF

    chmod +x "$work_dir/scripts/live-bottom/truenas-update"

    chmod +x "$work_dir/scripts/init-premount/static-net"

    # Create the cpio archive
    (cd "$work_dir" && find . | cpio -o -H newc 2>/dev/null | gzip) > "$dest/netboot-init.img"

    rm -rf "$work_dir"

    if [ -f "$dest/netboot-init.img" ]; then
        info "  Created supplementary initrd: netboot-init.img"
        return 0
    else
        warn "  Failed to create supplementary initrd"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Extract/prepare TrueNAS Scale ISOs for HTTP fetch boot
# ---------------------------------------------------------------------------
extract_truenas() {
    local iso="$1"
    local dest="$2"
    local iso_filename
    iso_filename="$(basename "$iso")"

    info "  TrueNAS Scale: Extracting for HTTP fetch boot..."

    # Extract full ISO contents
    # Note: 7z may report "errors" for symlinks but still extracts the main files
    info "  Extracting ISO contents (symlink warnings are normal)..."
    7z x "$iso" -o"$dest" -aoa >/dev/null 2>&1 || true

    # Verify the boot files we need were extracted
    # TrueNAS has vmlinuz and initrd.img at root level
    if [ ! -f "$dest/vmlinuz" ] || [ ! -f "$dest/initrd.img" ]; then
        error "  Failed to extract TrueNAS boot files (vmlinuz, initrd.img)"
        return 1
    fi

    # Verify the squashfs exists (needed for fetch=)
    if [ ! -f "$dest/live/filesystem.squashfs" ]; then
        error "  Failed to extract TrueNAS squashfs (live/filesystem.squashfs)"
        return 1
    fi

    # Create supplementary initrd for network configuration
    create_network_initrd "$dest"

    # Also keep the original ISO for reference/fallback
    if [ ! -e "$dest/$iso_filename" ]; then
        info "  Moving ISO into image folder..."
        mv "$iso" "$dest/$iso_filename"
    fi

    info "  TrueNAS extraction complete."
}
