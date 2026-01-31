#!/bin/bash
# =============================================================================
# Netboot Server - AlmaLinux ISO Extraction Functions
# =============================================================================
# Handles AlmaLinux ISO extraction for PXE boot.
#
# AlmaLinux is a RHEL clone using the Anaconda installer with boot files at:
#   - images/pxeboot/vmlinuz (kernel)
#   - images/pxeboot/initrd.img (initrd)
#
# IMPORTANT: Anaconda's inst.repo= expects a full repository structure, not
# just an ISO file. We must extract the FULL ISO contents so Anaconda can
# access .treeinfo, images/install.img, LiveOS/squashfs.img, etc.
#
# Source this file from prepare-images.sh.
#
# Required functions (from logging-and-utils.sh):
#   info, warn, error
# =============================================================================

# ---------------------------------------------------------------------------
# Extract boot files and full contents for AlmaLinux ISOs
# ---------------------------------------------------------------------------
extract_almalinux() {
    local iso="$1"
    local dest="$2"
    local iso_filename
    iso_filename="$(basename "$iso")"

    info "  AlmaLinux: Extracting for local HTTP repository..."

    # Extract FULL ISO contents (Anaconda needs .treeinfo, images/, BaseOS/, etc.)
    info "  Extracting full ISO contents..."
    7z x "$iso" -o"$dest" -aoa >/dev/null 2>&1 || {
        error "  Failed to extract ISO contents"
        return 1
    }

    # Move kernel and initrd to root of dest for easy PXE access
    if [ -f "$dest/images/pxeboot/vmlinuz" ]; then
        cp "$dest/images/pxeboot/vmlinuz" "$dest/vmlinuz"
        info "  Copied vmlinuz to root"
    else
        error "  Could not find AlmaLinux kernel at images/pxeboot/vmlinuz"
        return 1
    fi

    if [ -f "$dest/images/pxeboot/initrd.img" ]; then
        cp "$dest/images/pxeboot/initrd.img" "$dest/initrd.img"
        info "  Copied initrd.img to root"
    else
        error "  Could not find AlmaLinux initrd at images/pxeboot/initrd.img"
        return 1
    fi

    # Verify key files exist for Anaconda
    if [ ! -f "$dest/.treeinfo" ]; then
        warn "  Warning: .treeinfo not found - Anaconda may have issues"
    fi

    local kernel_size initrd_size
    kernel_size=$(du -h "$dest/vmlinuz" | cut -f1)
    initrd_size=$(du -h "$dest/initrd.img" | cut -f1)
    info "  Boot files ready: vmlinuz ($kernel_size), initrd.img ($initrd_size)"

    # Delete the original ISO to save space (contents are extracted)
    info "  Deleting original ISO (contents extracted)..."
    rm -f "$iso"

    info "  AlmaLinux extraction complete."
    info "  NOTE: Installer will use inst.repo= to fetch packages from local HTTP server."
}
