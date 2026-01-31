#!/bin/bash
# =============================================================================
# Netboot Server - Linux ISO Extraction Functions
# =============================================================================
# Handles Linux ISO extraction for standard distributions:
#   - Ubuntu/Debian (casper-based)
#   - RHEL/CentOS/Fedora/Rocky/Alma
#
# For specialized systems (Proxmox, TrueNAS), see their dedicated modules.
# Source this file from prepare-images.sh.
#
# Required functions (from logging-and-utils.sh):
#   info, warn, error
# =============================================================================

# ---------------------------------------------------------------------------
# Extract boot files for Ubuntu / Casper-based ISOs
# ---------------------------------------------------------------------------
extract_ubuntu() {
    local iso="$1"
    local dest="$2"
    local iso_filename
    iso_filename="$(basename "$iso")"

    info "  Extracting casper/vmlinuz ..."
    7z e "$iso" -o"$dest" "casper/vmlinuz" -aoa -r >/dev/null 2>&1 || warn "  Could not extract casper/vmlinuz"

    info "  Extracting casper/initrd ..."
    7z e "$iso" -o"$dest" "casper/initrd" -aoa -r >/dev/null 2>&1 || warn "  Could not extract casper/initrd"

    # Move ISO into the subfolder so nginx can serve it for HTTP install
    # (keeps everything for one image in one folder)
    if [ ! -e "$dest/$iso_filename" ]; then
        info "  Moving ISO into image folder ..."
        mv "$iso" "$dest/$iso_filename"
    fi
}

# ---------------------------------------------------------------------------
# Extract boot files for RHEL / Fedora / CentOS ISOs
# ---------------------------------------------------------------------------
extract_rhel() {
    local iso="$1"
    local dest="$2"
    local iso_filename
    iso_filename="$(basename "$iso")"

    info "  Extracting images/pxeboot/vmlinuz ..."
    7z e "$iso" -o"$dest" "images/pxeboot/vmlinuz" -aoa -r >/dev/null 2>&1 || warn "  Could not extract vmlinuz"

    info "  Extracting images/pxeboot/initrd.img ..."
    7z e "$iso" -o"$dest" "images/pxeboot/initrd.img" -aoa -r >/dev/null 2>&1 || warn "  Could not extract initrd.img"

    # Move ISO into the subfolder so nginx can serve it for HTTP install
    if [ ! -e "$dest/$iso_filename" ]; then
        info "  Moving ISO into image folder ..."
        mv "$iso" "$dest/$iso_filename"
    fi
}
