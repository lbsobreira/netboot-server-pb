# Netboot Server - Architecture Documentation

> Created: 2026-01-31
> Last Updated: 2026-01-31

---

## Table of Contents

1. [Overview](#overview)
2. [System Architecture](#system-architecture)
3. [Container Architecture](#container-architecture)
4. [Boot Flow](#boot-flow)
5. [Authentication System](#authentication-system)
6. [Directory Structure](#directory-structure)
7. [Script Architecture](#script-architecture)
8. [Adding New OS Support](#adding-new-os-support)
9. [Configuration Files](#configuration-files)
10. [OS-Specific Boot Methods](#os-specific-boot-methods)

---

## Overview

Netboot Server is a Docker-based PXE (Preboot Execution Environment) network boot server that enables OS installation across a network without physical media. It supports Windows, Linux distributions, and VMware ESXi, with an authentication layer to control access.

### Key Features

- **ProxyDHCP Mode**: Coexists with existing DHCP servers on the network
- **Multi-OS Support**: Windows, Linux (Ubuntu, Debian, Fedora, AlmaLinux, RHEL, Proxmox, TrueNAS), VMware ESXi
- **Authentication**: Local users (bcrypt) and LDAP/Active Directory support
- **Dynamic Menu Generation**: Boot menu auto-generated from available images
- **UEFI and Legacy BIOS**: Supports both boot modes

### Design Principles

1. **Convention over Configuration**: ISO naming conventions drive automatic detection and configuration
2. **Modular Architecture**: Each OS family has its own extraction module
3. **Separation of Concerns**: Parsing, extraction, configuration, and menu generation are separate
4. **Fail-Safe Logging**: All operations logged with timestamps for troubleshooting
5. **Idempotent Operations**: Re-running scripts skips already-prepared images

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              NETWORK (192.168.1.0/24)                       │
└─────────────────────────────────────────────────────────────────────────────┘
        │                                          │
        │ PXE Boot Request                         │ Existing DHCP
        │ (UDP 67/68)                              │ (IP assignment)
        ▼                                          ▼
┌───────────────────────┐                 ┌───────────────────────┐
│   NETBOOT SERVER      │                 │   EXISTING DHCP       │
│   (Docker Container)  │                 │   SERVER/ROUTER       │
│                       │                 │                       │
│   ProxyDHCP Mode      │                 │   Provides IP         │
│   Provides boot info  │                 │   addresses           │
└───────────────────────┘                 └───────────────────────┘
        │
        │ TFTP (UDP 69): iPXE bootloader
        │ HTTP (TCP 8080): Boot scripts, images, auth
        │ SMB (TCP 445): Windows install source
        │
        ▼
┌───────────────────────┐
│   PXE CLIENT          │
│   (VM or Physical)    │
│                       │
│   1. Gets IP from     │
│      existing DHCP    │
│   2. Gets boot info   │
│      from ProxyDHCP   │
│   3. Downloads iPXE   │
│   4. Authenticates    │
│   5. Selects OS       │
│   6. Installs         │
└───────────────────────┘
```

---

## Container Architecture

The netboot server runs as a single Docker container with multiple services managed by supervisord.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Docker Container (netboot-server) — host networking mode                   │
│                                                                             │
│  entrypoint.sh → generates smb.conf → exec supervisord                      │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         SUPERVISORD                                  │   │
│  │                                                                      │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────┐│   │
│  │  │    AUTH      │  │   DNSMASQ    │  │    SMBD      │  │  NGINX   ││   │
│  │  │  (Flask)     │  │              │  │   (Samba)    │  │          ││   │
│  │  │              │  │  ProxyDHCP   │  │              │  │  HTTP    ││   │
│  │  │  Port 8081   │  │  UDP 67/68   │  │  TCP 445     │  │  TCP 8080││   │
│  │  │  (internal)  │  │              │  │              │  │          ││   │
│  │  │              │  │  TFTP        │  │  /srv/images │  │  Proxy   ││   │
│  │  │  Priority 5  │  │  UDP 69      │  │  (read-only) │  │  + Static││   │
│  │  │              │  │              │  │              │  │          ││   │
│  │  │              │  │  Priority 10 │  │  Priority 15 │  │ Priority ││   │
│  │  │              │  │              │  │              │  │    20    ││   │
│  │  └──────────────┘  └──────────────┘  └──────────────┘  └──────────┘│   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  Volume Mounts:                                                             │
│  ├── ./images:/srv/images              (rw — extraction + SMB serve)        │
│  ├── ./config/ipxe:/srv/ipxe           (rw — menu generation)               │
│  ├── ./config/dnsmasq/dnsmasq.conf:ro                                       │
│  ├── ./config/nginx/nginx.conf:ro                                           │
│  ├── ./config/auth/*.yml:ro                                                 │
│  └── ./tftp:/srv/tftp:ro                                                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Service Responsibilities

| Service | Port(s) | Purpose |
|---------|---------|---------|
| **dnsmasq** | UDP 67/68 (DHCP), UDP 69 (TFTP) | ProxyDHCP announcements, TFTP bootloader delivery |
| **nginx** | TCP 8080 | HTTP server for boot files, images, auth proxy |
| **smbd** | TCP 445 | SMB share for Windows installation source |
| **auth** | TCP 8081 (internal) | Flask authentication service |

---

## Boot Flow

### Complete PXE Boot Sequence

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   CLIENT     │     │   EXISTING   │     │   NETBOOT    │     │   NETBOOT    │
│   MACHINE    │     │   DHCP       │     │   (dnsmasq)  │     │   (nginx)    │
└──────┬───────┘     └──────┬───────┘     └──────┬───────┘     └──────┬───────┘
       │                    │                    │                    │
       │  1. DHCP Discover  │                    │                    │
       │ ──────────────────►│                    │                    │
       │ ──────────────────────────────────────►│                    │
       │                    │                    │                    │
       │  2. DHCP Offer (IP)│                    │                    │
       │ ◄──────────────────│                    │                    │
       │                    │                    │                    │
       │  3. ProxyDHCP Offer (boot info)         │                    │
       │ ◄──────────────────────────────────────│                    │
       │     next-server = netboot IP            │                    │
       │     filename = ipxe.efi/undionly.kpxe   │                    │
       │                    │                    │                    │
       │  4. TFTP Request (bootloader)           │                    │
       │ ──────────────────────────────────────►│                    │
       │                    │                    │                    │
       │  5. iPXE Bootloader                     │                    │
       │ ◄──────────────────────────────────────│                    │
       │                    │                    │                    │
       │  6. HTTP: GET /ipxe/boot.ipxe           │                    │
       │ ──────────────────────────────────────────────────────────►│
       │                    │                    │                    │
       │  7. boot.ipxe (login prompt)            │                    │
       │ ◄──────────────────────────────────────────────────────────│
       │                    │                    │                    │
       │     ┌────────────────────────────────┐  │                    │
       │     │  User enters username/password │  │                    │
       │     └────────────────────────────────┘  │                    │
       │                    │                    │                    │
       │  8. HTTP: POST /auth/boot.ipxe          │                    │
       │     (username + password)               │                    │
       │ ──────────────────────────────────────────────────────────►│
       │                    │                    │         ┌─────────┴─────────┐
       │                    │                    │         │ Auth Service      │
       │                    │                    │         │ validates creds   │
       │                    │                    │         │ (local/LDAP)      │
       │                    │                    │         └─────────┬─────────┘
       │  9. menu.ipxe (on success)              │                    │
       │ ◄──────────────────────────────────────────────────────────│
       │                    │                    │                    │
       │     ┌────────────────────────────────┐  │                    │
       │     │  User selects OS from menu     │  │                    │
       │     └────────────────────────────────┘  │                    │
       │                    │                    │                    │
       │  10. HTTP: Download kernel, initrd, etc.│                    │
       │ ──────────────────────────────────────────────────────────►│
       │ ◄──────────────────────────────────────────────────────────│
       │                    │                    │                    │
       │  11. OS Installation begins             │                    │
       │                    │                    │                    │
```

### Boot Modes by Client Type

| Client | Bootloader | Delivered via |
|--------|------------|---------------|
| UEFI | `ipxe.efi` | TFTP |
| Legacy BIOS | `undionly.kpxe` | TFTP |

---

## Authentication System

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           AUTHENTICATION FLOW                               │
└─────────────────────────────────────────────────────────────────────────────┘

  iPXE Client                 nginx (:8080)              Auth Service (:8081)
       │                           │                            │
       │  POST /auth/boot.ipxe     │                            │
       │  username=xxx             │                            │
       │  password=yyy             │                            │
       │ ─────────────────────────►│                            │
       │                           │                            │
       │                           │  proxy_pass                │
       │                           │ ──────────────────────────►│
       │                           │                            │
       │                           │         ┌──────────────────┴──────────────┐
       │                           │         │  Auth Mode Check                │
       │                           │         │                                 │
       │                           │         │  mode: local                    │
       │                           │         │  └─► Check users.yml (bcrypt)   │
       │                           │         │                                 │
       │                           │         │  mode: ldap                     │
       │                           │         │  └─► Bind to LDAP/AD server     │
       │                           │         │                                 │
       │                           │         │  mode: both                     │
       │                           │         │  └─► Try local, fallback LDAP   │
       │                           │         └──────────────────┬──────────────┘
       │                           │                            │
       │                           │  200 OK + menu.ipxe        │
       │                           │ ◄──────────────────────────│
       │  menu.ipxe content        │                            │
       │ ◄─────────────────────────│                            │
       │                           │                            │
```

### Configuration Files

| File | Purpose |
|------|---------|
| `config/auth/auth.yml` | Authentication mode (local/ldap/both), LDAP server settings |
| `config/auth/users.yml` | Local user accounts with bcrypt password hashes |

### LDAP Bind Modes

| Mode | Description | Use Case |
|------|-------------|----------|
| `direct_bind` | Constructs DN from pattern, binds directly | Simple, flat AD structures |
| `search_bind` | Service account searches for user, then re-binds | Complex AD with nested OUs |

### Password Security

- Local passwords: bcrypt with 12 rounds
- Password input: Visible in iPXE prompt (iPXE `read` command limitation)
- LDAP: Credentials validated against AD/LDAP server (not stored locally)
- LDAP queries: Username escaped to prevent injection attacks

---

## Directory Structure

```
netboot-server/
├── CLAUDE.md                      # AI assistant context file
├── docker-compose.yml             # Container orchestration
├── Dockerfile                     # Container build instructions
├── .env                           # Environment variables (network config)
├── .env.example                   # Template for .env
│
├── auth/                          # Authentication service
│   ├── app.py                     # Flask auth service (local + LDAP)
│   ├── requirements.txt           # Python dependencies
│   └── hash-password.py           # Utility to generate bcrypt hashes
│
├── config/
│   ├── auth/
│   │   ├── auth.yml               # Auth mode configuration
│   │   └── users.yml              # Local user accounts
│   ├── dnsmasq/
│   │   └── dnsmasq.conf           # DHCP proxy + TFTP configuration
│   ├── nginx/
│   │   └── nginx.conf             # HTTP server + auth proxy
│   ├── ipxe/
│   │   ├── boot.ipxe              # Entry point: login prompt
│   │   └── menu.ipxe              # Boot menu (auto-generated)
│   ├── winpe/                     # Universal WinPE for Windows PXE
│   │   ├── README.md              # ADK build instructions
│   │   ├── boot.wim               # ADK WinPE image (gitignored)
│   │   ├── BCD                    # Boot Configuration Data (gitignored)
│   │   └── boot.sdi               # Boot SDI file (gitignored)
│   └── templates/
│       └── windows-11-oobe-bypass.xml  # Windows OOBE automation
│
├── images/                        # OS images directory (user ISOs)
│   ├── README.md                  # Image naming instructions
│   └── <extracted-images>/        # Prepared images (gitignored)
│
├── tftp/                          # TFTP root (bootloader files)
│   ├── ipxe.efi                   # UEFI bootloader
│   └── undionly.kpxe              # BIOS bootloader
│
├── logs/                          # Script execution logs (gitignored)
│
├── scripts/
│   ├── entrypoint.sh              # Container entrypoint
│   ├── setup.sh                   # Initial setup script
│   ├── prepare-images.sh          # Main orchestrator for ISO preparation
│   ├── generate-menu.sh           # Generates iPXE menu from config.json files
│   └── lib/                       # Modular library functions
│       ├── logging-and-utils.sh   # Colored logging (info, warn, error)
│       ├── parse-iso-filename.sh  # OS detection from filename
│       ├── generate-image-config.sh # config.json creation
│       ├── extract-windows-iso.sh # Windows extraction
│       ├── extract-linux-iso.sh   # Generic Linux (Ubuntu/RHEL)
│       ├── extract-debian-iso.sh  # Debian-specific
│       ├── extract-fedora-iso.sh  # Fedora-specific
│       ├── extract-almalinux-iso.sh # AlmaLinux-specific
│       ├── extract-esxi-iso.sh    # VMware ESXi
│       ├── extract-proxmox-iso.sh # Proxmox VE
│       └── extract-truenas-iso.sh # TrueNAS Scale
│
└── docs/
    ├── ARCHITECTURE.md            # This file
    ├── DIARY.md                   # Development diary
    ├── PLAN.md                    # Implementation phases
    ├── TESTING.md                 # Testing procedures
    └── screenshots/               # Visual documentation
```

---

## Script Architecture

### Script Execution Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         prepare-images.sh (Orchestrator)                    │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
          ┌──────────────────────────┼──────────────────────────┐
          │                          │                          │
          ▼                          ▼                          ▼
┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
│ Source lib/     │      │ For each *.iso  │      │ If prepared > 0 │
│                 │      │                 │      │                 │
│ logging-and-    │      │ 1. Parse type   │      │ Call            │
│   utils.sh      │      │ 2. Check if     │      │ generate-menu.sh│
│ parse-iso-      │      │    prepared     │      │                 │
│   filename.sh   │      │ 3. Extract      │      └─────────────────┘
│ extract-*.sh    │      │ 4. Create       │
│ generate-image- │      │    config.json  │
│   config.sh     │      │                 │
└─────────────────┘      └─────────────────┘
```

### Module Responsibilities

| Module | Functions | Purpose |
|--------|-----------|---------|
| `logging-and-utils.sh` | `info()`, `warn()`, `error()` | Colored console output |
| `parse-iso-filename.sh` | `parse_os_type()`, `folder_name()`, `display_name()` | ISO filename parsing and OS detection |
| `generate-image-config.sh` | `create_config()`, `is_prepared()` | config.json creation and preparation check |
| `extract-<os>-iso.sh` | `extract_<os>()` | OS-specific extraction logic |

### ISO Naming Convention

The system uses filename patterns to automatically detect OS type:

| Pattern | Detected Type | Example |
|---------|---------------|---------|
| `windows-*` | windows | `windows-11-desktop-25h2-x64.iso` |
| `linux-ubuntu-*` | ubuntu | `linux-ubuntu-server-24.04-amd64.iso` |
| `linux-debian-*` | debian | `linux-debian-13.3.0-amd64.iso` |
| `linux-fedora-*` | fedora | `linux-fedora-server-x86.64-43.1.6.iso` |
| `linux-almalinux-*` | almalinux | `linux-AlmaLinux-x86.64-10.1.iso` |
| `linux-proxmox-*` | proxmox | `linux-proxmox-ve-9.0.1.iso` |
| `linux-truenas-*` | truenas | `linux-truenas-scale-25.04.iso` |
| `vmware-esxi-*` | esxi | `vmware-esxi-x86.64-8.0U3e.iso` |

---

## Adding New OS Support

When adding support for a new OS, follow this checklist:

### Files to Modify/Create

| # | File | Action | Purpose |
|---|------|--------|---------|
| 1 | `scripts/lib/parse-iso-filename.sh` | MODIFY | Add pattern detection in `parse_os_type()` |
| 2 | `scripts/lib/parse-iso-filename.sh` | MODIFY | Add case in `display_name()` for pretty names |
| 3 | `scripts/lib/extract-<newos>-iso.sh` | CREATE | New extraction function |
| 4 | `scripts/lib/generate-image-config.sh` | MODIFY | Add case in `create_config()` |
| 5 | `scripts/lib/generate-image-config.sh` | MODIFY | Add case in `is_prepared()` |
| 6 | `scripts/prepare-images.sh` | MODIFY | Add `source` line for new extraction script |
| 7 | `scripts/prepare-images.sh` | MODIFY | Add case in extraction switch |
| 8 | `scripts/generate-menu.sh` | MODIFY | Add menu section if new type (e.g., "bsd") |

### Example: Adding a New Linux Distro

If the new distro follows standard Linux boot (kernel + initrd), minimal changes are needed:

**1. parse-iso-filename.sh** - Add to `parse_os_type()`:
```bash
case "$distro" in
    ...
    newdistro) echo "newdistro" ;;
    ...
esac
```

**2. parse-iso-filename.sh** - Add to `display_name()`:
```bash
ubuntu|debian|fedora|almalinux|rhel|proxmox|truenas|newdistro)
```

**3. Create extract-newdistro-iso.sh**:
```bash
#!/bin/bash
extract_newdistro() {
    local iso="$1"
    local dest="$2"

    info "  NewDistro: Extracting boot files..."
    # Extract kernel and initrd
    7z x "$iso" -o"$dest" "path/to/vmlinuz" "path/to/initrd" -aoa
    # Move to expected locations
    mv "$dest/path/to/vmlinuz" "$dest/vmlinuz"
    mv "$dest/path/to/initrd" "$dest/initrd.img"

    info "  NewDistro extraction complete."
}
```

**4. generate-image-config.sh** - Add to `create_config()`:
```bash
newdistro)
    cat > "$config_file" << EOF
{
    "name": "$name",
    "type": "linux",
    "distro": "newdistro",
    "kernel": "vmlinuz",
    "initrd": "initrd.img",
    "boot_args": "ip=dhcp inst.repo=\${base-url}"
}
EOF
    ;;
```

**5. generate-image-config.sh** - Add to `is_prepared()`:
```bash
newdistro)
    [ -f "$dest/vmlinuz" ] && [ -f "$dest/initrd.img" ]
    ;;
```

**6. prepare-images.sh** - Add source and case:
```bash
source "$SCRIPT_DIR/lib/extract-newdistro-iso.sh"
...
case "$os_type" in
    ...
    newdistro) extract_newdistro "$iso" "$dest" ;;
    ...
esac
```

---

## Configuration Files

### config.json (Per-Image)

Each extracted image folder contains a `config.json` that generate-menu.sh reads:

```json
{
    "name": "Ubuntu Server 24.04 LTS",
    "type": "linux",
    "distro": "ubuntu",
    "kernel": "vmlinuz",
    "initrd": "initrd",
    "boot_args": "ip=dhcp url=${base-url}/linux-ubuntu-server-24.04-amd64.iso",
    "iso": "linux-ubuntu-server-24.04-amd64.iso"
}
```

| Field | Required | Purpose |
|-------|----------|---------|
| `name` | Yes | Display name in boot menu |
| `type` | Yes | OS category: `linux`, `windows`, `vmware` |
| `distro` | No | Specific distribution (for distro-specific handling) |
| `kernel` | Linux only | Path to kernel file |
| `initrd` | Linux only | Path to initrd file |
| `boot_args` | No | Additional kernel boot parameters |
| `boot_type` | No | Boot method: `kernel` (default), `nfs`, `iso`, `chainload` |
| `bootloader` | VMware only | Bootloader file (e.g., `mboot.efi`) |
| `boot_cfg` | VMware only | Boot config file (e.g., `boot.cfg`) |
| `iso` | No | ISO filename (for URL-based installers) |

### Environment Variables (.env)

```bash
# Network Configuration
TFTP_SERVER_IP=192.168.1.43       # IP of the Docker host
HTTP_PORT=8080                     # nginx HTTP port
DHCP_INTERFACE=eth0                # Network interface
SMB_ALLOWED_SUBNET=192.168.1.0/24  # SMB access control

# Menu Customization
MENU_TITLE="Netboot Server"        # Boot menu title
```

---

## OS-Specific Boot Methods

### Linux (Standard)

```
type: linux, boot_type: kernel (default)

iPXE:
  kernel ${base-url}/vmlinuz initrd=initrd ${boot_args}
  initrd ${base-url}/initrd
  boot
```

### Linux (NFS/Special - Proxmox, TrueNAS)

```
type: linux, boot_type: nfs

Special handling per distro:
- Proxmox: ISO embedded in initrd, ramdisk_size parameter
- TrueNAS: live-boot with squashfs fetch
```

### Windows

```
type: windows

iPXE:
  kernel ${server-url}/images/wimboot
  initrd ${base-url}/boot/bcd        BCD
  initrd ${base-url}/boot/boot.sdi   boot.sdi
  initrd ${base-url}/sources/boot.wim boot.wim
  boot

Requires:
- Universal WinPE from Windows ADK (config/winpe/)
- SMB share for install source
- startnet.cmd injection for network mapping
```

### VMware ESXi

```
type: vmware, boot_type: chainload

iPXE:
  kernel ${base-url}/mboot.efi -c ${base-url}/boot.cfg prefix=${base-url}
  boot

Requires:
- boot.cfg modification (remove leading slashes, cdromBoot)
- Filenames converted to lowercase
- Bare metal or compatible virtualization (not Hyper-V/VirtualBox)
```

---

## Error Handling

### Script Safety

All scripts use `set -euo pipefail`:
- `-e`: Exit on any command failure
- `-u`: Exit on undefined variable
- `-o pipefail`: Pipeline fails if any command fails

### Logging

- All operations logged to `logs/<script>_<timestamp>.log`
- Colored output: `[INFO]` (green), `[WARN]` (yellow), `[ERROR]` (red)
- Both console and file output via `tee`

### Recovery

- `is_prepared()` checks allow re-running without re-extracting
- Partial extractions can be cleaned up by removing the image folder
- Menu regeneration is idempotent

---

## Security Considerations

> **This service is designed for internal/trusted networks only.**
> Do not expose to the internet.

1. **Network Isolation**: Run only on trusted networks (PXE traffic is not encrypted)
2. **Authentication**: Always enable authentication in production
3. **Password Storage**: Local passwords use bcrypt (12 rounds)
4. **SMB Access**: Restricted by subnet (configured via SMB_ALLOWED_SUBNET)
5. **NFS Access**: Restricted by subnet (same as SMB)
6. **LDAP**: Use TLS (`ldaps://`) when authenticating against external directories
7. **LDAP Injection**: Username input is escaped before use in LDAP queries
8. **Default Credentials**: Change `admin/netboot` before deployment
9. **No HTTPS**: Traffic is unencrypted (acceptable for isolated PXE networks)

