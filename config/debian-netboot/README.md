# Debian Netboot Files

This folder contains the **netboot initrd** required for Debian PXE installation.

## Why is this needed?

The initrd from Debian ISOs (`install.amd/initrd.gz`) contains `cdrom-detect` which always prompts for CD-ROM media - this cannot be disabled via preseed or kernel parameters.

The **netboot initrd** uses `net-retriever` instead, which fetches packages via HTTP without any CD-ROM detection.

## Files

- `initrd.gz` - Debian netboot initrd (~40MB)

## Download

For Debian 13 (Trixie):
```
https://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz
```

For other versions, replace `trixie` with the codename:
- Debian 12: `bookworm`
- Debian 11: `bullseye`

## How it works

When `prepare-images.sh` processes a Debian ISO:
1. Extracts the **kernel** (`vmlinuz`) from the ISO
2. Extracts **full ISO contents** (serves as local HTTP package repository)
3. Copies the **netboot initrd** from this folder (not the ISO's initrd)

The installer then boots without CD-ROM detection and uses your local HTTP server as the package mirror.
