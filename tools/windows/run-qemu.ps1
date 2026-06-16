<#
.SYNOPSIS
    Build the Void Linux raw image on Windows with QEMU, fully automated and
    headless — or open an interactive VM window if you prefer to drive it by hand.

.DESCRIPTION
    Host side of the Windows + QEMU local build. This repo is exposed to the
    guest as a read-only disk (QEMU vvfat, /dev/vdb1) — no SMB, no cifs-utils,
    no credentials, no seed image. The same scripts as every other path do the
    install; only the device backend (raw, writing to /dev/vda) differs.

    MODES (-Mode):
      build       (default) Boot the live kernel headless with a serial console
                  + autologin, drive it over a TCP serial link (a small built-in
                  expect), run the in-VM build, and stream the whole session to
                  the console and a log. No window, no typing. Produces
                  void-vm.raw on the host.
      probe       Same boot, but only dump lsblk/blkid and mount-test the repo,
                  then power off. Fast (~1 min) sanity check of vvfat + serial
                  before committing to a long build.
      interactive Open a normal QEMU window and boot the ISO's GRUB menu. Log in
                  (root / voidlinux) and run the one line printed below (also
                  copied to your clipboard). For when you want eyes on it.

    -VerifyBoot   After a successful build (or on its own), boot the produced
                  image under OVMF, supply the LUKS passphrase from .env over the
                  serial console, and confirm it reaches userspace. Headless.

    REQUIREMENTS: QEMU for Windows (qemu-system-x86_64.exe, qemu-img.exe) and
    PowerShell 7+ (pwsh). Enable "Windows Hypervisor Platform" for speed (WHPX);
    otherwise QEMU falls back to slow TCG. The kernel/initrd are extracted from
    the ISO with Windows' built-in tar (bsdtar/libarchive reads ISO9660) — no
    extra tooling. See docs/windows-qemu-build.md.

.PARAMETER Iso
    Path to a Void live x86_64 ISO. If omitted, the first match of
    tools\void-live-*.iso then binaries\void-iso\*.iso is used. The "-base"
    flavor is fine; build.sh installs the partitioning tools itself.

.EXAMPLE
    pwsh -File tools\windows\run-qemu.ps1            # auto-detect ISO, build
.EXAMPLE
    pwsh -File tools\windows\run-qemu.ps1 -Mode probe
.EXAMPLE
    pwsh -File tools\windows\run-qemu.ps1 -VerifyBoot
#>
[CmdletBinding()]
param(
    [string]$Iso = "",
    [string]$Repo = "",
    [string]$Disk = "",
    [int]   $Mem  = 4096,
    [int]   $Cpus = 4,
    [string]$QemuDir = "C:\Program Files\qemu",
    [ValidateSet('build', 'probe', 'interactive', 'verify')]
    [string]$Mode = 'build',
    # Append a verify pass after a build/probe run. To ONLY verify an existing
    # image (no build), use -Mode verify.
    [switch]$VerifyBoot,
    # Whole-build budget for the serial driver to wait on the result sentinel.
    [int]   $TimeoutSec = 5400,
    [int]   $SerialPort = 55501,
    [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = "Stop"

# --- resolve repo / paths ----------------------------------------------------
if (-not $Repo) {
    $Repo = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..\..")).Path
}
$Repo = (Resolve-Path $Repo).Path
if (-not (Test-Path (Join-Path $Repo "build.sh"))) { throw "Repo at '$Repo' is missing build.sh -- pass -Repo <repo root>" }

if (-not $Disk) { $Disk = Join-Path $Repo "void-vm.raw" }
if (-not [System.IO.Path]::IsPathRooted($Disk)) { $Disk = Join-Path (Get-Location).Path $Disk }

# --- locate QEMU -------------------------------------------------------------
$qemu = Join-Path $QemuDir "qemu-system-x86_64.exe"
$qimg = Join-Path $QemuDir "qemu-img.exe"
foreach ($exe in @($qemu, $qimg)) {
    if (-not (Test-Path $exe)) { throw "Not found: $exe  (install QEMU for Windows or pass -QemuDir)" }
}

# --- auto-detect ISO ---------------------------------------------------------
if (-not $Iso) {
    $cand = @(Get-ChildItem (Join-Path $Repo "tools") -Filter "void-live-*.iso" -ErrorAction SilentlyContinue) +
            @(Get-ChildItem (Join-Path $Repo "binaries\void-iso") -Filter "*.iso" -ErrorAction SilentlyContinue)
    if (-not $cand) { throw "No ISO found under tools\ or binaries\void-iso\. Pass -Iso <path to void live ISO>." }
    $Iso = $cand[0].FullName
    Write-Host "Using ISO: $Iso"
}
$Iso = (Resolve-Path $Iso).Path

# =============================================================================
#  Serial driver (a tiny expect over a TCP serial link)
# =============================================================================
$enc = [System.Text.Encoding]::ASCII
$script:stream = $null
$script:buf    = [System.Text.StringBuilder]::new()
$script:logw   = $null

function Connect-Serial {
    param([int]$Port, [int]$Retries = 120)
    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            $c = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $Port)
            $script:stream = $c.GetStream()
            $script:stream.ReadTimeout = 400
            return $c
        } catch { Start-Sleep -Milliseconds 500 }
    }
    throw "Could not connect to QEMU serial on 127.0.0.1:$Port"
}

