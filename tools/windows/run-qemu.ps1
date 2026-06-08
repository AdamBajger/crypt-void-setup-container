<#
.SYNOPSIS
    Spin up a Void Linux live VM with QEMU on Windows, share this repo into the
    guest over SMB, and prepare the single command to paste inside the VM.

.DESCRIPTION
    Automates the host side of the interactive Windows+QEMU local build:
      1. Creates (idempotently) an SMB share of this repo.
      2. Creates a blank raw target disk if missing.
      3. Prints + copies the guest paste-line (mount the share, run the installer).
      4. Launches QEMU in an interactive window booting the live ISO.

    You log in inside the VM (root / voidlinux) and paste the prepared line.
    When it finishes, the target disk (void-vm.raw) is the etchable image.

    See docs/windows-qemu-build.md for the full walkthrough.

.PARAMETER Iso
    Path to a FULL void-live x86_64 ISO (NOT the stripped "-base" flavor — the
    installer needs parted/cryptsetup/lvm2, which -base omits).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\windows\run-qemu.ps1 `
        -Iso C:\isos\void-live-x86_64-20250202.iso
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$Iso,
    [string]$Repo        = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    [string]$Disk        = (Join-Path (Get-Location) "void-vm.raw"),
    # Optional override of the image size, in GiB. If omitted (0), the size is
    # read from config/disk.conf (disk_size_mib) — that file is the single
    # source of truth and is never modified by this script.
    [int]   $DiskSizeGiB = 0,
    [string]$ShareName   = "cvs",
    [int]   $Mem         = 4096,
    [int]   $Cpus        = 4,
    [string]$QemuDir     = "C:\Program Files\qemu"
)

$ErrorActionPreference = "Stop"

# --- locate QEMU ------------------------------------------------------------
$qemu = Join-Path $QemuDir "qemu-system-x86_64.exe"
$qimg = Join-Path $QemuDir "qemu-img.exe"
foreach ($exe in @($qemu, $qimg)) {
    if (-not (Test-Path $exe)) { throw "Not found: $exe  (install QEMU for Windows or pass -QemuDir)" }
}

# --- validate inputs --------------------------------------------------------
if (-not (Test-Path $Iso)) { throw "ISO not found: $Iso" }
$Repo = (Resolve-Path $Repo).Path
if (-not (Test-Path (Join-Path $Repo "tools\qemu-run-mounted.sh"))) {
    throw "Repo at '$Repo' is missing tools\qemu-run-mounted.sh — pass -Repo <repo root>"
}
if (-not (Test-Path (Join-Path $Repo "binaries\firefox-developer"))) {
    Write-Warning "binaries/ looks unpopulated. Run 'bash tools/fetch-binaries.sh' (e.g. in WSL/Git-Bash) first, or the Firefox/VS Code step will fail."
}

# --- 1. SMB share (idempotent) ---------------------------------------------
$share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
if ($share -and $share.Path -ne $Repo) {
    Remove-SmbShare -Name $ShareName -Force | Out-Null
    $share = $null
}
if (-not $share) {
    New-SmbShare -Name $ShareName -Path $Repo -ReadAccess $env:USERNAME | Out-Null
}
Write-Host "SMB share \\$env:COMPUTERNAME\$ShareName  ->  $Repo  (read: $env:USERNAME)"

# --- 2. target disk ---------------------------------------------------------
# Image size = config/disk.conf's disk_size_mib (single source of truth), unless
# overridden by -DiskSizeGiB. The image fills the whole disk (LUKS = 100%, root
# = 100%FREE), so the qemu-img size IS the final image size. disk.conf is read,
# never written.
$diskConf = Join-Path $Repo "config\disk.conf"
if ($DiskSizeGiB -gt 0) {
    $diskMiB = $DiskSizeGiB * 1024
    Write-Host "Image size: $diskMiB MiB (from -DiskSizeGiB $DiskSizeGiB; config/disk.conf not consulted)"
} elseif ((Test-Path $diskConf) -and ((Get-Content $diskConf -Raw) -match '(?m)^\s*disk_size_mib\s*=\s*(\d+)')) {
    $diskMiB = [int]$Matches[1]
    Write-Host "Image size: $diskMiB MiB (from config/disk.conf disk_size_mib)"
} else {
    $diskMiB = 16384
    Write-Warning "No disk_size_mib in config/disk.conf and no -DiskSizeGiB; defaulting to $diskMiB MiB."
}
if ($diskMiB -lt 5120) {
    throw "Image size $diskMiB MiB is too small — need at least ~5120 MiB (EFI + swap + a usable root)."
}
if (Test-Path $Disk) {
    Write-Warning "Target disk $Disk already exists — leaving it as-is. Delete it to resize to $diskMiB MiB."
} else {
    & $qimg create -f raw $Disk "${diskMiB}M" | Out-Null
    Write-Host "Created blank target disk: $Disk ($diskMiB MiB; sparse — grows as written)"
}

# --- 3. guest paste-line (fully prepared; nothing to edit in the VM) --------
# Install passwords (LUKS/ROOT/USER) are read inside the VM from the repo's
# .env (the same file the Docker path uses), so they are NOT in this line. Only
# the SMB mount needs a host credential to open the share — prompt once and bake
# it into the line.
if (-not (Test-Path (Join-Path $Repo ".env"))) {
    Write-Warning "No .env found. Copy .env.example to .env and fill LUKS_PASSWORD/ROOT_PASSWORD/USER_PASSWORD, otherwise the install falls back to the default passphrase 'voidlinux'."
}

$sec  = Read-Host -AsSecureString "Windows password for '$env:USERNAME' (to mount the share inside the VM)"
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$pw   = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

$guest = "xbps-install -Suy xbps; xbps-install -Sy cifs-utils; modprobe cifs; mkdir -p /mnt/cvs; mount -t cifs //10.0.2.2/$ShareName /mnt/cvs -o ro,vers=3.1.1,username=$env:USERNAME,password=$pw && bash /mnt/cvs/tools/qemu-run-mounted.sh"

$copied = $false
try { Set-Clipboard -Value $guest; $copied = $true } catch {}
Write-Host ""
Write-Host "==== In the VM: log in as root / voidlinux, then PASTE (already on your clipboard) ====" -ForegroundColor Cyan
if ($copied) {
    Write-Host "The complete command is on your clipboard — just paste it. Nothing to edit." -ForegroundColor Green
    Write-Host "(SMB password hidden here on purpose; it's only in the clipboard line.)" -ForegroundColor DarkGray
} else {
    # Clipboard unavailable: print with the password masked, plus how to retrieve it.
    Write-Host ($guest -replace [regex]::Escape("password=$pw"), "password=<your-windows-password>") -ForegroundColor Yellow
    Write-Warning "Clipboard unavailable — fill your Windows password where shown."
}
Write-Host "=====================================================================================" -ForegroundColor Cyan
Write-Host ""

# --- 4. launch QEMU (interactive) ------------------------------------------
# whpx = Windows Hypervisor Platform (fast); falls back to tcg (slow) if absent.
# Boot order is pinned with explicit bootindex (CD first, disk second) rather
# than `-boot d` — with a blank target disk attached, `-boot d` is honoured
# inconsistently across firmware/accel and the VM may try the empty disk and
# report "No bootable device".
$qemuArgs = @(
    "-accel", "whpx,kernel-irqchip=off", "-accel", "tcg",
    "-m", "$Mem", "-smp", "$Cpus",
    "-drive", "id=cd,if=none,media=cdrom,readonly=on,file=$Iso",
    "-device", "ide-cd,drive=cd,bootindex=0",
    "-drive", "id=hd,if=none,format=raw,file=$Disk",
    "-device", "virtio-blk-pci,drive=hd,bootindex=1",
    "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0"
)
Write-Host "Launching QEMU (close the window or 'poweroff' in the guest when done)..." -ForegroundColor Green
Write-Host "qemu: `"$qemu`" $($qemuArgs -join ' ')" -ForegroundColor DarkGray
& $qemu @qemuArgs

Write-Host ""
Write-Host "QEMU exited. If the install finished, '$Disk' is your etchable image." -ForegroundColor Green
Write-Host "Etch with Rufus (select the raw image) or 'dd' from WSL. LUKS passphrase = what you set above."
