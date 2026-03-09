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
docker compose run --rm --env-file .env void-setup
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
| `disk_size_mb` | `61440` | Total image size (61440 MiB ≈ 60 GiB fits a 64 GB card) |
| `efi_partition_size_mb` | `512` | EFI System Partition (FAT32, `/boot/efi`) |
| `boot_partition_size_mb` | `512` | Unencrypted boot partition (ext4, `/boot`) |
| `swap_size_mb` | `4096` | Swap logical volume inside the encrypted LVM group |

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

Edit `void-installation-script.sh` to add packages, configure services, or
install dotfiles. The script runs inside `xchroot` after the base system is
bootstrapped and has full access to `xbps-install` and all VoidLinux tools.