# Read until one of $Patterns (regex strings) appears in the rolling buffer, or
# timeout. Streams every byte to host + log. Returns the matched pattern, or
# '__TIMEOUT__', or $null if the link closed.
function Wait-ForPattern {
    param([string[]]$Patterns, [int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $bytes = New-Object byte[] 8192
    while ((Get-Date) -lt $deadline) {
        $n = 0
        try { $n = $script:stream.Read($bytes, 0, $bytes.Length) }
        catch [System.IO.IOException] { continue }   # read timeout -> keep waiting
        if ($n -le 0) { return $null }               # link closed
        $chunk = $enc.GetString($bytes, 0, $n)
        [Console]::Out.Write($chunk)
        if ($script:logw) { $script:logw.Write($chunk) }
        [void]$script:buf.Append($chunk)
        foreach ($p in $Patterns) {
            if ($script:buf.ToString() -match $p) {
                $script:buf.Clear() | Out-Null   # consume so old text can't re-match
                return $p
            }
        }
        if ($script:buf.Length -gt 65536) {        # keep the buffer bounded
            $s = $script:buf.ToString()
            $script:buf.Clear() | Out-Null
            [void]$script:buf.Append($s.Substring($s.Length - 4096))
        }
    }
    return '__TIMEOUT__'
}

# Truncating log writer that permits concurrent external readers (tail/grep) on
# Windows -- a plain StreamWriter denies sharing and collides with a watcher.
function New-SharedLogWriter {
    param([string]$Path)
    $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $w = [System.IO.StreamWriter]::new($fs)
    $w.AutoFlush = $true
    return $w
}

function Send-Line {
    param([string]$Text)
    $b = $enc.GetBytes($Text + "`r")
    $script:stream.Write($b, 0, $b.Length); $script:stream.Flush()
}

# Robust serial login (mirrors tools/qemu-install.expect): react to login: /
# password: prompts and prove a shell by the OUTPUT of an arithmetic echo (the
# literal 42 appears only in the output, never in the echoed command or MOTD).
function Invoke-SerialLogin {
    $ready = $false
    for ($a = 0; $a -lt 15 -and -not $ready; $a++) {
        switch (Wait-ForPattern @('VOIDMARK=42=END', 'assword:', 'ogin:') 60) {
            'VOIDMARK=42=END' { $ready = $true }
            'assword:'        { Send-Line 'voidlinux'; Start-Sleep -Milliseconds 1200; Send-Line 'echo VOIDMARK=$((21*2))=END' }
            'ogin:'           { Send-Line 'root' }
            '__TIMEOUT__'     { Send-Line ''; Send-Line 'echo VOIDMARK=$((21*2))=END' }
            $null             { throw "QEMU serial closed before a shell was reached" }
        }
    }
    if (-not $ready) { throw "Failed to log in / reach a shell over serial" }
    Send-Line "export PS1='QXREADY# '"
    if ((Wait-ForPattern @('QXREADY# ') 30) -ne 'QXREADY# ') { throw "Could not pin the shell prompt" }
}

# Launch QEMU (headless, serial on TCP) with cwd = staging dir so 'fat:.' works.
function Start-Qemu {
    param([string[]]$QArgs, [string]$WorkDir)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $qemu
    foreach ($a in $QArgs) { $psi.ArgumentList.Add([string]$a) }
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    Write-Host "qemu: `"$qemu`" $($QArgs -join ' ')" -ForegroundColor DarkGray
    return [System.Diagnostics.Process]::Start($psi)
}

# =============================================================================
#  Extract the live kernel + initrd from the ISO (Windows tar reads ISO9660)
# =============================================================================
function Get-LiveBoot {
    param([string]$IsoPath)
    $work = Join-Path $env:TEMP "cvs-qemu-work"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $kernel = Join-Path $work "boot\vmlinuz"
    $initrd = Join-Path $work "boot\initrd"
    Remove-Item $kernel, $initrd -ErrorAction SilentlyContinue
    Push-Location $work
    try {
        & tar -xf $IsoPath boot/vmlinuz boot/initrd 2>&1 | Out-Null
    } finally { Pop-Location }
    if (-not (Test-Path $kernel) -or -not (Test-Path $initrd)) {
        throw "Failed to extract boot/vmlinuz + boot/initrd from $IsoPath"
    }
    # Known-good void-live cmdline (matches the ISO's grub_void.cfg) + our serial
    # console and autologin. console=ttyS0 last => primary console for the driver.
    $append = 'root=live:CDLABEL=VOID_LIVE ro init=/sbin/init rd.luks=0 rd.md=0 rd.dm=0 ' +
              'loglevel=4 gpt add_efi_memmap vconsole.unicode=1 vconsole.keymap=us ' +
              'locale.LANG=en_US.UTF-8 rd.live.overlay.overlayfs=1 ' +
              'console=tty0 console=ttyS0,115200n8 live.autologin'
    return [pscustomobject]@{ Kernel = $kernel; Initrd = $initrd; Append = $append }
}

# =============================================================================
#  Stage the repo for vvfat
# =============================================================================
function New-VvfatStage {
    $stage = Join-Path $env:TEMP "crypt-void-vvfat-stage"
    Write-Host "Staging repo for vvfat at $stage (excluding .git, output, logs, *.iso/*.raw/*.img/*.bak)..."
    $null = robocopy $Repo $stage /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP `
        /XD (Join-Path $Repo ".git") (Join-Path $Repo "output") (Join-Path $Repo "logs") `
        /XF *.iso *.raw *.img *.bak
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed staging the repo to $stage (exit $LASTEXITCODE)" }
    $bytes = (Get-ChildItem $stage -Recurse -Force -File | Measure-Object Length -Sum).Sum
    $mib = [math]::Round($bytes / 1MB)
    Write-Host "Staged: $mib MiB"
    if ($bytes -gt 480MB) {
        throw "Staged repo is $mib MiB -- vvfat tops out at ~504 MiB. Trim binaries/ or extend the exclude list."
    }
    if (-not (Test-Path (Join-Path $stage "binaries\firefox-developer\VERSION"))) {
        Write-Warning "binaries/ looks unpopulated. Run 'bash tools/fetch-binaries.sh' first or the Firefox/VS Code step will fail."
    }
    if (-not (Test-Path (Join-Path $stage ".env"))) {
        Write-Warning "No .env staged. Copy .env.example to .env, otherwise the install uses the default passphrase 'voidlinux'."
    }
    return $stage
}

# =============================================================================
#  Target disk: size from config/disk.conf (authoritative; read, never written)
# =============================================================================
function New-TargetDisk {
    $diskConf = Join-Path $Repo "config\disk.conf"
    if (-not (Test-Path $diskConf)) { throw "config/disk.conf not found at $diskConf" }
    if ((Get-Content $diskConf -Raw) -notmatch '(?m)^\s*disk_size_mib\s*=\s*(\d+)') {
        throw "disk_size_mib is not set in config/disk.conf"
    }
    $mib = [int]$Matches[1]
    if ($mib -lt 5120) { throw "disk_size_mib ($mib) too small -- need >= ~5120 MiB (EFI + swap + usable root)." }
    Write-Host "Image size: $mib MiB (config/disk.conf disk_size_mib)"
    if (Test-Path $Disk) {
        Write-Warning "Target disk $Disk already exists -- leaving it as-is. Delete it to resize to $mib MiB."
    } else {
        & $qimg create -f raw $Disk "${mib}M" | Out-Null
        Write-Host "Created blank target disk: $Disk ($mib MiB; sparse -- grows as written)"
    }
}

# =============================================================================
#  build / probe (headless, serial-driven)
# =============================================================================
function Invoke-HeadlessRun {
    param([string]$RunMode)   # 'build' | 'probe'

    New-TargetDisk
    $stage = New-VvfatStage
    $boot  = Get-LiveBoot $Iso

    $logDir = Join-Path $Repo "logs"; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $logFile = Join-Path $logDir ("windows-{0}.log" -f $RunMode)
    $script:logw = New-SharedLogWriter $logFile

    # Devices: /dev/sr0 live ISO (squashfs), /dev/vda target image, /dev/vdb repo (vvfat).
    $qemuArgs = @(
        "-accel", "whpx,kernel-irqchip=off", "-accel", "tcg",
        "-m", "$Mem", "-smp", "$Cpus",
        "-kernel", $boot.Kernel, "-initrd", $boot.Initrd, "-append", $boot.Append,
        "-drive", "id=cd,if=none,media=cdrom,readonly=on,file=$Iso",
        "-device", "ide-cd,drive=cd",
        "-drive", "id=hd,if=none,format=raw,file=$Disk",
        "-device", "virtio-blk-pci,drive=hd",
        "-drive", "id=repo,if=none,readonly=on,format=vvfat,file=fat:.",
        "-device", "virtio-blk-pci,drive=repo",
        "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0",
        "-display", "none",
        "-serial", "tcp:127.0.0.1:$SerialPort,server=on,wait=off",
        "-monitor", "none", "-no-reboot"
    ) + $ExtraArgs

    Write-Host "Launching QEMU headless ($RunMode); serial -> console + $logFile" -ForegroundColor Green
    $proc = Start-Qemu -QArgs $qemuArgs -WorkDir $stage
    $client = $null
    try {
        $client = Connect-Serial $SerialPort
        Invoke-SerialLogin

        if ($RunMode -eq 'probe') {
            Send-Line ('lsblk -f; echo ---; blkid; echo ---; ls -l /dev/vd* /dev/sr* 2>/dev/null; echo ---; ' +
                       'mkdir -p /repo && mount /dev/vdb1 /repo && ls /repo && head -1 /repo/build.sh && ' +
                       'printf ''PROBE_%s\n'' DONE_4242 || printf ''PROBE_%s\n'' FAIL_4242')
            $r = Wait-ForPattern @('PROBE_DONE_4242', 'PROBE_FAIL_4242') 120
            Send-Line 'poweroff'
            $proc.WaitForExit(60000) | Out-Null
            if (-not $proc.HasExited) { $proc.Kill() }
            if ($r -eq 'PROBE_DONE_4242') { Write-Host "`nPROBE OK: vvfat repo mounts at /dev/vdb1." -ForegroundColor Green; return 0 }
            Write-Host "`nPROBE FAILED (r=$r). See $logFile." -ForegroundColor Red; return 1
        }

        # build: mount the repo and run the in-VM build. Sentinels are printf-
        # assembled so the literal can't match the echoed command line.
        Send-Line ('mkdir -p /repo && mount /dev/vdb1 /repo && bash /repo/build.sh; rc=$?; ' +
                   'if [ $rc -eq 0 ]; then printf ''VOID_BUILD_%s\n'' RESULT_OK_4242; ' +
                   'else printf ''VOID_BUILD_%s rc=%s\n'' RESULT_FAIL_4242 $rc; fi')
        $r = Wait-ForPattern @('VOID_BUILD_RESULT_OK_4242', 'VOID_BUILD_RESULT_FAIL_4242') $TimeoutSec
        Send-Line 'poweroff'
        $proc.WaitForExit(120000) | Out-Null
        if (-not $proc.HasExited) { $proc.Kill() }
        if ($r -eq 'VOID_BUILD_RESULT_OK_4242') {
            Write-Host "`nBUILD OK: '$Disk' is your etchable image." -ForegroundColor Green
            return 0
        }
        Write-Host "`nBUILD FAILED (r=$r). See $logFile." -ForegroundColor Red
        return 1
    } finally {
        if ($client) { $client.Close() }
        if ($script:logw) { $script:logw.Flush(); $script:logw.Close(); $script:logw = $null }
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch {} }
    }
}

