# crypt-void-setup-container

Builds a [VoidLinux](https://voidlinux.org) disk image inside a Docker
container. The image is designed for **x86_64 UEFI systems**, uses
LUKS1+PBKDF2 encryption with LVM inside, keeps `/boot` inside encrypted storage
(Void handbook FDE style), and can be flashed directly to a USB drive or SD
card that will be used as removable storage on that class of machine.

Everything runs in a privileged VoidLinux container. A loopback device is used
during the build so the physical storage device is never touched until you
deliberately flash the finished image.

See [AUDIT.md](./AUDIT.md) for a detailed viability review, boot-path audit,
and the remaining things to verify on real hardware.

---

## Build, flash, and boot

### Prerequisites

- Docker with Compose v2 (or `docker-compose`)
- A Linux host with `loop`, `dm-crypt`, and `lvm` kernel modules available

### 1 — Clone and configure secrets

```bash
git clone https://github.com/AdamBajger/crypt-void-setup-container.git
cd crypt-void-setup-container
mkdir -p output

cp .env.example .env
$EDITOR .env          # set the three required passwords (see .env.example)
```

The build will fail immediately if any of those three values are left empty.

### 2 — Choose the disk layout

Use the default `config/disk.yaml` if you want an image that fits on a typical
64 GB device, or replace it with one of the example layouts:

```bash
# Example: build an image that fits on a 16 GB device
cp examples/disk-16gb-sdcard.yaml config/disk.yaml

# Or edit the layout manually
$EDITOR config/disk.yaml

# Optional: adjust hostname, username, timezone, locale, keymap
$EDITOR config/system.yaml
```

### 3 — (Optional) Auto-generate `disk.yaml` from a physical device

```bash
# Replace /dev/sdX with your target device — do NOT use your system disk!
sudo ./tools/get-device-spec.sh /dev/sdX > config/disk.yaml
```

### 4 — Build the image

```bash
docker compose --env-file .env run --rm void-setup
```

The finished image is saved to `output/void-linux-encrypted-<timestamp>.img`.

### 5 — Flash the image

List the output directory and choose the exact image file you want to write:

```bash
ls -lh output/
```

```bash
# Balena Etcher (GUI): open the .img file from the output/ directory.

# Or with dd (replace IMAGE_FILE and /dev/sdX with the correct values):
sudo dd if=output/IMAGE_FILE.img of=/dev/sdX bs=4M conv=fsync status=progress
```

### 6 — Boot expectations

- The generated image targets **x86_64 UEFI** firmware.
- `grub-install --removable` places the bootloader at the fallback path
  `EFI/BOOT/BOOTX64.EFI`, which is the right layout for removable media.
- `GRUB_ENABLE_CRYPTODISK=y` is enabled so GRUB can unlock the encrypted
  container and read the kernel/initramfs from encrypted `/boot`.
- Secure Boot is **not** configured.
- A real boot test is still required before relying on the image.

---

## Configuration

**`config/disk.yaml`** — partition sizes in MiB (default targets a 64 GB removable device):

| Key | Default | Description |
|-----|---------|-------------|
| `disk_size_mib` | `61440` | Total image size in MiB (61440 MiB = 60 GiB fits a 64 GB card) |
| `efi_partition_size_mib` | `512` | EFI System Partition (FAT32, `/boot/efi`) |
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
| `ROOT_PASSWORD` | Passphrase for the `root` account |
| `USER_PASSWORD` | Passphrase for the regular user account |

---

## Customising the installation

The `scripts/` directory contains three scripts that run in order:

| Script | Runs in | Purpose |
|--------|---------|---------|
| `void-bootstrap.sh` | host (outside chroot) | Installs the base package set into the target rootfs |
| `void-setup-minimal.sh` | inside `xchroot` | Everything required for a bootable system (hostname, locale, fstab, crypttab, dracut, GRUB, users, runit services) |
| `void-setup-extras.sh` | inside `xchroot` | **Your customisations** — extra packages, services, dotfiles, etc. |

To add packages or configuration, edit `scripts/void-setup-extras.sh`.  
To change the base package set installed before the chroot, edit `scripts/void-bootstrap.sh`.  
The minimal setup in `scripts/void-setup-minimal.sh` should rarely need to be changed.
