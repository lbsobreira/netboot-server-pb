#!/bin/bash
# =============================================================================
# Netboot Server - Auto-prepare ISOs for PXE Boot
# =============================================================================
# Scans images/ for .iso files and extracts the required boot files
# for PXE booting. Creates config.json for each image and regenerates
# the boot menu.
#
# Windows ISOs: full extraction + startnet.cmd injection via wimlib
#               so WinPE can map the SMB share and run setup.exe.
#               ISO is deleted after extraction to save disk space.
#
# Linux ISOs:   boot files extracted + ISO kept for HTTP install source.
#
# ISO Naming Convention (required):
#   Windows:  windows-<edition>-<version>-<variant>-<arch>.iso
#   Linux:    linux-<distro>-<edition>-<version>.iso
#
# Examples:
#   windows-server-2022-datacenter-x64.iso
#   windows-11-pro-25h2-x64.iso
#   linux-ubuntu-server-24lts.iso
#   linux-centos-desktop-9.iso
#
# Prerequisites (host):
#   sudo apt install p7zip-full wimtools
#   (Samba is handled automatically inside the Docker container)
#
# Usage: ./scripts/prepare-images.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGES_DIR="$PROJECT_DIR/images"
WINPE_DIR="$PROJECT_DIR/config/winpe"
LOGS_DIR="$PROJECT_DIR/logs"

# ---------------------------------------------------------------------------
# Logging setup — logs to file and console
# ---------------------------------------------------------------------------
mkdir -p "$LOGS_DIR"
SCRIPT_NAME="$(basename "$0" .sh)"
LOG_TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
LOG_FILE="$LOGS_DIR/${SCRIPT_NAME}_${LOG_TIMESTAMP}.log"

# Start logging (tee to both console and file)
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo " Log started: $(date '+%Y-%m-%d %H:%M:%S')"
echo " Log file: $LOG_FILE"
echo "=========================================="
echo ""

# Source .env for server IP
if [ -f "$PROJECT_DIR/.env" ]; then
    source "$PROJECT_DIR/.env"
fi

SERVER_IP="${TFTP_SERVER_IP:-192.168.1.100}"

# ---------------------------------------------------------------------------
# Source library modules
# ---------------------------------------------------------------------------
source "$SCRIPT_DIR/lib/logging-and-utils.sh"
source "$SCRIPT_DIR/lib/parse-iso-filename.sh"
source "$SCRIPT_DIR/lib/extract-windows-iso.sh"
source "$SCRIPT_DIR/lib/extract-linux-iso.sh"
source "$SCRIPT_DIR/lib/extract-debian-iso.sh"
source "$SCRIPT_DIR/lib/extract-fedora-iso.sh"
source "$SCRIPT_DIR/lib/extract-almalinux-iso.sh"
source "$SCRIPT_DIR/lib/extract-esxi-iso.sh"
source "$SCRIPT_DIR/lib/extract-proxmox-iso.sh"
source "$SCRIPT_DIR/lib/extract-truenas-iso.sh"
source "$SCRIPT_DIR/lib/generate-image-config.sh"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

if ! command -v 7z &>/dev/null; then
    error "7z not found. Install it with: sudo apt install p7zip-full"
    exit 1
fi

if [ ! -d "$IMAGES_DIR" ]; then
    error "Images directory not found: $IMAGES_DIR"
    exit 1
fi

# =============================================================================
# Main
# =============================================================================

echo "==========================================="
echo " Netboot Server - ISO Auto-Preparation"
echo "==========================================="
echo ""

# Check for universal WinPE files
if [ -f "$WINPE_DIR/boot.wim" ]; then
    info "Universal WinPE found — Windows ISOs will use ADK boot files."
else
    warn "Universal WinPE not found at: $WINPE_DIR/"
    warn "Windows PXE boot may fail without it (SMB client not available)."
    warn "See: config/winpe/README.md for setup instructions."