# =============================================================================
#  interactive (GUI window; you log in and run one line)
# =============================================================================
function Invoke-Interactive {
    New-TargetDisk
    $stage = New-VvfatStage
    $guest = "mkdir -p /repo && mount /dev/vdb1 /repo && bash /repo/build.sh"
    try { Set-Clipboard -Value $guest } catch {}
    Write-Host ""
    Write-Host "==== In the VM: log in as root / voidlinux, then run (copied to clipboard): ====" -ForegroundColor Cyan
    Write-Host "    $guest" -ForegroundColor Yellow
    Write-Host "================================================================================" -ForegroundColor Cyan
    Write-Host ""
    $qemuArgs = @(
        "-accel", "whpx,kernel-irqchip=off", "-accel", "tcg",
        "-m", "$Mem", "-smp", "$Cpus",
        "-drive", "id=cd,if=none,media=cdrom,readonly=on,file=$Iso",
        "-device", "ide-cd,drive=cd,bootindex=0",
        "-drive", "id=hd,if=none,format=raw,file=$Disk",
        "-device", "virtio-blk-pci,drive=hd,bootindex=1",
        "-drive", "id=repo,if=none,readonly=on,format=vvfat,file=fat:.",
        "-device", "virtio-blk-pci,drive=repo",
        "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0"
    ) + $ExtraArgs
    Push-Location $stage
    try {
        Write-Host "Launching QEMU window (close it or 'poweroff' in the guest when done)..." -ForegroundColor Green
        & $qemu @qemuArgs
    } finally { Pop-Location }
    Write-Host "QEMU exited. If the install finished, '$Disk' is your etchable image." -ForegroundColor Green
}

