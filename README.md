# crypt-void-setup-container

Builds a fully encrypted [VoidLinux](https://voidlinux.org) disk image inside a
Docker container. The image is EFI-bootable, uses LUKS1+PBKDF2 encryption with
LVM inside, and can be flashed directly to a micro SD card or USB drive.

Everything runs in a privileged VoidLinux container. A loopback device is used
during the build so the physical storage device is never touched until you
deliberately flash the finished image.

---

## Quick start

### Prerequisites

- Docker with Compose v2 (or `docker-compose`)
- A Linux host with `loop`, `dm-crypt`, and `lvm` kernel modules available

### 1 — Clone and configure

```bash
git clone https://github.com/AdamBajger/crypt-void-setup-container.git
cd crypt-void-setup-container
mkdir -p output

cp .env.example .env
$EDITOR .env          # set LUKS_PASSWORD, ROOT_PASSWORD, USER_PASSWORD

# Optional: adjust partition sizes
$EDITOR config/disk.yaml

# Optional: adjust hostname, username, timezone, locale, keymap
$EDITOR config/system.yaml
```

### 2 — (Optional) Auto-generate disk.yaml from a physical device

```bash
# Replace /dev/sdX with your target device — do NOT use your system disk!
sudo ./tools/get-device-spec.sh /dev/sdX > config/disk.yaml
```

### 3 — Build and run

```bash
docker compose --env-file .env run --rm void-setup
```

The finished image is saved to `output/void-linux-encrypted-<timestamp>.img`.

### 4 — Flash the image

```bash
# Balena Etcher (GUI): open the .img file from the output/ directory.

# Or with dd (replace /dev/sdX with your target device):
sudo dd if=output/void-linux-encrypted-*.img of=/dev/sdX bs=4M status=progress
```

---

## Configuration

**`config/disk.yaml`** — partition sizes in MiB (default targets a 64 GB micro SD card):

| Key | Default | Description |
|-----|---------|-------------|
| `disk_size_mib` | `61440` | Total image size in MiB (61440 MiB = 60 GiB fits a 64 GB card) |
| `efi_partition_size_mib` | `512` | EFI System Partition (FAT32, `/boot/efi`) |
| `boot_partition_size_mib` | `512` | Unencrypted boot partition (ext4, `/boot`) |
| `swap_size_mib` | `4096` | Swap logical volume inside the encrypted LVM group |

See `examples/` for pre-computed sizes for 16 GB, 128 GB, and 256 GB devices.

**`config/system.yaml`** — installed system settings:

| Key | Default | Description |
|-----|---------|-------------|
| `hostname` | `voidlinux` | System hostname |
| `username` | `voiduser` | Regular user account name |
| `timezone` | `UTC` | Timezone from `/usr/share/zoneinfo` |
| `locale` | `en_US.UTF-8` | glibc locale identifier |
| `keymap` | `us` | Console keymap |

**Environment variables** (set in `.env`, never committed):

| Variable | Description |
|----------|-------------|
| `LUKS_PASSWORD` | LUKS1 encryption passphrase |
| `ROOT_PASSWORD` | Password for the `root` account |
| `USER_PASSWORD` | Password for the regular user account |

---

## Customising the installation

The `scripts/` directory contains four scripts that run in order:

| Script | Runs in | Purpose |
|--------|---------|---------|
| `void-bootstrap.sh` | host (outside chroot) | Installs the base package set into the target rootfs |
| `void-installation-script.sh` | inside `xchroot` | Orchestrator — calls the two scripts below |
| `void-setup-minimal.sh` | inside `xchroot` | Everything required for a bootable system (hostname, locale, fstab, crypttab, dracut, GRUB, users, runit services) |
| `void-setup-extras.sh` | inside `xchroot` | **Your customisations** — extra packages, services, dotfiles, etc. |

To add packages or configuration, edit `scripts/void-setup-extras.sh`.  
To change the base package set installed before the chroot, edit `scripts/void-bootstrap.sh`.  
The minimal setup in `scripts/void-setup-minimal.sh` should rarely need to be changed.
