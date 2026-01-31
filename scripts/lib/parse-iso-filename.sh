#!/bin/bash
# =============================================================================
# Netboot Server - ISO Filename Parsing Functions
# =============================================================================
# Parses ISO filenames to detect OS type and generate folder/display names.
# Source this file from prepare-images.sh.
# =============================================================================

# ---------------------------------------------------------------------------
# Parse OS type and Linux distro from the ISO filename convention
# ---------------------------------------------------------------------------
# Returns: "windows", "ubuntu", "rhel", "proxmox", "truenas", or "unknown"
# ---------------------------------------------------------------------------
parse_os_type() {
    local filename="$1"
    local lower
    lower="$(echo "$filename" | tr '[:upper:]' '[:lower:]')"

    if [[ "$lower" == windows-* ]]; then
        echo "windows"
    elif [[ "$lower" == vmware-* ]]; then
        # Extract product (second segment): vmware-<product>-...
        local product
        product="$(echo "$lower" | cut -d'-' -f2)"
        case "$product" in
            esxi) echo "esxi" ;;
            *) echo "vmware-unknown" ;;
        esac
    elif [[ "$lower" == linux-* ]]; then
        # Extract distro (second segment): linux-<distro>-...
        local distro
        distro="$(echo "$lower" | cut -d'-' -f2)"
        case "$distro" in
            ubuntu)  echo "ubuntu" ;;
            debian)  echo "debian" ;;
            fedora) echo "fedora" ;;
            almalinux|alma) echo "almalinux" ;;
            centos|rhel|rocky) echo "rhel" ;;
            proxmox) echo "proxmox" ;;
            truenas) echo "truenas" ;;
            *) echo "linux-unknown" ;;
        esac
    else
        echo "unknown"
    fi
}

# ---------------------------------------------------------------------------
# Derive folder name from ISO filename
# ---------------------------------------------------------------------------
folder_name() {
    local filename="$1"
    echo "${filename%.iso}" | tr '[:upper:]' '[:lower:]'
}

# ---------------------------------------------------------------------------
# Build a display name from the filename segments
# ---------------------------------------------------------------------------
display_name() {
    local folder="$1"
    local os_type="$2"
    local name

    case "$os_type" in
        windows)
            name="${folder#windows-}"
            name="$(echo "$name" | tr '-' ' ' | sed -E 's/\b(.)/\u\1/g')"
            echo "Windows $name"
            ;;
        esxi)
            name="${folder#vmware-}"
            name="$(echo "$name" | tr '-' ' ' | sed -E 's/\b(.)/\u\1/g')"
            echo "VMware $name"
            ;;
        ubuntu|debian|fedora|almalinux|rhel|proxmox|truenas)
            name="${folder#linux-}"
            name="$(echo "$name" | tr '-' ' ' | sed -E 's/\b(.)/\u\1/g')"
            echo "$name"
            ;;
        *)
            echo "$folder" | tr '-' ' '
            ;;
    esac
}
