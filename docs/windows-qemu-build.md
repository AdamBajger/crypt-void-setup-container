# Build the image locally on Windows + QEMU

Boot the Void live ISO in QEMU, log in, run **one** line. This repo is exposed
to the VM as a read-only disk via QEMU's **vvfat** (a host folder shown as a
FAT disk) — so there's **no SMB, no `cifs-utils`, no credentials, and no image
to build**. The in-VM `build.sh` reads `.env` + `config/` from the mounted repo
and runs the same `entrypoint.sh` as every other path.

> Linux users: use `bash tools/qemu-build.sh` (fully automated, see the README).
> This page is the **Windows** path.

---

## Prerequisites (host)

1. **QEMU for Windows** (`qemu-system-x86_64.exe` + `qemu-img.exe`), default
   `C:\Program Files\qemu`. https://qemu.weilnetz.de/w64/
2. **Hardware acceleration** (optional, ~10× faster): enable *Windows Hypervisor
   Platform* in "Turn Windows features on or off" + virtualization in BIOS.
   Without it QEMU falls back to TCG (slow).
3. **A Void live x86_64 ISO** from https://voidlinux.org/download/. Either the
   full or the `-base` flavor works — `build.sh` installs the partitioning tools.
4. **`binaries/` populated** (the installer unpacks Firefox / VS Code from it):
   ```sh
   bash tools/fetch-binaries.sh      # run once in WSL or Git-Bash
   ```
5. **`.env`** with your passwords (optional — defaults to passphrase `voidlinux`):
   ```sh
   cp .env.example .env              # then edit LUKS_PASSWORD / ROOT_PASSWORD / USER_PASSWORD
   ```

Image size is taken from **`config/disk.conf`** (`disk_size_mib`) — authoritative,
no flag. For a ~64 GiB image set `disk_size_mib=65536`. The image fills the whole
disk, so this value is the final image size and must fit your USB stick.

---

## Automated path (recommended)

From the repo root in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File tools\windows\run-qemu.ps1 -Iso C:\path\to\void-live-x86_64-XXXXXXXX.iso
```

It reads `config/disk.conf`, creates `void-vm.raw` at that size, attaches the
repo as a vvfat disk, copies the one in-VM command to your clipboard, and
launches QEMU. Options: `-Disk D:\void.raw`, `-Mem 8192`, `-Cpus 6`,
`-QemuDir "C:\Program Files\qemu"`.

---

## Manual path (equivalent)

```powershell
# 1. blank target disk at the size from config/disk.conf (example: 64000 MiB)
& "C:\Program Files\qemu\qemu-img.exe" create -f raw void-vm.raw 64000M

# 2. launch from the REPO ROOT (cwd matters: vvfat uses 'fat:32:.' = this folder)
cd C:\path\to\crypt-void-setup-container
& "C:\Program Files\qemu\qemu-system-x86_64.exe" `
  -accel whpx,kernel-irqchip=off -accel tcg -m 4096 -smp 4 `
  -drive id=cd,if=none,media=cdrom,readonly=on,file=C:\path\to\void-live.iso `
  -device ide-cd,drive=cd,bootindex=0 `
  -drive id=hd,if=none,format=raw,file=C:\path\to\void-vm.raw `
  -device virtio-blk-pci,drive=hd,bootindex=1 `
  -drive id=repo,if=none,readonly=on,file=fat:32:. `
  -device virtio-blk-pci,drive=repo `
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0
```

---

## Inside the VM

1. At `void-live login:` log in as **`root`** / **`voidlinux`**.
2. Run the one line (the script copied it to your clipboard):
   ```sh
   mount /dev/vdb /mnt && bash /mnt/build.sh
   ```
   `/dev/vdb` is the repo (vvfat). `build.sh` self-updates xbps, installs the
   installer tools, reads `.env` + `config/` from `/mnt`, and installs to
   `/dev/vda`. Nothing else to type.
3. When it prints the final summary, run `poweroff`.

---

## Get the image onto a USB stick

After poweroff, `void-vm.raw` is the full-disk-encrypted, EFI-bootable image.
Write it to a stick (≥ the `disk_size_mib` you chose):

- **Rufus**: select `void-vm.raw` (DD-image mode).
- **WSL / dd**: `sudo dd if=void-vm.raw of=/dev/sdX bs=4M status=progress conv=fsync`
  (verify `/dev/sdX` first — wrong device destroys data).

At boot you're asked for the LUKS passphrase (your `.env` value, default
`voidlinux`). Change it (`cryptsetup luksChangeKey`) before real use.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `mount: /dev/vdb: ... not found` / wrong disk | The repo is the 2nd virtio disk. If devices enumerate oddly, check `lsblk` — the repo is the small FAT disk, the target is the big empty one. |
| `No bootable device` when the VM starts | Boot order — already pinned via `bootindex` in the script; if doing it manually, keep `bootindex=0` on the CD. |
| Firefox/VS Code step fails (`VERSION` missing) | `binaries/` wasn't populated — run `bash tools/fetch-binaries.sh` on the host first. |
| vvfat errors / repo not readable | Make sure QEMU's working dir is the repo root (the script does this with `Push-Location`; manually, `cd` into the repo before launching so `fat:32:.` resolves). |
| Very slow install | WHPX not active (TCG fallback). Enable Windows Hypervisor Platform + BIOS virtualization. |
| `-accel whpx ... not available` | Harmless — QEMU falls through to `-accel tcg`. |

> The image bakes in your `.env` passwords (defaults are non-secret `voidlinux`).
> Fine for trying; rotate them for real use.
