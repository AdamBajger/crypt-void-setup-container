<#
.SYNOPSIS
    Spin up a Void Linux live VM with QEMU on Windows, expose this repo to the
    guest as a read-only disk (vvfat), and boot the live ISO.

.DESCRIPTION
    Host side of the interactive Windows+QEMU local build:
      1. Reads the image size from config/disk.conf and creates the target disk.
      2. Launches QEMU booting the live ISO, with this repo attached as a disk
         via QEMU's vvfat (no SMB, no cifs-utils, no credentials, no image build).

    Inside the VM you log in (root / voidlinux) and run ONE line:

        mount /dev/vdb /mnt && bash /mnt/build.sh

    build.sh reads .env + config/ from the mounted repo and installs to /dev/vda.
    When it finishes, the target disk (void-vm.raw) is the etchable image.

    See docs/windows-qemu-build.md for the full walkthrough.

.PARAMETER Iso
    Path to a Void live x86_64 ISO. build.sh installs the partitioning tools
    itself, so either the full or the "-base" flavor works.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\windows\run-qemu.ps1 `
        -Iso C:\isos\void-live-x86_64-20250202.iso
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$Iso,
    [string]$Repo    = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    [string]$Disk    = (Join-Path (Get-Location) "void-vm.raw"),
    [int]   $Mem     = 4096,
    [int]   $Cpus    = 4,
    [string]$QemuDir = "C:\Program Files\qemu"
)

$ErrorActionPreference = "Stop"

# --- locate QEMU ------------------------------------------------------------
$qemu = Join-Path $QemuDir "qemu-system-x86_64.exe"
$qimg = Join-Path $QemuDir "qemu-img.exe"
foreach ($exe in @($qemu, $qimg)) {
    if (-not (Test-Path $exe)) { throw "Not found: $exe  (install QEMU for Windows or pass -QemuDir)" }
}

# --- validate + make paths absolute (vvfat runs with cwd = repo) ------------
$Iso  = (Resolve-Path $Iso).Path
$Repo = (Resolve-Path $Repo).Path
if (-not [System.IO.Path]::IsPathRooted($Disk)) { $Disk = Join-Path (Get-Location).Path $Disk }
if (-not (Test-Path (Join-Path $Repo "build.sh"))) {
    throw "Repo at '$Repo' is missing build.sh — pass -Repo <repo root>"
}
if (-not (Test-Path (Join-Path $Repo "binaries\firefox-developer"))) {
    Write-Warning "binaries/ looks unpopulated. Run 'bash tools/fetch-binaries.sh' (e.g. in WSL/Git-Bash) first, or the Firefox/VS Code step will fail."
}
if (-not (Test-Path (Join-Path $Repo ".env"))) {
    Write-Warning "No .env found. Copy .env.example to .env and fill the passwords, otherwise the install uses the default passphrase 'voidlinux'."
}

# --- target disk: size is config/disk.conf's disk_size_mib (authoritative) --
# The image fills the whole disk (LUKS = 100%, root = 100%FREE), so this IS the
# final image size. disk.conf is read, never written; no per-run override.
$diskConf = Join-Path $Repo "config\disk.conf"
if (-not (Test-Path $diskConf)) { throw "config/disk.conf not found at $diskConf" }
if ((Get-Content $diskConf -Raw) -notmatch '(?m)^\s*disk_size_mib\s*=\s*(\d+)') {
    throw "disk_size_mib is not set in config/disk.conf"
}
$diskMiB = [int]$Matches[1]
if ($diskMiB -lt 5120) {
    throw "disk_size_mib ($diskMiB) is too small — need at least ~5120 MiB (EFI + swap + a usable root)."
}
Write-Host "Image size: $diskMiB MiB (config/disk.conf disk_size_mib)"
if (Test-Path $Disk) {
    Write-Warning "Target disk $Disk already exists — leaving it as-is. Delete it to resize to $diskMiB MiB."
} else {
    & $qimg create -f raw $Disk "${diskMiB}M" | Out-Null
    Write-Host "Created blank target disk: $Disk ($diskMiB MiB; sparse — grows as written)"
}

# --- the single in-VM command ----------------------------------------------
$guest = "mount /dev/vdb /mnt && bash /mnt/build.sh"
try { Set-Clipboard -Value $guest } catch {}
Write-Host ""
Write-Host "==== In the VM: log in as root / voidlinux, then run (copied to clipboard): ====" -ForegroundColor Cyan
Write-Host "    $guest" -ForegroundColor Yellow
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host ""

# --- launch QEMU ------------------------------------------------------------
# Devices:
#   /dev/sr0  live ISO (cdrom, bootindex 0 -> booted)
#   /dev/vda  target image disk (bootindex 1)
#   /dev/vdb  THIS repo, read-only, via vvfat (host dir shown as a FAT disk)
# vvfat path must be relative (its option parser splits on ':', so a Windows
# drive-letter path breaks it) — we set cwd to the repo and pass '.'.
# whpx = Windows Hypervisor Platform (fast); falls back to tcg if absent.
$qemuArgs = @(
    "-accel", "whpx,kernel-irqchip=off", "-accel", "tcg",
    "-m", "$Mem", "-smp", "$Cpus",
    "-drive", "id=cd,if=none,media=cdrom,readonly=on,file=$Iso",
    "-device", "ide-cd,drive=cd,bootindex=0",
    "-drive", "id=hd,if=none,format=raw,file=$Disk",
    "-device", "virtio-blk-pci,drive=hd,bootindex=1",
    "-drive", "id=repo,if=none,readonly=on,file=fat:32:.",
    "-device", "virtio-blk-pci,drive=repo",
    "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0"
)
Push-Location $Repo   # so 'fat:32:.' resolves to the repo
try {
    Write-Host "Launching QEMU (close the window or 'poweroff' in the guest when done)..." -ForegroundColor Green
    Write-Host "qemu: `"$qemu`" $($qemuArgs -join ' ')" -ForegroundColor DarkGray
    & $qemu @qemuArgs
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "QEMU exited. If the install finished, '$Disk' is your etchable image." -ForegroundColor Green
Write-Host "Etch with Rufus (select the raw image) or 'dd' from WSL. LUKS passphrase = your .env value (default 'voidlinux')."
