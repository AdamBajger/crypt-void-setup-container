# crypt-void-setup-container

## Overview

A Docker-driven pipeline that produces a fully pre-installed, KDE6, full-disk-
encrypted (LUKS1 + LVM) Void Linux raw disk image. The output is a single
USB-flashable, EFI-bootable `.img` (compressed as `.img.zst`). Two CI tracks
build it: a fast container path (`build-image-container.yml`, runs on every
push/PR) and an end-to-end QEMU path (`build-image-qemu.yml`, manual) that
boots a real Void live ISO and runs the same install scripts against a
virtio-blk disk.

## Architecture

The installer is split into a thin orchestrator, a device-agnostic install
core, and one of two interchangeable device backends:

```
scripts/entrypoint.sh        - thin orchestrator: loads config, picks backend,
                               runs the install sequence, traps cleanup
scripts/install-core.sh      - device-agnostic install phases (partition,
                               LUKS, LVM, mkfs, mount, xbps, chroot stages)
scripts/device-loop.sh       - backend adapter: loopback file in /output
scripts/device-raw.sh        - backend adapter: caller-supplied block device
scripts/void-setup-minimal.sh- chroot stage 1 (hostname, locale, users,
                               fstab, dracut, GRUB)
scripts/void-setup-extras.sh - chroot stage 2 (xbps extras, Firefox/VS Code
                               unpack, firstboot service install)
scripts/firstboot.sh         - runs once on first real boot to install
                               Flatpaks (needs DBus + network)
scripts/firstboot-runit-run  - runit `run` script that drives firstboot.sh
```

### Adapter contract

Both backends implement the same four functions, sourced by `entrypoint.sh`:

```
device_acquire             - obtain a block device path; export VOID_DEVICE
device_resolve_partitions  - after partitioning, expose VOID_EFI_PARTITION
                             and VOID_LUKS_PARTITION block paths
device_release             - reverse device_acquire (called from cleanup)
device_finalize <ok>       - post-success housekeeping (e.g. rename image)
```

`install-core.sh` only ever operates on the paths placed in `VOID_DEVICE`,
`VOID_EFI_PARTITION`, and `VOID_LUKS_PARTITION`. It does not know whether
those are loop devices or real block devices.

### Backends

`loop` (default, used by `build-image-container.yml`):

- `truncate` a sparse file at `/output/voidlinux_fde_<arch>_<ts>.img`.
- `losetup --partscan` to attach the file as `/dev/loopN`.
- Because container kernels often do not auto-create `/dev/loopNpX` partition
  nodes, partitions are exposed as **separate offset/sizelimit loop devices**
  derived from `parted -ms ... unit s print`. See `device_resolve_partitions`
  in `scripts/device-loop.sh`.
- On success `device_finalize` renames the image to its final name.

`raw` (used by `build-image-qemu.yml`):

- The caller (the QEMU VM script) hands in `VOID_TARGET_DEVICE=/dev/vda`.
  No `losetup` is involved.
- `partprobe + udevadm settle` after partitioning; partition nodes are then
  `${dev}p${n}` for `loop|nvme|mmcblk` style names, otherwise `${dev}${n}`.
- `device_finalize` is a no-op: the host-side raw file backing the QEMU
  virtio disk **is** the etchable artifact.

### Environment contract

Required:

```
LUKS_PASSWORD     - LUKS1 passphrase
ROOT_PASSWORD     - password for root on the installed system
USER_PASSWORD     - password for the regular user on the installed system
```

Backend selection:

```
VOID_DEVICE_BACKEND={loop|raw}   default: loop
VOID_TARGET_DEVICE=<path>        required when VOID_DEVICE_BACKEND=raw
                                 (typically /dev/vda inside the QEMU VM)
```

Optional:

```
VOID_XBPS_REPOSITORY=<url>       default: https://repo-default.voidlinux.org/current
```

### Why two paths

The container path runs on every push/PR for fast feedback. It cannot prove
the produced image actually boots, and Flatpak installs are deferred to a
runit `firstboot` service that completes on the user's first real boot.

The QEMU path is `workflow_dispatch` only because it is slow. It boots an
official Void live ISO under OVMF and drives the same `install-core.sh` end
to end, then can boot the produced image to verify it actually works. It is
also the natural place to let the Flatpak first-boot service run to
completion in CI rather than on the user's machine.

## Binary supply chain

