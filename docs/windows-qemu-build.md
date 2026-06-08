# Build the image locally on Windows + QEMU

A hands-on local build: boot the Void live ISO in QEMU, log in, paste **one**
command. The repo is shared into the VM over SMB (no seed ISO, no `git clone`,
no binary download in the guest), and the in-VM install reuses the same
`tools/qemu-run-mounted.sh` → `scripts/entrypoint.sh` as every other path.

> Linux users: don't use this — run `bash tools/qemu-build.sh` (fully
> automated, see the README). This page is the **Windows-only** manual path.

---

## Prerequisites (host)

1. **QEMU for Windows** (includes `qemu-system-x86_64.exe` and `qemu-img.exe`),
   default install dir `C:\Program Files\qemu`. https://qemu.weilnetz.de/w64/
2. **Hardware acceleration** (optional but ~10× faster): enable *Windows
   Hypervisor Platform* in "Turn Windows features on or off", and virtualization
   in BIOS. Without it the VM still runs via TCG, just slowly.
3. **A full `void-live` x86_64 ISO — NOT the `-base` flavor.** The `-base` image
   is stripped of `parted`/`cryptsetup`/`lvm2` and the build will fail at
   partitioning. Get a normal live image from https://voidlinux.org/download/.
4. **This repo, with `binaries/` populated.** The installer unpacks Firefox /
   VS Code from `binaries/`. Populate once (WSL or Git-Bash):
   ```sh
   bash tools/fetch-binaries.sh
   ```
5. Your **Windows account username + password** (Windows 11 disables anonymous
   SMB, so the guest authenticates as you).

---

## Automated path (recommended)

From the repo root in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File tools\windows\run-qemu.ps1 -Iso C:\path\to\void-live-x86_64-XXXXXXXX.iso
```

The script:
- creates an SMB share `cvs` of this repo,
- creates a blank `void-vm.raw` (16 GiB) target disk,
- prints **and copies to your clipboard** the exact line to paste in the VM,
- launches QEMU in an interactive window.

Useful options: `-Disk D:\void.raw`, `-DiskSize 32G`, `-Mem 8192`, `-Cpus 6`,
`-ShareName cvs`, `-QemuDir "C:\Program Files\qemu"`.

Then jump to [Inside the VM](#inside-the-vm).

---

## Manual path (equivalent to what the script does)

Run these in PowerShell **as Administrator** (for `New-SmbShare`). Edit paths.

**1. Share the repo over SMB:**
```powershell
New-SmbShare -Name cvs -Path "C:\path\to\crypt-void-setup-container" -ReadAccess "$env:USERNAME"
```

**2. Create the blank target disk:**
```powershell
& "C:\Program Files\qemu\qemu-img.exe" create -f raw void-vm.raw 16G
```

**3. Launch QEMU:**
```powershell
& "C:\Program Files\qemu\qemu-system-x86_64.exe" `
  -accel whpx,kernel-irqchip=off -accel tcg `
  -m 4096 -smp 4 `
  -drive if=virtio,format=raw,file=void-vm.raw `
  -cdrom C:\path\to\void-live-x86_64-XXXXXXXX.iso `
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 `
  -boot d
```

---

## Inside the VM

1. At `void-live login:` log in as **`root`** / **`voidlinux`**.

2. Paste this **one line** (the script prints it pre-filled; here edit
   `YOUR_WINDOWS_PASSWORD`, and `WINUSER` if your account differs). `10.0.2.2`
   is the host as seen from QEMU's user network.

   ```sh
   xbps-install -Suy xbps; xbps-install -Sy cifs-utils; modprobe cifs; mkdir -p /mnt/cvs; mount -t cifs //10.0.2.2/cvs /mnt/cvs -o ro,vers=3.1.1,username=WINUSER,password=YOUR_WINDOWS_PASSWORD && LUKS_PASSWORD=voidlinux ROOT_PASSWORD=voidlinux USER_PASSWORD=voidlinux bash /mnt/cvs/tools/qemu-run-mounted.sh
   ```

   What it does: self-updates `xbps`, installs the one dependency `cifs-utils`,
   mounts the shared repo at `/mnt/cvs`, then runs the installer against
   `/dev/vda`. Change the three passwords to your own if you like.

3. Watch it partition → LUKS → LVM → install base-system → chroot setup. When it
   prints `[run-mounted] ... DONE` (and the installer's final summary), run:
   ```sh
   poweroff
   ```

---

## Get the image onto a USB stick

After poweroff, the host file `void-vm.raw` **is** the full-disk-encrypted,
EFI-bootable image. Write it to a stick (≥ the disk size you chose):

- **Rufus**: pick `void-vm.raw` directly (DD-image mode).
- **WSL / dd**: `sudo dd if=void-vm.raw of=/dev/sdX bs=4M status=progress conv=fsync`
  (verify `/dev/sdX` first — wrong device destroys data).

At boot you'll be asked for the LUKS passphrase (what you set as
`LUKS_PASSWORD`, default `voidlinux`). Change it (`cryptsetup luksChangeKey`)
before any real use.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Guest `mount -t cifs` hangs/times out | Allow **File and Printer Sharing** through Windows Firewall on the active network profile. |
| `mount error(13): Permission denied` | Wrong Windows username/password, or Win11 blocking the account — use your real account creds; ensure the account has a password. |
| `parted: command not found` mid-install | You booted the **`-base`** ISO. Use a full `void-live` image. |
| Firefox/VS Code step fails (`VERSION` missing) | `binaries/` wasn't populated — run `bash tools/fetch-binaries.sh` on the host first. |
| Very slow install | WHPX not active (TCG fallback). Enable Windows Hypervisor Platform + BIOS virtualization. |
| `-accel whpx ... not available` | Harmless — QEMU falls through to `-accel tcg`. |

> The image bakes in whatever passwords you passed (defaults are non-secret
> `voidlinux`). It's fine for trying; rotate them for real use.
