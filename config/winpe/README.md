# Universal WinPE for PXE Boot

Retail Windows ISOs include a `boot.wim` designed for local DVD/USB installation.
It does **not** have the SMB client (Workstation service) enabled, so `net use`
fails during PXE boot even though TCP/IP works fine.

The solution is to build a universal WinPE using the Windows ADK. ADK WinPE
includes SMB support out of the box. The `prepare-images.sh` script automatically
replaces each ISO's boot files with copies from this directory.

## One-Time Setup (on a Windows machine)

### 1. Install Windows ADK + WinPE Add-on

Download and install both:

- [Windows ADK](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install)
  (only the "Deployment Tools" feature is required)
- **Windows PE add-on for the ADK** (same page, separate download)

### 2. Create the WinPE Working Directory

Open **Deployment and Imaging Tools Environment** as Administrator:

```cmd
copype amd64 C:\WinPE
```

### 3. (Optional) Add Extra Components

Mount the WinPE image and add useful packages:

```cmd
Dism /Mount-Image /ImageFile:C:\WinPE\media\sources\boot.wim /Index:1 /MountDir:C:\WinPE\mount

Dism /Image:C:\WinPE\mount /Add-Package /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-WMI.cab"
Dism /Image:C:\WinPE\mount /Add-Package /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\en-us\WinPE-WMI_en-us.cab"

Dism /Image:C:\WinPE\mount /Add-Package /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-Scripting.cab"
Dism /Image:C:\WinPE\mount /Add-Package /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\en-us\WinPE-Scripting_en-us.cab"

Dism /Unmount-Image /MountDir:C:\WinPE\mount /Commit
```

### 4. Copy the 3 Required Files

Copy these files into this `config/winpe/` directory:

| Source | Destination |
|--------|-------------|
| `C:\WinPE\media\sources\boot.wim` | `config/winpe/boot.wim` |
| `C:\WinPE\media\Boot\BCD` | `config/winpe/BCD` |
| `C:\WinPE\media\Boot\boot.sdi` | `config/winpe/boot.sdi` |

```cmd
:: Option A: Copy via network share
copy C:\WinPE\media\sources\boot.wim   \\<your-server>\netboot-server\config\winpe\
copy C:\WinPE\media\Boot\BCD           \\<your-server>\netboot-server\config\winpe\
copy C:\WinPE\media\Boot\boot.sdi      \\<your-server>\netboot-server\config\winpe\

:: Option B: Copy via SCP (if OpenSSH available)
scp C:\WinPE\media\sources\boot.wim   user@server:/path/to/netboot-server/config/winpe/
scp C:\WinPE\media\Boot\BCD           user@server:/path/to/netboot-server/config/winpe/
scp C:\WinPE\media\Boot\boot.sdi      user@server:/path/to/netboot-server/config/winpe/
```

## Result

After placing the files, this directory should contain:

```
config/winpe/
├── .gitkeep
├── README.md
├── boot.wim      (~250-400 MB)
├── BCD            (~16 KB)
└── boot.sdi       (~3 MB)
```

## How It's Used

When `prepare-images.sh` processes a Windows ISO:

1. Extracts the full ISO contents as before
2. **Replaces** the ISO's `sources/boot.wim` with a copy of `winpe/boot.wim`
3. **Replaces** the ISO's `boot/bcd` with a copy of `winpe/BCD`
4. **Replaces** the ISO's `boot/boot.sdi` with a copy of `winpe/boot.sdi`
5. Injects the per-image `startnet.cmd` into the copy

If the WinPE files are not present, the script warns and falls back to using the
ISO's original boot files (previous behavior).

## Compatibility

One WinPE build works for all Windows versions (10, 11, Server 2019, 2022, etc.).
The WinPE is only used to boot, initialise networking, map the SMB share, and
launch `setup.exe`. The actual Windows installer comes from each ISO's own
`install.wim` / `install.esd`.
