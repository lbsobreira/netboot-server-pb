#!/bin/bash
# =============================================================================
# Netboot Server - VMware ESXi ISO Extraction Functions
# =============================================================================
# Handles VMware ESXi ISO extraction for PXE boot.
#
# ESXi uses a custom boot mechanism:
#   - mboot.efi (UEFI bootloader) from efi/boot/bootx64.efi
#   - boot.cfg (configuration listing kernel and modules)
#   - Multiple .b00 and .vgz module files
#
# For PXE boot, boot.cfg must be modified:
#   - Remove leading slashes from kernel= and modules= paths
#   - Set prefix= to HTTP URL or leave empty for relative paths
#
# Source this file from prepare-images.sh.
#
# Required functions (from logging-and-utils.sh):
#   info, warn, error
# =============================================================================

# ---------------------------------------------------------------------------
# Extract and prepare ESXi ISO for PXE boot
# ---------------------------------------------------------------------------
extract_esxi() {
    local iso="$1"
    local dest="$2"
    local iso_filename
    iso_filename="$(basename "$iso")"

    info "  ESXi: Extracting for PXE boot..."

    # Extract FULL ISO contents
    info "  Extracting full ISO contents..."
    7z x "$iso" -o"$dest" -aoa >/dev/null 2>&1 || {
        error "  Failed to extract ISO contents"
        return 1
    }

    # Copy mboot.efi to root (it's at efi/boot/bootx64.efi)
    if [ -f "$dest/efi/boot/bootx64.efi" ]; then
        cp "$dest/efi/boot/bootx64.efi" "$dest/mboot.efi"
        info "  Copied mboot.efi (UEFI bootloader)"
    elif [ -f "$dest/EFI/BOOT/BOOTX64.EFI" ]; then
        cp "$dest/EFI/BOOT/BOOTX64.EFI" "$dest/mboot.efi"
        info "  Copied mboot.efi (UEFI bootloader)"
    else
        error "  Could not find ESXi UEFI bootloader (bootx64.efi)"
        return 1
    fi

    # Find and modify boot.cfg
    local boot_cfg=""
    if [ -f "$dest/boot.cfg" ]; then
        boot_cfg="$dest/boot.cfg"
    elif [ -f "$dest/BOOT.CFG" ]; then
        boot_cfg="$dest/BOOT.CFG"
        # Rename to lowercase for consistency
        mv "$dest/BOOT.CFG" "$dest/boot.cfg"
        boot_cfg="$dest/boot.cfg"
    fi

    if [ -z "$boot_cfg" ] || [ ! -f "$boot_cfg" ]; then
        error "  Could not find boot.cfg"
        return 1
    fi

    info "  Modifying boot.cfg for HTTP boot..."

    # Create backup
    cp "$boot_cfg" "$dest/boot.cfg.original"

    # Rename all uppercase files to lowercase (ESXi ISOs often have uppercase)
    # This ensures boot.cfg references match actual filenames
    info "  Converting filenames to lowercase..."
    find "$dest" -maxdepth 1 -type f -name "*[A-Z]*" | while read -r f; do
        lower=$(echo "$f" | tr '[:upper:]' '[:lower:]')
        if [ "$f" != "$lower" ]; then
            mv "$f" "$lower" 2>/dev/null || true
        fi
    done

    # Also handle EFI directory if it exists
    if [ -d "$dest/EFI" ]; then
        mv "$dest/EFI" "$dest/efi" 2>/dev/null || true
    fi

    # Modify boot.cfg:
    # 1. Remove leading slashes from kernel= and modules= lines
    # 2. Remove cdromBoot from kernelopt (if present)
    # 3. Clear prefix= (we'll set it via iPXE or use relative paths)
    # 4. Convert all paths to lowercase
    sed -i 's|^kernel=/|kernel=|' "$boot_cfg"
    sed -i 's|^modules=/|modules=|' "$boot_cfg"
    sed -i 's| --- /| --- |g' "$boot_cfg"
    sed -i 's|cdromBoot||g' "$boot_cfg"
    sed -i 's|^prefix=.*|prefix=|' "$boot_cfg"

    # Convert kernel and modules paths to lowercase in boot.cfg
    sed -i 's|^kernel=.*|&|; s|=[A-Z]|=\L&|g; s|/[A-Z]|/\L&|g' "$boot_cfg"
    # Simpler approach - just lowercase the entire kernel and modules lines
    sed -i '/^kernel=/s/.*/\L&/' "$boot_cfg"
    sed -i '/^modules=/s/.*/\L&/' "$boot_cfg"

    # Verify key files exist
    if [ ! -f "$dest/mboot.efi" ]; then
        error "  mboot.efi not found"
        return 1
    fi

    # Check for essential boot files (now lowercase)
    if [ ! -f "$dest/b.b00" ]; then
        warn "  Warning: b.b00 (kernel) not found at root level"
    fi

    local mboot_size boot_cfg_size
    mboot_size=$(du -h "$dest/mboot.efi" | cut -f1)
    boot_cfg_size=$(du -h "$boot_cfg" | cut -f1)
    info "  Boot files ready: mboot.efi ($mboot_size), boot.cfg ($boot_cfg_size)"

    # Delete the original ISO to save space
    info "  Deleting original ISO (contents extracted)..."
    rm -f "$iso"

    info "  ESXi extraction complete."
    info "  NOTE: iPXE will chainload mboot.efi with boot.cfg for installation."
}
