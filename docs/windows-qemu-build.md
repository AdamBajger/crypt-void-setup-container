# Build the image locally on Windows + QEMU

Run **one** PowerShell command. It boots the Void live kernel headless, logs in
over a serial console, runs the in-VM build, and streams the whole session to
your terminal — **no QEMU window, no typing inside the VM**. This repo is exposed
to the guest as a read-only disk via QEMU's **vvfat** (a host folder shown as a
FAT disk), so there's **no SMB, no `cifs-utils`, no credentials, and no image to
build separately**. The in-VM `build.sh` reads `.env` + `config/` from the
mounted repo and runs the same `entrypoint.sh` as every other path.

> Linux users: use `bash tools/qemu-build.sh` (fully automated, see the README).
> This page is the **Windows** path.

---

## Prerequisites (host)

1. **QEMU for Windows** (`qemu-system-x86_64.exe` + `qemu-img.exe`), default
   `C:\Program Files\qemu`. https://qemu.weilnetz.de/w64/
2. **PowerShell 7+** (`pwsh`). The script uses .NET process APIs that Windows
   PowerShell 5.1 (`powershell.exe`) lacks, so invoke it with `pwsh`.
3. **Hardware acceleration** (~10× faster): enable *Windows Hypervisor Platform*
   in "Turn Windows features on or off" + virtualization in BIOS. Without it
   QEMU falls back to TCG (slow). The script logs `Windows Hypervisor Platform
   accelerator is operational` when WHPX is active.
