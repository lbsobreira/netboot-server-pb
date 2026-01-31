#!/bin/bash
# =============================================================================
# Netboot Server - Windows ISO Extraction Functions
# =============================================================================
# Handles Windows ISO extraction, WinPE replacement, and startnet.cmd injection.
# Source this file from prepare-images.sh.
#
# Required variables (set by parent script):
#   WINPE_DIR, LOGS_DIR, LOG_TIMESTAMP, SERVER_IP, IMAGES_DIR, PROJECT_DIR
#
# Required functions (from logging-and-utils.sh):
#   info, warn, error
# =============================================================================

# ---------------------------------------------------------------------------
# Extract Windows ISO — full contents, replace boot files with universal
# WinPE (if available), then inject startnet.cmd into boot.wim
# ---------------------------------------------------------------------------
extract_windows() {
    local iso="$1"
    local dest="$2"
    local folder="$3"

    # Full extraction preserving directory structure
    # Try UDF first (has all files), fall back to default
    info "  Extracting full ISO contents (this may take a while) ..."
    info "  ISO path: $iso"
    info "  ISO size: $(ls -lh "$iso" 2>/dev/null | awk '{print $5}' || echo 'unknown')"

    local extract_log="$LOGS_DIR/7z_extract_${LOG_TIMESTAMP}.log"

    if ! 7z x -tudf "$iso" -o"$dest" -aoa > "$extract_log" 2>&1; then
        warn "  UDF extraction failed. Trying default format..."
        warn "  7z output: $(tail -20 "$extract_log")"

        if ! 7z x "$iso" -o"$dest" -aoa > "$extract_log" 2>&1; then
            error "  Failed to extract ISO"
            error "  7z output: $(cat "$extract_log")"
            return 1
        fi
    fi

    info "  Extraction complete. See $extract_log for details."

    # Verify critical files exist
    # 7z may extract as lowercase — find them case-insensitively
    local boot_wim=""
    local install_wim=""
    boot_wim="$(find "$dest" -maxdepth 2 -iname "boot.wim" -ipath "*/sources/*" | head -1)"
    install_wim="$(find "$dest" -maxdepth 2 -iname "install.wim" -ipath "*/sources/*" | head -1)"

    if [ -z "$boot_wim" ]; then
        error "  sources/boot.wim not found after extraction"
        return 1
    fi

    if [ -z "$install_wim" ]; then
        warn "  sources/install.wim not found — checking for install.esd ..."
        install_wim="$(find "$dest" -maxdepth 2 -iname "install.esd" -ipath "*/sources/*" | head -1)"
        if [ -z "$install_wim" ]; then
            error "  No install.wim or install.esd found"
            return 1
        fi
    fi

    info "  Found: $boot_wim"
    info "  Found: $install_wim"

    # Replace ISO boot files with universal WinPE (ADK-built, has SMB support)
    replace_with_winpe "$dest" "$boot_wim"

    # Inject startnet.cmd into boot.wim for SMB share mapping
    inject_startnet "$boot_wim" "$folder"

    # Inject autounattend.xml for OOBE bypass (Windows 10/11 only)
    inject_autounattend "$dest" "$folder"
}

# ---------------------------------------------------------------------------
# Replace ISO boot files with universal WinPE copies (if available)
# ---------------------------------------------------------------------------
# The ADK WinPE has SMB support built-in, unlike retail ISO boot.wim.
# Falls back gracefully to the ISO's original files if WinPE is missing.
# ---------------------------------------------------------------------------
replace_with_winpe() {
    local dest="$1"
    local boot_wim="$2"

    if [ ! -f "$WINPE_DIR/boot.wim" ]; then
        warn "  Universal WinPE not found at: $WINPE_DIR/boot.wim"
        warn "  Using ISO's original boot.wim (SMB may not work during PXE boot)."
        warn "  See: config/winpe/README.md for setup instructions."
        return 0
    fi

    info "  Replacing boot files with universal WinPE ..."

    # Replace sources/boot.wim
    cp -f "$WINPE_DIR/boot.wim" "$boot_wim"
    info "  Replaced: $boot_wim"

    # Replace boot/bcd (case-insensitive search)
    if [ -f "$WINPE_DIR/BCD" ]; then
        local bcd_file
        bcd_file="$(find "$dest" -maxdepth 2 -iname "bcd" -ipath "*/boot/*" | head -1)"
        if [ -n "$bcd_file" ]; then
            cp -f "$WINPE_DIR/BCD" "$bcd_file"
            info "  Replaced: $bcd_file"
        else
            warn "  boot/bcd not found in extracted ISO — skipping BCD replacement"
        fi
    fi

    # Replace boot/boot.sdi (case-insensitive search)
    if [ -f "$WINPE_DIR/boot.sdi" ]; then
        local sdi_file
        sdi_file="$(find "$dest" -maxdepth 2 -iname "boot.sdi" -ipath "*/boot/*" | head -1)"
        if [ -n "$sdi_file" ]; then
            cp -f "$WINPE_DIR/boot.sdi" "$sdi_file"
            info "  Replaced: $sdi_file"
        else
            warn "  boot/boot.sdi not found in extracted ISO — skipping SDI replacement"
        fi
    fi

    info "  Universal WinPE applied successfully."
}

# ---------------------------------------------------------------------------
# Inject startnet.cmd into boot.wim using wimlib
# ---------------------------------------------------------------------------
inject_startnet() {
    local boot_wim="$1"
    local folder="$2"

    if ! command -v wimlib-imagex &>/dev/null; then
        warn "  wimlib-imagex not found. Skipping startnet.cmd injection."
        warn "  Install with: sudo apt install wimtools"
        warn "  WinPE will boot but cannot auto-map the install source."
        return 0
    fi

    info "  Injecting startnet.cmd into boot.wim ..."

    # Create temp startnet.cmd
    local tmp_startnet
    tmp_startnet="$(mktemp /tmp/startnet.XXXXXX.cmd)"

    # Write startnet.cmd — initialise networking, wait, map SMB share, run setup
    # wpeinit alone can fail to bring up networking on some systems (especially
    # wimboot on UEFI). We explicitly initialise and wait for the network, then
    # retry the SMB mapping before launching setup.exe.
    #
    # Note: ADK WinPE has SMB support built-in — no need for manual
    # "net start" of MRxSmb20 or LanmanWorkstation.
    cat > "$tmp_startnet" << STARTNET
@echo off
wpeinit
wpeutil InitializeNetwork
wpeutil WaitForNetwork

echo Waiting for network...
:wait_net
ping -n 2 ${SERVER_IP} >nul 2>&1
if errorlevel 1 goto wait_net

echo Mapping SMB share...
:retry_map
net use Z: \\\\${SERVER_IP}\\images\\${folder} >nul 2>&1
if errorlevel 1 (
    ping -n 3 127.0.0.1 >nul 2>&1
    goto retry_map
)

echo Bypassing hardware checks (TPM, Secure Boot, RAM)...
reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f >nul 2>&1
reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f >nul 2>&1
reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f >nul 2>&1

echo Starting Windows Setup...
Z:\\setup.exe
STARTNET

    # Inject into all image indexes in the WIM
    local num_images
    num_images="$(wimlib-imagex info "$boot_wim" | grep "Image Count" | awk '{print $3}')"

    if [ -z "$num_images" ] || [ "$num_images" -eq 0 ]; then
        warn "  Could not determine image count in boot.wim"
        rm -f "$tmp_startnet"
        return 1
    fi

    for i in $(seq 1 "$num_images"); do
        wimlib-imagex update "$boot_wim" "$i" --command \
            "add $tmp_startnet /Windows/System32/startnet.cmd" >/dev/null 2>&1 || {
            warn "  Failed to inject startnet.cmd into image index $i"
        }
    done

    rm -f "$tmp_startnet"
    info "  startnet.cmd injected (server: $SERVER_IP, share: images/$folder)"
}

# ---------------------------------------------------------------------------
# Inject autounattend.xml for Windows 10/11 OOBE bypass
# ---------------------------------------------------------------------------
# Copies the OOBE bypass template to the image root so Windows Setup picks
# it up automatically. Skips network requirement and Microsoft account prompt.
# ---------------------------------------------------------------------------
inject_autounattend() {
    local dest="$1"
    local folder="$2"

    local template="$PROJECT_DIR/config/templates/windows-11-oobe-bypass.xml"

    # Only inject for Windows 10/11 (not Server editions)
    if [[ "$folder" != *windows-10* ]] && [[ "$folder" != *windows-11* ]]; then
        info "  Skipping OOBE bypass (not Windows 10/11 client)."
        return 0
    fi

    if [ ! -f "$template" ]; then
        warn "  OOBE bypass template not found: $template"
        warn "  Windows 11 will require network + Microsoft account during OOBE."
        return 0
    fi

    info "  Copying OOBE bypass (autounattend.xml) ..."
    cp -f "$template" "$dest/autounattend.xml"
    info "  OOBE bypass applied (skips network requirement + Microsoft account)."
}

# ---------------------------------------------------------------------------
# Download wimboot (iPXE Windows boot shim)
# ---------------------------------------------------------------------------
ensure_wimboot() {
    local wimboot_path="$IMAGES_DIR/wimboot"

    if [ -f "$wimboot_path" ]; then
        info "wimboot already present."
        return 0
    fi

    info "Downloading wimboot from iPXE project ..."
    local url="https://github.com/ipxe/wimboot/releases/latest/download/wimboot"
    if curl -fSL -o "$wimboot_path" "$url"; then
        chmod 644 "$wimboot_path"
        info "wimboot downloaded to $wimboot_path"
    else
        error "Failed to download wimboot. Windows PXE boot will not work."
        error "Download manually from: $url"
        return 1
    fi
}