# =============================================================================
#  -VerifyBoot (OVMF, headless; supply LUKS passphrase over serial)
# =============================================================================
function Resolve-Ovmf {
    $share = Join-Path $QemuDir "share"
    $code = Join-Path $share "edk2-x86_64-code.fd"
    if (-not (Test-Path $code)) { throw "OVMF code firmware not found: $code" }
    # Per-run writable NVRAM. The Windows QEMU build ships no edk2-x86_64-vars.fd,
    # but the varstore is arch-neutral, so edk2-i386-vars.fd is the right template
    # (and the right size -- a code-sized blank breaks pflash). Boot is via the
    # removable path \EFI\BOOT\BOOTX64.EFI, so an empty NVRAM still boots GRUB.
    $work = Join-Path $env:TEMP "cvs-qemu-work"; New-Item -ItemType Directory -Force -Path $work | Out-Null
    $vars = Join-Path $work "OVMF_VARS.verify.fd"
    $tmpl = @("edk2-x86_64-vars.fd", "edk2-i386-vars.fd") |
        ForEach-Object { Join-Path $share $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $tmpl) { throw "No OVMF VARS template found in $share (edk2-x86_64-vars.fd / edk2-i386-vars.fd)" }
    Copy-Item $tmpl $vars -Force
    return [pscustomobject]@{ Code = $code; Vars = $vars }
}

