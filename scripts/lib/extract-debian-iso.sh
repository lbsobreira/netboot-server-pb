#!/bin/bash
# =============================================================================
# Netboot Server - Debian ISO Extraction Functions
# =============================================================================
# Handles Debian ISO extraction for PXE boot.
#
# IMPORTANT: Debian PXE boot requires the NETBOOT initrd, not the ISO's initrd.
# The ISO's initrd has cdrom-detect built-in which cannot be disabled.
# The netboot initrd uses net-retriever for HTTP-based installation.
#
# Approach:
#   1. Extract kernel from ISO (install.amd/vmlinuz)
#   2. Extract FULL ISO contents (serves as local HTTP repository)
#   3. Use NETBOOT initrd from config/debian-netboot/ (no CD-ROM detection)
#   4. Configure installer to use our HTTP server as the mirror
#
# The netboot initrd.gz must be placed in config/debian-netboot/ before
# running prepare-images.sh. Download from:
#   https://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz
#
# Source this file from prepare-images.sh.
#
# Required functions (from logging-and-utils.sh):
#   info, warn, error
# =============================================================================

# ---------------------------------------------------------------------------
# Extract boot files and full contents for Debian ISOs
# ---------------------------------------------------------------------------
extract_debian() {
    local iso="$1"
    local dest="$2"
    local iso_filename
    iso_filename="$(basename "$iso")"

    # Path to netboot initrd in config
    local netboot_initrd="$PROJECT_DIR/config/debian-netboot/initrd.gz"

    info "  Debian: Extracting for local HTTP repository..."

    # Check for netboot initrd
    if [ ! -f "$netboot_initrd" ]; then
        error "  Netboot initrd not found at: $netboot_initrd"
        error "  Debian PXE boot requires the netboot initrd (not the ISO's initrd)."
        error "  Download from: https://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz"
        error "  Place it in: config/debian-netboot/initrd.gz"
        return 1
    fi

    # Extract FULL ISO contents (serves as local mirror)
    info "  Extracting full ISO contents (local HTTP repository)..."
    7z x "$iso" -o"$dest" -aoa >/dev/null 2>&1 || {
        error "  Failed to extract ISO contents"
        return 1
    }

    # Extract kernel from ISO to root of dest
    if [ -f "$dest/install.amd/vmlinuz" ]; then
        mv "$dest/install.amd/vmlinuz" "$dest/vmlinuz"
        info "  Extracted kernel: vmlinuz"
    elif [ -f "$dest/install.amd64/vmlinuz" ]; then
        mv "$dest/install.amd64/vmlinuz" "$dest/vmlinuz"
        info "  Extracted kernel: vmlinuz"
    else
        error "  Could not find Debian kernel in ISO"
        return 1
    fi

    # Copy NETBOOT initrd (not the ISO's initrd!)
    info "  Copying netboot initrd (no CD-ROM detection)..."
    cp "$netboot_initrd" "$dest/initrd.gz"

    # Remove the ISO's initrd to avoid confusion
    rm -f "$dest/install.amd/initrd.gz" 2>/dev/null
    rm -f "$dest/install.amd64/initrd.gz" 2>/dev/null

    # Keep the ISO in the folder (backup)
    if [ ! -e "$dest/$iso_filename" ]; then
        info "  Moving ISO into image folder..."
        mv "$iso" "$dest/$iso_filename"
    fi

    local kernel_size initrd_size
    kernel_size=$(du -h "$dest/vmlinuz" | cut -f1)
    initrd_size=$(du -h "$dest/initrd.gz" | cut -f1)
    info "  Boot files ready: vmlinuz ($kernel_size), initrd.gz ($initrd_size)"

    info "  Debian extraction complete."
    info "  NOTE: Installer will use local HTTP server as package repository."
}
