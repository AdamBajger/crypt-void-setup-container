# crypt-void-setup-container

This project streamlines the setup of a fully encrypted
[VoidLinux](https://voidlinux.org) installation on a bootable removable
storage device (micro SD card, USB drive, etc.).

The entire process runs inside a Docker container based on the official
VoidLinux image.  A loopback device simulates the target storage device so
that the physical device experiences no load during setup.  The finished disk
image is saved to an output directory and can be flashed to the physical device
using [Balena Etcher](https://etcher.balena.io/) or a similar tool.

---

## Overview

```
Host machine
 └─ docker-compose run void-setup
     └─ VoidLinux container (privileged)
         ├─ /tmp/void-disk.img         loopback disk image (in container FS)
         │   ├─ p1  void-efi-partition   512 MiB  FAT32      /boot/efi
         │   ├─ p2  void-boot-partition  512 MiB  ext4       /boot
         │   └─ p3  void-luks-partition  rest     LUKS1+PBKDF2
         │       └─ void-luks (dm-crypt)
         │           └─ void-vg (LVM volume group)
         │               ├─ void-swap   swap LV
         │               └─ void-root   root LV   ext4   /
         ├─ /config  (mounted read-only from host)
         │   ├─ disk.yaml
         │   └─ system.yaml
         └─ /output  (mounted read-write from host)
             └─ void-linux-encrypted-<timestamp>.img  ← flashable image
```

---

## Quick start

### 1 — Prerequisites

- Docker with Compose v2 (or `docker-compose`)
- A Linux host (the container requires the `loop`, `dm-crypt`, and `lvm`
  kernel modules on the host)

### 2 — Clone and configure

```bash
git clone https://github.com/AdamBajger/crypt-void-setup-container.git
cd crypt-void-setup-container

# Create the output directory (ignored by git).
mkdir -p output

# Copy and edit the environment variable template.
cp .env.example .env
$EDITOR .env          # set LUKS_PASSWORD, ROOT_PASSWORD, USER_PASSWORD

# (Optional) Adjust partition sizes.
$EDITOR config/disk.yaml

# (Optional) Adjust system settings (hostname, username, timezone, …).
$EDITOR config/system.yaml
```

### 3 — (Optional) Auto-generate disk.yaml from a physical device

If you want the image to exactly match a specific storage device, run the
helper tool on the host *before* starting the container:

```bash
# Replace /dev/sdX with your actual device — do NOT pass your system disk!
sudo ./tools/get-device-spec.sh /dev/sdX > config/disk.yaml
```

### 4 — Build and run

```bash
docker compose run --rm --env-file .env void-setup
```

The container will:

1. Parse `config/disk.yaml` and `config/system.yaml`.
2. Create a loopback disk image.
3. Partition it (GPT, EFI + unencrypted boot + LUKS).
4. Set up **LUKS1** encryption with **PBKDF2** on the third partition.
5. Set up **LVM** (volume group `void-vg`, logical volumes `void-root` and
   `void-swap`) inside the LUKS container.
6. Format all filesystems.
7. Bootstrap a minimal VoidLinux system via `xbps-install`.
8. Run `void-installation-script.sh` inside `xchroot` to configure the system
   (hostname, locale, users, GRUB, initramfs, services).
9. Save the raw disk image to `output/`.

### 5 — Flash the image

```bash
# Using Balena Etcher (GUI) — open the .img file from the output/ directory.

# Or using dd (replace /dev/sdX with your target device):
sudo dd if=output/void-linux-encrypted-*.img of=/dev/sdX bs=4M status=progress
```

---

## Configuration reference

### `config/disk.yaml`

| Key | Description | Default |
|-----|-------------|---------|
| `disk_size_mb` | Total disk image size in MiB | `61440` (60 GiB, fits a 64 GB SD) |
| `efi_partition_size_mb` | EFI System Partition size in MiB | `512` |
| `boot_partition_size_mb` | Unencrypted `/boot` partition size in MiB | `512` |
| `swap_size_mb` | Swap logical volume size in MiB | `4096` |

See `examples/` for configurations targeting other device sizes.

### `config/system.yaml`

| Key | Description | Default |
|-----|-------------|---------|
| `hostname` | System hostname | `voidlinux` |
| `username` | Regular user account name | `voiduser` |
| `timezone` | Timezone (from `/usr/share/zoneinfo`) | `UTC` |
| `locale` | glibc locale identifier | `en_US.UTF-8` |
| `keymap` | Console keymap name | `us` |

### Environment variables (passwords)

| Variable | Description |
|----------|-------------|
| `LUKS_PASSWORD` | LUKS1 encryption passphrase |
| `ROOT_PASSWORD` | Password for the `root` account |
| `USER_PASSWORD` | Password for the regular user account |

These are passed to the Docker runtime and are **never** stored in
configuration files or source control.

---

## Customising the installation

Edit `void-installation-script.sh` to customise the installed system —
add packages, configure services, install dotfiles, etc.  The script runs
inside `xchroot` and has full access to `xbps-install` and all standard
VoidLinux tools.

---

## Repository structure

```
.
├── Dockerfile                      VoidLinux container definition
├── docker-compose.yml              Container runtime configuration
├── entrypoint.sh                   Main orchestration script
├── void-installation-script.sh     System configuration script (customise me)
├── config/
│   ├── disk.yaml                   Default disk layout (64 GB micro SD card)
│   └── system.yaml                 Default system configuration
├── examples/
│   ├── disk-16gb-sdcard.yaml
│   ├── disk-64gb-sdcard.yaml
│   ├── disk-128gb-sdcard.yaml
│   └── disk-256gb-sdcard.yaml
├── tools/
│   └── get-device-spec.sh          Auto-generate disk.yaml from a device
└── output/                         (gitignored) flashable images land here
```
