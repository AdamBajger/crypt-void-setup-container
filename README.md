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

The QEMU path is `workflow_dispatch` only because it is slow. It boots the
official Void live ISO's kernel directly (`qemu -kernel/-initrd/-append`,
appending `console=ttyS0,115200n8 live.autologin` so the live system comes up
on the serial console with an autologin shell), then an `expect` script
(`tools/qemu-install.expect`) logs in, launches the seed `autorun.sh`, and
drives the same `install-core.sh` end to end against `/dev/vda`. When the
installer finishes, `autorun.sh` prints a `VOID_INSTALL_RESULT: OK|FAIL`
sentinel to the console that expect keys off. The produced image is then
booted under OVMF; `tools/qemu-verify.expect` types the LUKS passphrase at the
dracut prompt and confirms it boots past decryption.

Reaching the passphrase prompt is the deterministic success signal — it proves
the firmware → GRUB → kernel → initramfs + crypt chain works, which is exactly
what the container path cannot demonstrate.

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
  Installs `qemu-system-x86`, `qemu-utils`, `ovmf`, `xorriso`, `expect`,
  `jq`, etc. (and opens `/dev/kvm` so the runner user can use it), runs the
  same fetch + preflight steps, then drives `tools/qemu-build.sh` which runs
  the install scripts inside the VM with `VOID_DEVICE_BACKEND=raw` and
  `VOID_TARGET_DEVICE=/dev/vda`. Compresses to `output/void-vm.raw.zst` and
  uploads `void-image-qemu-<sha>` (image + `logs/`).

  The QEMU image is a disposable smoke-test artifact: it bakes in fixed,
  **non-secret** credentials (`ci-luks-password-not-secret`, etc. — see
  `tools/qemu-seed-iso.sh`), because the live VM does not inherit the host's
  environment. Do not treat it as a personal install.

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

### Running the QEMU pipeline locally

The QEMU track runs the full end-to-end install inside a VM and then boots the
result. It needs hardware virtualisation (`/dev/kvm`) to finish in a reasonable
time — without KVM it falls back to TCG and takes hours.

Host prerequisites (Debian/Ubuntu names): `qemu-system-x86`, `qemu-utils`,
`ovmf`, `xorriso`, `expect`, `jq`, `gnupg`, `curl`, `zstd`. Confirm KVM with
`kvm-ok` (from `cpu-checker`), and make sure your user can open `/dev/kvm`
(be in the `kvm` group, or `sudo chmod 666 /dev/kvm`).

```sh
bash tools/fetch-binaries.sh           # download + manifest the upstream blobs
bash tools/preflight-verify-binaries.sh
bash tools/qemu-build.sh               # build seed ISO, install in a VM, verify boot
```

The finished image is `output/void-vm.raw`; the live serial logs land in
`logs/qemu-install.log` and `logs/qemu-verify.log`. Useful knobs (env vars):
`QEMU_RAM` (MiB, default 4096), `QEMU_VCPUS` (4), `QEMU_DISK_SIZE` (16G),
`QEMU_INSTALL_TIMEOUT` (3600s). The image uses the fixed non-secret CI
credentials noted above.

### Interactive local install (no seed ISO / no expect)

For a hands-on local build — boot the live ISO yourself, then run one command
inside the VM — use `build.sh` instead of the automated `qemu-build.sh`. It
expects **this repo mounted into the guest** and reuses the same
`entrypoint.sh`; there is no seed image, no `git clone`, and no binary download
(the binaries come from the mounted, already-populated `binaries/`).

One requirement: **populate `binaries/` on the host first**
(`bash tools/fetch-binaries.sh`). Any Void live ISO works — `build.sh` installs
the partitioning tools (`parted`, `cryptsetup`, `lvm2`, …) itself, so the
stripped `-base` flavor is fine.

#### Getting the repo into the guest

The repo reaches the guest as a mounted filesystem — no copy, no clone:

- **Windows host → QEMU vvfat.** A filtered, staged copy of the repo (vvfat
  tops out at ~504 MiB and refuses >2 GiB files, so `.git`, `output/` and
  ISO/raw images are excluded) is shown to the VM as a read-only FAT16 disk
  (`/dev/vdb1`); no SMB, no `cifs-utils`, no credentials, no image build.
  Run **one** command — it boots headless, logs in over a serial console, and
  runs the in-VM build with **no QEMU window and no typing inside the VM**:
  ```powershell
  pwsh -File tools\windows\run-qemu.ps1
  ```
  Full walkthrough (modes `probe`/`interactive`, `-VerifyBoot`) in
  **[docs/windows-qemu-build.md](docs/windows-qemu-build.md)**. The driver runs
  the same one line you'd type by hand: `mount /dev/vdb1 /repo && bash
  /repo/build.sh` (`/repo`, not `/mnt` — the installer mounts the target at
  `/mnt/void-install`).

- **Linux / WSL2 host → 9p (`-virtfs`).** Add to the qemu line:
  `-virtfs local,path=$PWD,mount_tag=cvs,security_model=none,readonly=on`; in the
  guest: `modprobe 9pnet_virtio; mount -t 9p -o trans=virtio,version=9p2000.L,ro cvs /mnt && bash /mnt/build.sh`.

`build.sh` installs the installer tools, reads `.env` + `config/` from the
mounted repo, and runs the install against `/dev/vda`. When it finishes, the
target disk (`void-vm.raw`) is the etchable image. (`build.sh` wraps
`tools/qemu-run-mounted.sh`, which is mount-method agnostic.)

## Build/Run notes

- Each install run starts from scratch.
- On error, the run is torn down (mounts unwound, LVM deactivated, LUKS
  closed, loop devices detached, partial image left only if it would still
  be useful for debugging — see `device_finalize`).
- There is no reuse between runs.
