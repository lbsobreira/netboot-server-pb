# Netboot Server - Testing Guide

## Test Environments

### 1. Hyper-V Manager (Primary Development Testing)

#### Creating a BIOS Test VM (Generation 1)

1. Open Hyper-V Manager
2. New > Virtual Machine
3. **Name**: `netboot-test-bios`
4. **Generation**: Generation 1 (Legacy BIOS)
5. **Memory**: 2048 MB (minimum)
6. **Network**: Connect to the same virtual switch as the Docker host
7. **Hard Disk**: Create a virtual hard disk (40 GB)
8. **Installation**: Install an operating system from a network-based installation server
9. **Boot Order**: Move "Legacy Network Adapter" or "Network Adapter" to the top

#### Creating a UEFI Test VM (Generation 2)

1. Open Hyper-V Manager
2. New > Virtual Machine
3. **Name**: `netboot-test-uefi`
4. **Generation**: Generation 2 (UEFI)
5. **Memory**: 2048 MB (minimum)
6. **Network**: Connect to the same virtual switch as the Docker host
7. **Hard Disk**: Create a virtual hard disk (40 GB)
8. **Security**: Disable Secure Boot (Settings > Security > uncheck "Enable Secure Boot")
9. **Firmware**: Move "Network Adapter" to the top of the boot order

### 2. Physical Micro PCs (Real-World Validation)

1. Enter BIOS/UEFI setup (usually F2, DEL, or F12 on boot)
2. Disable Secure Boot (if UEFI)
3. Set Network Boot / PXE as first boot option
4. Save and exit
5. Device should PXE boot and reach the iPXE menu

## Test Checklist

### Phase 1: Basic PXE Boot

| Test | BIOS (Gen1) | UEFI (Gen2) | Physical |
|------|:-----------:|:-----------:|:--------:|
| Container starts without errors | | | N/A |
| Client sends PXE request | | | |
| dnsmasq responds with boot file | | | |
| iPXE bootloader loads | | | |
| Boot menu displays | | | |

### Phase 2: Linux Boot

| Test | BIOS (Gen1) | UEFI (Gen2) | Physical |
|------|:-----------:|:-----------:|:--------:|
| Linux option appears in menu | | | |
| Kernel + initrd load over HTTP | | | |
| Installer starts | | | |
| Full installation completes | | | |

### Phase 3: Windows Boot

| Test | BIOS (Gen1) | UEFI (Gen2) | Physical |
|------|:-----------:|:-----------:|:--------:|
| Windows option appears in menu | | | |
| wimboot loads WinPE | | | |
| Windows installer starts | | | |
| Disks are visible | | | |
| Full installation completes | | | |

## Logging and Debugging

```bash
# Watch all container logs
docker compose logs -f

# Watch only dnsmasq logs (PXE/DHCP)
docker compose logs -f | grep dnsmasq

# Watch only nginx logs (HTTP)
docker compose logs -f | grep nginx

# Check if ports are listening
ss -ulnp | grep -E '67|69'     # DHCP + TFTP (UDP)
ss -tlnp | grep 8080            # HTTP (TCP)
```

## Evidence Collection

For each successful test:
1. Take a screenshot of the boot menu or installer
2. Save it in `docs/screenshots/` with naming: `phase{N}-{description}-{date}.png`
3. Log the result in `docs/DIARY.md` with the screenshot reference
