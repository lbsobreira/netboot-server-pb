#!/bin/bash
# =============================================================================
# Netboot Server - Proxmox VE ISO Extraction Functions
# =============================================================================
# Handles Proxmox VE ISO preparation for PXE boot.
#
# APPROACH: Embed entire ISO into initrd (pve-iso-2-pxe method)
# ============================================================
# Proxmox's init script already supports PXE boot if /proxmox.iso exists
# inside the initrd. This is the community-proven approach:
#
#   1. Extract kernel (linux26) and initrd from ISO
#   2. Decompress initrd (zstd + cpio)
#   3. Copy the ENTIRE ISO into the initrd as /proxmox.iso
#   4. Repack initrd (will be ~1.5GB with embedded ISO)
#   5. Boot with ramdisk_size=16777216 kernel parameter
#
# The original init finds /proxmox.iso and proceeds with installation.
# No wrapper script, no driver injection, no network download needed.
#
# Requirements:
#   - Client must have 4GB+ RAM (ISO loaded entirely into RAM)
#   - Host needs: zstd, cpio (standard Linux tools)
#
# Source this file from prepare-images.sh.
#
# Required variables (set by parent script):
#   IMAGES_DIR, SERVER_IP
#
# Required functions (from logging-and-utils.sh):
#   info, warn, error
# =============================================================================

# ---------------------------------------------------------------------------
# Create PXE-bootable initrd with embedded ISO (pve-iso-2-pxe approach)
# ---------------------------------------------------------------------------
create_proxmox_pxe_initrd() {
    local iso_path="$1"
    local dest="$2"
    local orig_initrd="$dest/boot/initrd.img"
    local work_dir="/tmp/proxmox-pxe-$$"
    local iso_filename
    iso_filename="$(basename "$iso_path")"

    info "  Creating PXE initrd with embedded ISO..."
    info "  (This embeds the full ~1.3GB ISO into the initrd)"

    if [ ! -f "$orig_initrd" ]; then
        error "  Original initrd not found at $orig_initrd"
        return 1
    fi

    if [ ! -f "$iso_path" ]; then
        error "  ISO not found at $iso_path"
        return 1
    fi

    # Check available disk space (need ~3GB for temp files)
    local available_space
    available_space=$(df -BG /tmp | tail -1 | awk '{print $4}' | tr -d 'G')
    if [ "$available_space" -lt 3 ]; then
        error "  Insufficient disk space in /tmp. Need at least 3GB, have ${available_space}GB"
        return 1
    fi

    mkdir -p "$work_dir"
    cd "$work_dir" || return 1

    # Step 1: Extract original initrd (zstd compressed)
    info "  Extracting original initrd..."
    if ! zstd -d < "$orig_initrd" | cpio -idm 2>/dev/null; then
        error "  Failed to extract original initrd"
        rm -rf "$work_dir"
        return 1
    fi

    # Verify init exists
    if [ ! -f "$work_dir/init" ]; then
        error "  init script not found in initrd"
        rm -rf "$work_dir"
        return 1
    fi

    # Step 2: Copy the ENTIRE ISO into the initrd
    info "  Embedding ISO into initrd (this may take a moment)..."
    cp "$iso_path" "$work_dir/proxmox.iso"

    if [ ! -f "$work_dir/proxmox.iso" ]; then
        error "  Failed to copy ISO into initrd"
        rm -rf "$work_dir"
        return 1
    fi

    local iso_size
    iso_size=$(du -h "$work_dir/proxmox.iso" | cut -f1)
    info "  Embedded ISO size: $iso_size"

    # Step 3: Repack the initrd with embedded ISO
    info "  Repacking initrd (this will take a while due to size)..."
    cd "$work_dir" || return 1

    # Use zstd level 1 for faster compression (still good ratio, much faster than -19)
    # The initrd will be ~1.5GB regardless of compression level
    if find . | cpio -o -H newc 2>/dev/null | zstd -1 -T0 > "$dest/boot/initrd-pxe.img"; then
        if [ -f "$dest/boot/initrd-pxe.img" ] && [ -s "$dest/boot/initrd-pxe.img" ]; then
            local final_size
            final_size=$(du -h "$dest/boot/initrd-pxe.img" | cut -f1)
            info "  Created PXE initrd: boot/initrd-pxe.img ($final_size)"
            rm -rf "$work_dir"
            return 0
        fi
    fi

    error "  Failed to create PXE initrd"
    rm -rf "$work_dir"
    return 1
}

# ---------------------------------------------------------------------------
# Extract/prepare Proxmox VE ISOs for PXE boot
# ---------------------------------------------------------------------------
extract_proxmox() {
    local iso="$1"
    local dest="$2"
    local iso_filename
    iso_filename="$(basename "$iso")"

    info "  Proxmox VE: Preparing for PXE boot (ISO embedding method)..."

    # Extract boot files from ISO using 7z
    # We only need: boot/linux26 and boot/initrd.img
    info "  Extracting boot files from ISO..."
    7z x "$iso" -o"$dest" "boot/linux26" "boot/initrd.img" -aoa >/dev/null 2>&1 || {
        # Fallback: extract everything if selective extraction fails
        7z x "$iso" -o"$dest" -aoa >/dev/null 2>&1 || true
    }

    # Verify the boot files we need were extracted
    if [ ! -f "$dest/boot/linux26" ] || [ ! -f "$dest/boot/initrd.img" ]; then
        error "  Failed to extract Proxmox boot files (boot/linux26, boot/initrd.img)"
        return 1
    fi

    info "  Boot files extracted successfully"

    # Create PXE-bootable initrd with embedded ISO
    # Pass the ORIGINAL ISO path (not in dest yet)
    create_proxmox_pxe_initrd "$iso" "$dest"

    # We DON'T need the extracted squashfs files for PXE boot
    # The ISO embedded in initrd contains everything
    # Clean up any extracted squashfs to save space
    rm -f "$dest/pve-base.squashfs" 2>/dev/null
    rm -f "$dest/pve-installer.squashfs" 2>/dev/null
    rm -rf "$dest/proxmox" 2>/dev/null
    rm -rf "$dest/.disk" 2>/dev/null
    rm -f "$dest/.cd-info" "$dest/.pve-cd-id.txt" 2>/dev/null
    rm -f "$dest/COPYING" "$dest/COPYRIGHT" "$dest/EULA" 2>/dev/null

    # Delete the original ISO - it's now embedded in initrd-pxe.img
    # This saves ~1.3GB of disk space
    info "  Deleting original ISO (embedded in initrd)..."
    rm -f "$iso"

    info "  Proxmox PXE preparation complete."
    info "  IMPORTANT: Client needs 4GB+ RAM (entire ISO loaded into memory)"
    info "  The initrd-pxe.img is large (~1.5GB) - this is expected."
}
