# Images Directory

Place your OS ISOs in this directory. The `prepare-images.sh` script will
automatically extract boot files, create folders, and update the boot menu.

## ISO Naming Convention

ISOs **must** follow this naming format so the script can identify them:

### Windows

```
windows-<edition>-<version>[-variant][-arch].iso
```

| Example filename | Menu name |
|---|---|
| `windows-11-pro-25h2-x64.iso` | Windows 11 Pro 25h2 X64 |
| `windows-10-enterprise-22h2-x64.iso` | Windows 10 Enterprise 22h2 X64 |
| `windows-server-2022-datacenter-x64.iso` | Windows Server 2022 Datacenter X64 |
| `windows-server-2019-standard-x64.iso` | Windows Server 2019 Standard X64 |

### Linux

```
linux-<distro>-<edition>-<version>.iso
```

| Example filename | Menu name |
|---|---|
| `linux-ubuntu-server-24lts.iso` | Ubuntu Server 24lts |
| `linux-ubuntu-desktop-22.04.iso` | Ubuntu Desktop 22.04 |
| `linux-centos-server-9.iso` | Centos Server 9 |
| `linux-rhel-server-9.iso` | Rhel Server 9 |
| `linux-rocky-server-9.iso` | Rocky Server 9 |
| `linux-fedora-workstation-41.iso` | Fedora Workstation 41 |
| `linux-debian-server-12.iso` | Debian Server 12 |

### Supported Linux distros

`ubuntu`, `debian`, `centos`, `rhel`, `fedora`, `rocky`, `alma`

## Windows PXE Requirement: Universal WinPE

Retail Windows ISOs include a `boot.wim` that lacks SMB support. PXE-booted
WinPE can ping the server but `net use` fails because the Workstation service
is not available. To fix this, build a universal WinPE once using the Windows
ADK and place 3 files in `config/winpe/`:

| File | Size (approx) |
|------|---------------|
| `boot.wim` | 250-400 MB |
| `BCD` | ~256 KB |
| `boot.sdi` | ~3 MB |

The `prepare-images.sh` script automatically replaces each ISO's boot files
with copies from `winpe/` before injecting the per-image `startnet.cmd`.

One WinPE build works for **all** Windows versions (10, 11, Server 2019, 2022, etc.).

**Setup instructions:** see [`config/winpe/README.md`](winpe/README.md)

**Without WinPE:** the script falls back to the ISO's original boot files and
prints a warning. Everything works except SMB mapping during PXE boot.

## How to Use

1. **(One-time)** Build universal WinPE — see [`config/winpe/README.md`](winpe/README.md)
2. Rename your ISO to match the convention above
3. Drop it into this `images/` directory
4. Run the preparation script:

```bash
./scripts/prepare-images.sh
```

5. The script will:
   - Detect the OS type from the filename
   - **Windows**: extract full ISO contents, replace boot files with universal
     WinPE (if present), inject `startnet.cmd` into `boot.wim` (for SMB share
     mapping), delete the ISO to save space
   - **Linux**: extract boot files (vmlinuz, initrd), keep the ISO for HTTP install
   - Download `wimboot` if Windows ISOs are present
   - Generate `config.json` metadata
   - Regenerate the iPXE boot menu

6. Restart the container:

```bash
docker compose restart
```

## What Happens During PXE Boot

### Windows
1. iPXE loads `wimboot` + `BCD` + `boot.sdi` + `boot.wim` into RAM
2. Universal WinPE boots (ADK-built, has SMB support) and runs injected `startnet.cmd`
3. `startnet.cmd` runs `wpeinit` + `wpeutil InitializeNetwork` + `wpeutil WaitForNetwork`
4. Waits for network connectivity (pings server)
5. Maps the SMB share: `net use Z: \\<server>\images\<folder>`
6. Runs `Z:\setup.exe` — Windows Setup starts with full access to `install.wim`

### Linux
1. iPXE loads kernel + initrd directly over HTTP
2. Linux installer boots with the ISO URL as the install source

## SMB Share (Automatic)

Windows PXE installs need an SMB share to access `install.wim`. This is handled
automatically by the Docker container — Samba runs inside the container and
shares this `images/` directory as a read-only guest-accessible share.

No host-level Samba installation is needed. The SMB share is available on port 445
whenever the container is running.

## What Gets Extracted

| OS | Extraction | ISO kept? |
|---|---|---|
| Windows | Full ISO contents (preserving directory structure) | No (deleted) |
| Ubuntu/Debian | `casper/vmlinuz`, `casper/initrd` | Yes (symlinked) |
| RHEL/CentOS/Fedora/Rocky/Alma | `images/pxeboot/vmlinuz`, `images/pxeboot/initrd.img` | Yes (symlinked) |

## Resulting Folder Structure

```
images/
├── winpe/                               (one-time ADK build — see winpe/README.md)
│   ├── boot.wim                         (universal WinPE with SMB support)
│   ├── BCD
│   └── boot.sdi
├── windows-11-desktop-25h2-x64/         (full ISO contents)
│   ├── config.json
│   ├── boot/
│   │   ├── bcd                          (replaced with winpe/BCD)
│   │   ├── boot.sdi                     (replaced with winpe/boot.sdi)
│   │   └── ...
│   ├── sources/
│   │   ├── boot.wim                     (replaced with winpe/boot.wim + startnet.cmd)
│   │   ├── install.wim
│   │   ├── setup.exe
│   │   └── ...
│   ├── efi/
│   └── ...
├── linux-ubuntu-server-24lts/
│   ├── config.json
│   ├── vmlinuz
│   ├── initrd
│   └── linux-ubuntu-server-24lts.iso → ../linux-ubuntu-server-24lts.iso
├── wimboot                              (downloaded automatically)
└── README.md
```

## Re-running the Script

The script is safe to re-run. It skips ISOs that have already been prepared.
For Windows, it checks for `sources/install.wim` in the subfolder.
To force re-extraction, delete the subfolder first.

## Prerequisites

```bash
sudo apt install p7zip-full wimtools
```

## Notes

- This directory is gitignored (ISOs and extracted contents are too large)
- Only `config.json` metadata files should be committed
- The boot menu is auto-generated from the subfolders here
- Windows ISOs are deleted after extraction to save disk space