`tools/fetch-binaries.sh` resolves and downloads:

- Firefox Developer Edition (`binaries/firefox-developer/`) — version pulled
  from `product-details.mozilla.org`, plus `KEY`, `SHA512SUMS`,
  `SHA512SUMS.asc`.
- VS Code stable Linux x64 (`binaries/vscode/`) — resolved via
  `update.code.visualstudio.com` JSON, plus a `SHA256` sidecar.
- Void Linux live x86_64 ISO (`binaries/void-iso/`) — newest `void-live-x86_64-*`
  from the official mirror, plus `KEY`, `sha256sum.txt`, `sha256sum.sig`.

It writes `binaries/manifest.json` with the resolved versions, URLs,
filenames, and expected hashes.

`tools/preflight-verify-binaries.sh` runs before any build and enforces the
chain `KEY → signature → checksum → file` for Firefox and the Void ISO, and
`manifest hash → SHA256 sidecar → file` for VS Code. Any missing file,
signature mismatch, or checksum mismatch is fatal.

Both CI workflows cache `binaries/` keyed on the hash of `tools/fetch-binaries.sh`.

## CI

Two parallel workflows build the image:

- `.github/workflows/build-image-container.yml` — privileged Docker pipeline.
  Runs on push to `main`/`master`, on PRs, and on `workflow_dispatch`.
  Installs host tools (`jq`, `gpg`, `xz-utils`, `curl`, `zstd`, `parted`,
  `file`), runs `tools/fetch-binaries.sh` (cached) and `preflight-verify-binaries.sh`,
  builds `void-installer:ci` from the `Dockerfile`, runs it `--privileged`
  against the mounted `config/`, `scripts/`, `tools/`, `binaries/` and an
  empty `output/`, verifies the produced raw image with `parted` and `file`,
  compresses it with `zstd -19 -T0`, and uploads
  `void-image-container-<sha>` (image + logs, 14-day retention).

- `.github/workflows/build-image-qemu.yml` — `workflow_dispatch` only.
  Installs `qemu-system-x86`, `ovmf`, `xorriso`, `expect`, `socat`, etc.,
  runs the same fetch + preflight steps, then drives `tools/qemu-build.sh`
  which boots the live ISO under OVMF and runs the install scripts inside
  the VM with `VOID_DEVICE_BACKEND=raw` and `VOID_TARGET_DEVICE=/dev/vda`.
  Compresses to `output/void-vm.raw.zst` and uploads
  `void-image-qemu-<sha>`.

### Downloading the artifact

Open the repository on GitHub, go to the **Actions** tab, pick the latest
run of the workflow you want, and download the
`void-image-container-<sha>` (or `void-image-qemu-<sha>`) artifact from the
run summary page.

### Flashing to USB

Decompress and write the image to your USB stick. **Verify `/dev/sdX` is the
correct device first** (e.g. with `lsblk`); writing to the wrong device will
destroy data.

```sh
zstd -d void-image.raw.zst
sudo dd if=void-image.raw of=/dev/sdX bs=4M status=progress conv=fsync
```

## Configuration

```
config/disk.conf             - target disk geometry (sizes in MiB)
config/system.conf           - hostname, username, timezone, locale, keymap
config/extra-packages.txt    - xbps packages installed in the chroot stage;
                               also carries the `# flatpak:` block read by
                               firstboot.sh
examples/disk-16gb-sdcard.conf
examples/disk-64gb-sdcard.conf
examples/disk-128gb-sdcard.conf
examples/qemu-vm.conf        - disk.conf used by the QEMU CI track
tools/get-device-spec.sh     - generates a disk.conf from a real device,
                               run on the HOST against /dev/sdX
```

## Local usage

Copy `.env.example` to `.env`, fill in the three password variables, then:

```sh
docker compose up --build
```

Required `.env` variables:

```
LUKS_PASSWORD=...
ROOT_PASSWORD=...
USER_PASSWORD=...
VOID_XBPS_REPOSITORY=https://repo-default.voidlinux.org/current   # optional
```

The container runs `--privileged` (needed for loop devices, dm-crypt, LVM)
and writes the output image to `./output/`.

## Build/Run notes

- Each install run starts from scratch.
- On error, the run is torn down (mounts unwound, LVM deactivated, LUKS
  closed, loop devices detached, partial image left only if it would still
  be useful for debugging — see `device_finalize`).
- There is no reuse between runs.
