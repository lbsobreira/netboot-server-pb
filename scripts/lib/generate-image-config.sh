#!/bin/bash
# =============================================================================
# Netboot Server - Image Config Generation Functions
# =============================================================================
# Creates config.json for images and checks preparation status.
# Source this file from prepare-images.sh.
#
# Required functions:
#   display_name (from parse-iso-filename.sh)
#   info (from logging-and-utils.sh)
# =============================================================================

# ---------------------------------------------------------------------------
# Create config.json for an image
# ---------------------------------------------------------------------------
create_config() {
    local dest="$1"
    local folder="$2"
    local os_type="$3"
    local iso_filename="$4"
    local name
    name="$(display_name "$folder" "$os_type")"

    local config_file="$dest/config.json"

    case "$os_type" in
        windows)
            cat > "$config_file" << EOF
{
    "name": "$name",
    "type": "windows"
}
EOF
            ;;
        ubuntu)
            cat > "$config_file" << EOF
{
    "name": "$name",
    "type": "linux",
    "distro": "ubuntu",
    "kernel": "vmlinuz",
    "initrd": "initrd",
    "boot_args": "ip=dhcp url=\${base-url}/$iso_filename",
    "iso": "$iso_filename"
}
EOF
            ;;
        debian)
            cat > "$config_file" << EOF
{
    "name": "$name",
    "type": "linux",
    "distro": "debian",
    "kernel": "vmlinuz",
    "initrd": "initrd.gz",
    "iso": "$iso_filename"
}
EOF
            ;;
        fedora)
            # Note: inst.repo points to the folder (extracted ISO contents), not the ISO file
            cat > "$config_file" << EOF
{
    "name": "$name",
    "type": "linux",
    "distro": "fedora",
    "kernel": "vmlinuz",
    "initrd": "initrd.img",
    "boot_args": "ip=dhcp inst.repo=\${base-url}"
}
EOF
            ;;
        almalinux)
            # Note: inst.repo points to the folder (extracted ISO contents), not the ISO file
            cat > "$config_file" << EOF
{
    "name": "$name",
    "type": "linux",
    "distro": "almalinux",
    "kernel": "vmlinuz",
    "initrd": "initrd.img",
    "boot_args": "ip=dhcp inst.repo=\${base-url}"
}
EOF
            ;;
        rhel)
            cat > "$config_file" << EOF
{
    "name": "$name",
    "type": "linux",
    "distro": "rhel",
    "kernel": "vmlinuz",
    "initrd": "initrd.img",
    "boot_args": "ip=dhcp inst.repo=\${base-url}/$iso_filename",
    "iso": "$iso_filename"
}
EOF
            ;;
        esxi)
            cat > "$config_file" << EOF
{
    "name": "$name",
    "type": "vmware",
    "distro": "esxi",
    "boot_type": "chainload",
    "bootloader": "mboot.efi",
    "boot_cfg": "boot.cfg"
}
EOF
            ;;
        proxmox)
            cat > "$config_file" << EOF
{
    "name": "$name",
    "type": "linux",
    "distro": "proxmox",
    "boot_type": "nfs",
    "kernel": "boot/linux26",
    "initrd": "boot/initrd.img",
    "iso": "$iso_filename"
}
EOF
            ;;
        truenas)
            cat > "$config_file" << EOF
{
    "name": "$name",
    "type": "linux",
    "distro": "truenas",
    "boot_type": "nfs",
    "kernel": "vmlinuz",
    "initrd": "initrd.img",
    "iso": "$iso_filename"
}
EOF
            ;;
    esac

    info "  Created $config_file"
}

# ---------------------------------------------------------------------------
# Check if an ISO has already been prepared
# ---------------------------------------------------------------------------
is_prepared() {
    local dest="$1"
    local os_type="$2"

    [ -d "$dest" ] || return 1
    [ -f "$dest/config.json" ] || return 1

    case "$os_type" in
        windows)
            # Full extraction: check for sources/install.wim (or .esd)
            local has_install=1
            find "$dest" -maxdepth 2 -iname "install.wim" -ipath "*/sources/*" | grep -q . && has_install=0
            if [ $has_install -ne 0 ]; then
                find "$dest" -maxdepth 2 -iname "install.esd" -ipath "*/sources/*" | grep -q . && has_install=0
            fi
            return $has_install
            ;;
        ubuntu)
            [ -f "$dest/vmlinuz" ] && [ -f "$dest/initrd" ]
            ;;
        debian)
            [ -f "$dest/vmlinuz" ] && [ -f "$dest/initrd.gz" ]
            ;;
        fedora|almalinux|rhel)
            [ -f "$dest/vmlinuz" ] && [ -f "$dest/initrd.img" ]
            ;;
        esxi)
            [ -f "$dest/mboot.efi" ] && [ -f "$dest/boot.cfg" ]
            ;;
        proxmox)
            # PXE boot: need kernel and PXE initrd with embedded ISO
            [ -f "$dest/boot/linux26" ] && [ -f "$dest/boot/initrd-pxe.img" ]
            ;;
        truenas)
            # NFS boot: need extracted boot files (at root level)
            [ -f "$dest/vmlinuz" ] && [ -f "$dest/initrd.img" ]
            ;;
        *)
            return 1
            ;;
    esac
}