fi
echo "" >&2

FOUND_ISO=0
FOUND_WINDOWS=0
PREPARED=0
SKIPPED=0
ERRORS=0

for iso in "$IMAGES_DIR"/*.iso; do
    [ -f "$iso" ] || continue
    FOUND_ISO=$((FOUND_ISO + 1))

    iso_filename="$(basename "$iso")"
    info "Processing: $iso_filename"

    # Parse OS type from filename convention
    os_type="$(parse_os_type "$iso_filename")"

    if [ "$os_type" = "unknown" ]; then
        warn "  Filename does not follow naming convention. Skipping."
        warn "  Expected: windows-<...>.iso or linux-<distro>-<...>.iso"
        warn "  See: images/README.md for naming instructions."
        ERRORS=$((ERRORS + 1))
        echo "" >&2
        continue
    fi

    if [ "$os_type" = "linux-unknown" ]; then
        warn "  Unrecognised Linux distro in filename. Skipping."
        warn "  Supported: ubuntu, debian, centos, rhel, fedora, rocky, alma"
        ERRORS=$((ERRORS + 1))
        echo "" >&2
        continue
    fi

    info "  Detected: $os_type"

    # Folder name = lowercase filename without .iso
    folder="$(folder_name "$iso_filename")"
    dest="$IMAGES_DIR/$folder"
    info "  Target folder: $folder/"

    # Skip if already prepared
    if is_prepared "$dest" "$os_type"; then
        info "  Already prepared. Skipping."
        SKIPPED=$((SKIPPED + 1))
        echo "" >&2
        continue
    fi

    # Create destination folder
    mkdir -p "$dest"

    # Track Windows ISOs for wimboot download
    if [ "$os_type" = "windows" ]; then
        FOUND_WINDOWS=$((FOUND_WINDOWS + 1))
    fi

    # Extract
    case "$os_type" in
        windows)  extract_windows "$iso" "$dest" "$folder" ;;
        ubuntu)   extract_ubuntu  "$iso" "$dest" ;;
        debian)   extract_debian  "$iso" "$dest" ;;
        fedora)    extract_fedora    "$iso" "$dest" ;;
        almalinux) extract_almalinux "$iso" "$dest" ;;
        rhel)      extract_rhel      "$iso" "$dest" ;;
        esxi)      extract_esxi      "$iso" "$dest" ;;
        proxmox)  extract_proxmox "$iso" "$dest" ;;
        truenas)  extract_truenas "$iso" "$dest" ;;
    esac

    # Create config.json
    create_config "$dest" "$folder" "$os_type" "$iso_filename"

    # Delete Windows ISOs after full extraction to save disk space
    # (Linux ISOs are kept — needed for HTTP install source)
    if [ "$os_type" = "windows" ]; then
        info "  Deleting ISO (full contents extracted) ..."
        rm -f "$iso"
    fi

    PREPARED=$((PREPARED + 1))
    info "  Done."
    echo "" >&2
done

# Download wimboot if any Windows ISOs were found
if [ "$FOUND_WINDOWS" -gt 0 ]; then
    ensure_wimboot
    echo "" >&2
fi

# Summary
echo "==========================================="
echo " Summary"
echo "==========================================="
echo "  ISOs found:    $FOUND_ISO"
echo "  Prepared:      $PREPARED"
echo "  Skipped:       $SKIPPED"
echo "  Errors:        $ERRORS"
echo ""

# Regenerate the boot menu if we prepared anything
if [ "$PREPARED" -gt 0 ]; then
    info "Regenerating boot menu ..."
    "$SCRIPT_DIR/generate-menu.sh"
elif [ "$FOUND_ISO" -eq 0 ]; then
    warn "No .iso files found in $IMAGES_DIR"
    warn "Drop ISO files there and re-run this script."
    warn "See: images/README.md for naming instructions."
else
    info "Nothing new to prepare. Boot menu unchanged."
fi