4. **A Void live x86_64 ISO** from https://voidlinux.org/download/. Either the
   full or the `-base` flavor works — `build.sh` installs the partitioning tools.
   Drop it in `tools\` or `binaries\void-iso\` and the script auto-detects it,
   or pass `-Iso <path>`.
5. **`binaries/` populated** (the installer unpacks Firefox / VS Code from it):
   ```sh
   bash tools/fetch-binaries.sh      # run once in WSL or Git-Bash
   ```
6. **`.env`** with your passwords (optional — defaults to passphrase `voidlinux`):
   ```sh
   cp .env.example .env              # then edit LUKS_PASSWORD / ROOT_PASSWORD / USER_PASSWORD
   ```

Image size is taken from **`config/disk.conf`** (`disk_size_mib`) — authoritative,
no flag. The full KDE6 + LibreOffice + dev-tools set needs room: **`16384` MiB is
the smallest that fits**; for a real USB target set e.g. `disk_size_mib=65536`.
The image fills the whole disk, so this value is the final image size and must
fit your stick.

---

## Build (default, automated, headless)

From the repo root:

```powershell
pwsh -File tools\windows\run-qemu.ps1
```

That's it. The script:

1. reads `config/disk.conf` and creates `void-vm.raw` at that size,
2. stages a vvfat-safe copy of the repo (see below),
3. extracts the live kernel + initrd from the ISO with Windows' built-in `tar`
   (bsdtar reads ISO9660 — no extra tooling),
4. boots QEMU **headless** with a serial console + autologin, drives the login
   and the in-VM `build.sh` over a local TCP serial link, and mirrors everything
   to the console and `logs\windows-build.log`,
5. powers the guest off when it sees the build's success sentinel.

When it prints `BUILD OK`, `void-vm.raw` is your etchable image.

Options: `-Iso <path>` (else auto-detected), `-Disk D:\void.raw`, `-Mem 8192`,
`-Cpus 6`, `-QemuDir "C:\Program Files\qemu"`, `-TimeoutSec <s>` (build budget,
default 5400), `-VerifyBoot` (boot the result under OVMF afterwards, below),
`-ExtraArgs` (raw QEMU args).

### Other modes (`-Mode`)

| Mode | What it does |
|---|---|
| `build` *(default)* | The headless automated build above. |
| `probe` | Same boot, but only dumps `lsblk`/`blkid`, mount-tests the repo at `/dev/vdb1`, and powers off. ~1 min sanity check of vvfat + serial before a long build. |
| `interactive` | Opens a normal QEMU **window**, boots the ISO's GRUB menu. Log in `root` / `voidlinux` and run the one line it prints (also copied to your clipboard): `mkdir -p /repo && mount /dev/vdb1 /repo && bash /repo/build.sh`. For when you want eyes on it. |
| `verify` | Boots an existing `void-vm.raw` under OVMF and checks it unlocks LUKS and reaches userspace (see next section). Does **not** build. |

### Why the script stages a copy

QEMU's vvfat drive is a fixed **~504 MiB** virtual FAT disk and **refuses any
file larger than 2 GiB** — exposing the repo as-is fails the moment
`void-vm.raw`, the live ISO, or an `output/` image is in it. The script
robocopies the repo to `%TEMP%\crypt-void-vvfat-stage`, excluding `.git`,
`output/`, `logs/` and `*.iso`/`*.raw`/`*.img`/`*.bak`, checks the result fits,
and points vvfat at the copy. The build needs ~330 MiB (scripts, config, `.env`,
Firefox + VS Code tarballs) — the 1 GiB live ISO under `binaries/void-iso/` is
only used by the CI path and is deliberately left out.

---

## Verify the produced image boots (UEFI/OVMF)

```powershell
pwsh -File tools\windows\run-qemu.ps1 -VerifyBoot       # build, then verify in one go
pwsh -File tools\windows\run-qemu.ps1 -Mode verify      # verify an existing void-vm.raw (no build)
```

`-VerifyBoot` boots `void-vm.raw` under OVMF firmware (`edk2-x86_64-code.fd` from
the QEMU `share\` dir; a blank NVRAM store is created automatically), headless,
and supplies the **LUKS passphrase from your `.env`** at GRUB's and dracut's
prompts over the serial console. It prints `VERIFY OK` once the system reaches
userspace.

---

## Get the image onto a USB stick

After a successful build, `void-vm.raw` is the full-disk-encrypted, EFI-bootable
image. Write it to a stick (≥ the `disk_size_mib` you chose):

- **Rufus**: select `void-vm.raw` (DD-image mode).
- **WSL / dd**: `sudo dd if=void-vm.raw of=/dev/sdX bs=4M status=progress conv=fsync`
  (verify `/dev/sdX` first — wrong device destroys data).

At boot you're asked for the LUKS passphrase (your `.env` value, default
`voidlinux`). Change it (`cryptsetup luksChangeKey`) before real use.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Could not connect to QEMU serial` | QEMU failed to start (bad ISO path, port in use). Check the `qemu: ...` line the script echoes; try another `-SerialPort`. |
| Login never completes / build never starts | A serial send-race; the driver retries the login marker every 60 s and self-heals. If it truly stalls, re-run (the boot is cheap). |
| `Package 'X' not found in repository pool` | The chroot used the wrong/empty repo. Fixed: the extras step now pins `--repository`/`XBPS_ARCH` like the base step. Ensure `VOID_XBPS_REPOSITORY` in `.env` is a live mirror. |
| `No space left on device` during extras | `disk_size_mib` too small — the full desktop needs ≥ `16384` MiB. Raise it in `config/disk.conf` and delete the old `void-vm.raw`. |
| `mount: /dev/vdb1: ... not found` / wrong disk | The repo is the 2nd virtio disk, partition 1 (FAT16, label `QEMU VVFAT`); the target is the big empty disk. Run `-Mode probe` to confirm enumeration. |
| `File ... is larger than 2GB` at QEMU start | vvfat refuses files over 2 GiB. The script stages a filtered copy; if running QEMU by hand, keep big images out of the staged dir. |
| Firefox/VS Code step fails (`VERSION` missing) | `binaries/` wasn't populated — run `bash tools/fetch-binaries.sh` on the host first. |
| Very slow install | WHPX not active (TCG fallback). Enable Windows Hypervisor Platform + BIOS virtualization. |
| `-accel whpx ... not available` | Harmless — QEMU falls through to `-accel tcg`. |

> The image bakes in your `.env` passwords (defaults are non-secret `voidlinux`).
> Fine for trying; rotate them for real use.