function Get-LuksPassword {
    $envFile = Join-Path $Repo ".env"
    if (Test-Path $envFile) {
        $m = Select-String -Path $envFile -Pattern '^\s*LUKS_PASSWORD=(.*)$' | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value.Trim().Trim('"').Trim("'") }
    }
    return 'voidlinux'
}

function Invoke-VerifyBoot {
    if (-not (Test-Path $Disk)) { throw "Image not found: $Disk (build it first)" }
    $ovmf = Resolve-Ovmf
    $luks = Get-LuksPassword
    $logDir = Join-Path $Repo "logs"; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $logFile = Join-Path $logDir "windows-verify.log"
    $script:logw = New-SharedLogWriter $logFile
    $port = $SerialPort + 1

    # TCG only -- NOT WHPX. Windows Hypervisor Platform aborts on OVMF firmware
    # ("WHPX: Failed to emulate MMIO access"); the build path avoids this by
    # booting the kernel directly, but the UEFI verify must run under TCG. It is
    # only a short boot-to-LUKS-prompt check, so the slowdown is acceptable.
    $qemuArgs = @(
        "-accel", "tcg",
        "-m", "$Mem", "-smp", "$Cpus",
        "-drive", "if=pflash,format=raw,readonly=on,file=$($ovmf.Code)",
        "-drive", "if=pflash,format=raw,file=$($ovmf.Vars)",
        "-drive", "if=virtio,format=raw,file=$Disk",
        "-boot", "order=c,menu=off",
        "-netdev", "user,id=n1", "-device", "virtio-net-pci,netdev=n1",
        "-display", "none",
        "-serial", "tcp:127.0.0.1:$port,server=on,wait=off",
        "-monitor", "none", "-no-reboot"
    )
    Write-Host "Verifying $Disk under OVMF (headless); serial -> console + $logFile" -ForegroundColor Green
    $proc = Start-Qemu -QArgs $qemuArgs -WorkDir $Repo
    $client = $null
    try {
        $client = Connect-Serial $port
        $sawPrompt = $false; $sends = 0
        $passPatterns = @('(?i)enter passphrase', '(?i)please enter passphrase', '(?i)passphrase for')
        $userPatterns = @('(?i)welcome to void', 'runit:', '(?i)sddm', 'ogin:', 'seatd', '(?i)EXT4-fs.*mounted filesystem')
        # GRUB asks for the passphrase to read /boot, dracut asks again for root.
        for ($i = 0; $i -lt 40; $i++) {
            $m = Wait-ForPattern ($passPatterns + $userPatterns) 300
            if ($m -eq '__TIMEOUT__' -or $null -eq $m) {
                if ($sawPrompt) {
                    Write-Host "`nVERIFY PASS: boot + LUKS decrypt reached (no further token before idle/exit)." -ForegroundColor Green
                    return 0
                }
                throw "VERIFY FAIL: never reached the LUKS passphrase prompt"
            }
            if ($passPatterns -contains $m) {
                $sawPrompt = $true; $sends++
                if ($sends -gt 6) { throw "VERIFY FAIL: passphrase prompt kept reappearing (wrong passphrase?)" }
                Start-Sleep -Seconds 1
                Send-Line $luks
            } else {
                Write-Host "`nVERIFY OK: reached userspace (matched '$m')." -ForegroundColor Green
                return 0
            }
        }
        Write-Host "`nVERIFY: gave up after 40 events." -ForegroundColor Yellow
        return 1
    } finally {
        if ($client) { $client.Close() }
        if ($script:logw) { $script:logw.Flush(); $script:logw.Close(); $script:logw = $null }
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch {} }
    }
}

# =============================================================================
#  main
# =============================================================================
$rc = 0
switch ($Mode) {
    'build'       { $rc = Invoke-HeadlessRun 'build' }
    'probe'       { $rc = Invoke-HeadlessRun 'probe' }
    'interactive' { Invoke-Interactive }
    'verify'      { exit (Invoke-VerifyBoot) }   # verify ONLY, never build
}
if ($Mode -ne 'interactive' -and $rc -ne 0) { exit $rc }
if ($VerifyBoot) { $rc = Invoke-VerifyBoot }
exit $rc
