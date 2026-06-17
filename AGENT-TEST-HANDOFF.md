# Handoff: test the Windows + QEMU local build path

You are a coding agent running **locally on the user's machine** (Windows host
with QEMU, or WSL2). Your job: **test and, if needed, fix** the interactive
local-build path of this repo, then report results. The headless CI path is
already verified green — do **not** touch it. Focus only on the Windows/vvfat
local path.

## Repo

- GitHub: `AdamBajger/crypt-void-setup-container`
- Branch: **`qemu-pipeline-finish`** (work here; PR #7 open to `master`)
- Make changes here, commit logically, push to that branch. Do not touch
  `master`, `.github/workflows/`, `tools/qemu-build.sh`, or the seed/expect
  files (those are the CI path).

## What this repo does

Builds a KDE6, full-disk-encrypted (LUKS1 + LVM) Void Linux raw disk image.
The installer (`scripts/entrypoint.sh` → `install-core.sh` → `void-setup-*.sh`)
is backend-agnostic. Two paths drive it:
- **CI / Linux:** `tools/qemu-build.sh` (seed ISO + `expect`) — verified, leave alone.
- **Local Windows (under test):** boot the Void live ISO in QEMU, expose this
  repo to the guest as a read-only disk via **QEMU vvfat** (`/dev/vdb`), then in
  the VM run one line that installs to `/dev/vda` (the produced image).

Key files for your path:
- `tools/windows/run-qemu.ps1` — host launcher (sizes disk, attaches vvfat, boots).
- `build.sh` (repo root) — in-VM entry: installs tools, runs the installer.
- `tools/qemu-run-mounted.sh` — wires paths, reads `.env` + `config/`, runs `entrypoint.sh`.
- `config/disk.conf` — **authoritative image size** (`disk_size_mib`).
- `.env` (copy from `.env.example`) — LUKS/root/user passwords (default `voidlinux`).

## Goal / success criteria

1. **Build:** the in-VM command completes and prints the installer's final
   summary; `void-vm.raw` is produced on the host.
2. **Boots:** the produced image boots under UEFI (OVMF), unlocks LUKS, reaches
   userspace.

## Setup (host, once)

1. Install **QEMU for Windows** (`qemu-system-x86_64.exe`, `qemu-img.exe`;
   default `C:\Program Files\qemu`). Enable *Windows Hypervisor Platform* for
   speed (else it's slow TCG).
2. Get a **Void live x86_64 ISO** (any flavor; `-base` is fine).
3. From the repo root, populate binaries and create `.env` (use WSL or Git-Bash
   for the bash script):
   ```sh
   bash tools/fetch-binaries.sh
   cp .env.example .env        # optionally edit passwords
   ```
4. Set the image size in `config/disk.conf` (`disk_size_mib`, MiB). Keep it
   small for fast iteration (e.g. `disk_size_mib=8192`).

## Test 1 — build

```powershell
powershell -ExecutionPolicy Bypass -File tools\windows\run-qemu.ps1 -Iso C:\path\to\void-live.iso
```
A QEMU window opens and boots the live ISO. Log in `root` / `voidlinux`, then:
```sh
mount /dev/vdb /mnt && bash /mnt/build.sh
```
Watch for: xbps installs → partition → LUKS → LVM → base-system → chroot setup
→ Firefox/VS Code unpack → GRUB → final summary. Then `poweroff`.

**Capture on failure:** the QEMU console text, plus inside the VM before the
error: `lsblk`, `blkid`, `ls -la /mnt`, `dmesg | tail`, and the failing command's
output. Also the `qemu: ...` line the script echoes.

## Test 2 — verify the produced image boots (UEFI/OVMF)

```powershell
& "C:\Program Files\qemu\qemu-system-x86_64.exe" -machine q35 -m 4096 `
  -drive if=pflash,format=raw,readonly=on,file="C:\Program Files\qemu\share\edk2-x86_64-code.fd" `
  -drive if=pflash,format=raw,file="C:\Program Files\qemu\share\edk2-x86_64-vars.fd" `
  -drive if=virtio,format=raw,file=void-vm.raw
```
Expect: GRUB → a LUKS passphrase prompt (enter your `.env` value, default
`voidlinux`) → kernel → SDDM / login. (OVMF filenames vary; if those `.fd`
paths are absent, find the edk2 firmware in the QEMU `share\` dir.)

## Known-fragile points (most likely failures + fixes)

- **vvfat path parsing.** `run-qemu.ps1` uses `-drive file=fat:32:.` with
  `Push-Location $Repo` so the path has no drive-letter colon. If vvfat errors,
  confirm QEMU's working dir is the repo root. This whole mechanism is **untested
  on Windows by the previous agent** — it's the most likely thing to need fixing.
- **`/dev/vdb` is not the repo.** Two virtio disks: target (`/dev/vda`, big,
  empty) and repo (vvfat, small, FAT). If enumeration differs, identify the FAT
  disk via `lsblk -f` / `blkid` and adjust the mount (and the docs).
- **vvfat read-only / FAT limits.** The repo incl. `binaries/` is exposed
  read-only as FAT32. If large files or long names misbehave, consider excluding
  `binaries/void-iso/` from what's exposed, or switch delivery (see fallbacks).
- **"No bootable device" at VM start.** Boot order — the script pins `bootindex`
  (CD=0). If it recurs, verify the CD device has `bootindex=0`.
- **Slow install.** WHPX inactive → TCG. Enable Windows Hypervisor Platform.
- **Firefox/VS Code step fails (`VERSION` missing).** `binaries/` not populated.

### Fallbacks if vvfat proves unworkable on this Windows build
- **SMB:** Windows shares the repo; guest installs `cifs-utils` and mounts
  `//10.0.2.2/<share>`. (This was the prior approach; more in-VM steps.)
- **WSL2 + 9p:** run QEMU from WSL2 with
  `-virtfs local,path=$PWD,mount_tag=cvs,security_model=none,readonly=on`; guest
  `mount -t 9p -o trans=virtio,version=9p2000.L,ro cvs /mnt && bash /mnt/build.sh`.
Pick whichever actually works on the user's setup; update `run-qemu.ps1` +
`docs/windows-qemu-build.md` to match.

## Working method

- Iterate: run → capture exact errors → form a hypothesis → make the **smallest**
  change → re-run. One variable at a time.
- Keep `config/disk.conf` as the single source of truth for image size; do not
  add per-run size overrides. Do not have scripts overwrite `config/disk.conf`.
- Reuse `scripts/entrypoint.sh` and friends — don't fork the install logic.
- Commit each fix with a clear message; push to `qemu-pipeline-finish`.
- Report back: what you ran, what failed, the fix, and a final
  "build OK / boots OK" with the evidence (console excerpts).

## Reference

- `README.md` → "Local usage" / "Interactive local install".
- `docs/windows-qemu-build.md` → the user-facing Windows walkthrough.
