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
    [string]$Repo      = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    [string]$Disk      = (Join-Path (Get-Location) "void-vm.raw"),
    [string]$DiskSize  = "16G",
    [string]$ShareName = "cvs",
    [int]   $Mem       = 4096,
    [int]   $Cpus      = 4,
    [string]$QemuDir   = "C:\Program Files\qemu"
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
if (-not (Test-Path $Disk)) {
    & $qimg create -f raw $Disk $DiskSize | Out-Null
    Write-Host "Created blank target disk: $Disk ($DiskSize)"
} else {
    Write-Host "Reusing existing target disk: $Disk"
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
$qemuArgs = @(
    "-accel", "whpx,kernel-irqchip=off", "-accel", "tcg",
    "-m", "$Mem", "-smp", "$Cpus",
    "-drive", "if=virtio,format=raw,file=$Disk",
    "-cdrom", "$Iso",
    "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0",
    "-boot", "d"
)
Write-Host "Launching QEMU (close the window or 'poweroff' in the guest when done)..." -ForegroundColor Green
& $qemu @qemuArgs

Write-Host ""
Write-Host "QEMU exited. If the install finished, '$Disk' is your etchable image." -ForegroundColor Green
Write-Host "Etch with Rufus (select the raw image) or 'dd' from WSL. LUKS passphrase = what you set above."
