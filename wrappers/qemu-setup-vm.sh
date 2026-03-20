#!/usr/bin/env bash
# qemu-setup-vm.sh — One-time setup: create a QEMU VM that can run the
# Void Linux FDE build inside its privileged environment.
#
# The VM is a Debian-based guest configured with:
#   • All tools needed by entrypoint.sh (cryptsetup, lvm2, parted, …)
#   • SSH server for automation
#   • 9p virtfs tag "host_share" mapped to the repository root
#
# Prerequisites (host):
#   - qemu-system-x86_64 and qemu-img
#   - sshpass (for non-interactive SSH)
#   - A Debian netboot ISO (downloaded automatically if missing)
#
# Run once to create vm/void-builder.qcow2, then use qemu-run-build.sh for
# subsequent builds.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

log()  { echo "[qemu-setup] $*"; }
die()  { echo "[qemu-setup] ERROR: $*" >&2; exit 1; }
warn() { echo "[qemu-setup] WARNING: $*" >&2; }

# ---------------------------------------------------------------------------
# Configuration — override via environment variables if needed.
# ---------------------------------------------------------------------------
VM_DIR="${REPO_ROOT}/vm"
VM_DISK="${VM_DIR}/void-builder.qcow2"
VM_DISK_SIZE="${QEMU_VM_DISK_SIZE:-40G}"
VM_RAM="${QEMU_VM_RAM:-4096}"
VM_CPUS="${QEMU_VM_CPUS:-2}"
VM_SSH_PORT="${QEMU_VM_SSH_PORT:-2222}"

# Debian 12 (Bookworm) netinstall ISO — stable and well-supported by QEMU.
DEBIAN_ISO_URL="${QEMU_DEBIAN_ISO_URL:-https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.10.0-amd64-netinst.iso}"
DEBIAN_ISO="${VM_DIR}/debian-installer.iso"

# Cloud-init preseed via a small seed ISO (created inline).
SEED_ISO="${VM_DIR}/seed.iso"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 not found. Install QEMU."
command -v qemu-img            >/dev/null 2>&1 || die "qemu-img not found. Install QEMU utilities."

if [[ -f "${VM_DISK}" ]]; then
    warn "VM disk already exists at ${VM_DISK}."
    warn "Delete it and re-run this script to recreate the VM, or use qemu-run-build.sh directly."
    exit 0
fi

# ---------------------------------------------------------------------------
# Create VM directory and QCOW2 disk.
# ---------------------------------------------------------------------------
mkdir -p "${VM_DIR}"

log "Creating ${VM_DISK_SIZE} QCOW2 disk at ${VM_DISK}..."
qemu-img create -f qcow2 "${VM_DISK}" "${VM_DISK_SIZE}"

# ---------------------------------------------------------------------------
# Download Debian installer ISO if not already present.
# ---------------------------------------------------------------------------
if [[ ! -f "${DEBIAN_ISO}" ]]; then
    log "Downloading Debian installer ISO from ${DEBIAN_ISO_URL}..."
    if command -v curl >/dev/null 2>&1; then
        curl -L --progress-bar -o "${DEBIAN_ISO}" "${DEBIAN_ISO_URL}"
    elif command -v wget >/dev/null 2>&1; then
        wget --show-progress -O "${DEBIAN_ISO}" "${DEBIAN_ISO_URL}"
    else
        die "Neither curl nor wget is available. Download ${DEBIAN_ISO_URL} manually to ${DEBIAN_ISO}."
    fi
else
    log "Debian ISO already present at ${DEBIAN_ISO}."
fi

# ---------------------------------------------------------------------------
# Generate a preseed / cloud-init seed ISO for fully unattended installation.
# We use a minimal preseed that:
#   1. Partitions the disk automatically.
#   2. Installs only required packages.
#   3. Creates an "admin" user with SSH access (key-based).
#   4. Enables root SSH for automated commands during setup.
# ---------------------------------------------------------------------------

# Generate an ephemeral SSH key pair for VM automation.
SSH_KEY_DIR="${VM_DIR}/.ssh"
SSH_KEY="${SSH_KEY_DIR}/vm_key"
mkdir -p "${SSH_KEY_DIR}"
chmod 700 "${SSH_KEY_DIR}"
if [[ ! -f "${SSH_KEY}" ]]; then
    log "Generating SSH key pair for VM access at ${SSH_KEY}..."
    ssh-keygen -t ed25519 -N "" -f "${SSH_KEY}" -C "void-builder-vm"
fi
SSH_PUBKEY=$(cat "${SSH_KEY}.pub")

# Write a minimal Debian preseed file.
PRESEED_DIR="${VM_DIR}/preseed"
mkdir -p "${PRESEED_DIR}"

cat > "${PRESEED_DIR}/preseed.cfg" << EOF
# Debian automated preseed for the Void FDE builder VM.

# Locale / keyboard
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us

# Network
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string void-builder
d-i netcfg/get_domain string local

# Mirror
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

# Clock / timezone
d-i clock-setup/utc boolean true
d-i time/zone string UTC
d-i clock-setup/ntp boolean true

# Partitioning — use entire disk, LVM, no encryption (the host OS itself)
d-i partman-auto/method string lvm
d-i partman-auto-lvm/guided_size string max
d-i partman-auto/choose_recipe select atomic
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman/choose_partition select finish

# Root account
d-i passwd/root-login boolean true
d-i passwd/root-password-crypted password \$6\$rounds=500000\$void-builder\$plfGqcbNTSRvLIBGJp0nCr8bGLF1OhHfQAg3nvGnSi5BH8IUPRYqCmT2lT/TQmCdCp6IVvFq7DBAB8ZvPBPx01

# Regular user
d-i passwd/user-fullname string Build User
d-i passwd/username string admin
d-i passwd/user-password-crypted password \$6\$rounds=500000\$void-builder\$plfGqcbNTSRvLIBGJp0nCr8bGLF1OhHfQAg3nvGnSi5BH8IUPRYqCmT2lT/TQmCdCp6IVvFq7DBAB8ZvPBPx01

# Package selection — minimal with SSH and required build tools
tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string \
    openssh-server \
    cryptsetup \
    lvm2 \
    parted \
    dosfstools \
    e2fsprogs \
    util-linux \
    sudo \
    curl \
    wget

d-i pkgsel/upgrade select full-upgrade
popularity-contest popularity-contest/participate boolean false

# Boot loader
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean false
d-i grub-installer/bootdev string /dev/vda

# Finish
d-i finish-install/reboot_in_progress note
EOF

# Write a late-command script to:
#   1. Allow root SSH login for automation.
#   2. Install the generated public key.
cat > "${PRESEED_DIR}/late_command.sh" << LATEEOF
#!/bin/sh
set -e
in-target sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
in-target sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
in-target mkdir -p /root/.ssh
echo '${SSH_PUBKEY}' >> /target/root/.ssh/authorized_keys
in-target chmod 600 /root/.ssh/authorized_keys
LATEEOF
chmod +x "${PRESEED_DIR}/late_command.sh"

# Append late_command to preseed to run the script.
cat >> "${PRESEED_DIR}/preseed.cfg" << EOF
d-i preseed/late_command string cp /cdrom/late_command.sh /target/tmp/ && in-target sh /tmp/late_command.sh
EOF

# Build a seed ISO containing the preseed and late_command script.
log "Creating preseed seed ISO at ${SEED_ISO}..."
if command -v genisoimage >/dev/null 2>&1; then
    genisoimage -r -J -o "${SEED_ISO}" "${PRESEED_DIR}"
elif command -v mkisofs >/dev/null 2>&1; then
    mkisofs -r -J -o "${SEED_ISO}" "${PRESEED_DIR}"
elif command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs -r -J -o "${SEED_ISO}" "${PRESEED_DIR}"
else
    die "No ISO creation tool found (genisoimage/mkisofs/xorriso). Install one and re-run."
fi

# ---------------------------------------------------------------------------
# Boot the VM from the Debian installer ISO with the preseed seed ISO.
# The installer runs unattended and shuts the VM down when finished.
# ---------------------------------------------------------------------------
log "Starting unattended Debian installation inside QEMU..."
log "  This will take 15–40 minutes depending on network speed."
log "  The VM will power off automatically when installation completes."

qemu-system-x86_64 \
    -m "${VM_RAM}" \
    -smp "${VM_CPUS}" \
    -enable-kvm \
    -machine accel=kvm:hvf:tcg \
    -drive "file=${VM_DISK},format=qcow2,if=virtio,cache=writeback" \
    -cdrom "${DEBIAN_ISO}" \
    -drive "file=${SEED_ISO},format=raw,if=ide,media=cdrom,index=1" \
    -boot "d" \
    -netdev "user,id=net0,hostfwd=tcp::${VM_SSH_PORT}-:22" \
    -device "virtio-net-pci,netdev=net0" \
    -append "auto=true priority=critical preseed/url=cdrom:///preseed.cfg" \
    -nographic \
    -no-reboot

log "Debian installation complete. VM powered off."

# ---------------------------------------------------------------------------
# Post-install: boot the VM and install the XBPS (Void Linux) static binary
# so that entrypoint.sh can use it for the actual build.
# ---------------------------------------------------------------------------
log "Starting VM for post-install configuration..."
log "  Waiting for SSH on port ${VM_SSH_PORT}..."

qemu-system-x86_64 \
    -m "${VM_RAM}" \
    -smp "${VM_CPUS}" \
    -enable-kvm \
    -machine accel=kvm:hvf:tcg \
    -drive "file=${VM_DISK},format=qcow2,if=virtio,cache=writeback" \
    -netdev "user,id=net0,hostfwd=tcp::${VM_SSH_PORT}-:22" \
    -device "virtio-net-pci,netdev=net0" \
    -nographic \
    -daemonize \
    -pidfile "${VM_DIR}/vm.pid"

vm_ssh() {
    ssh \
        -i "${SSH_KEY}" \
        -o "StrictHostKeyChecking=no" \
        -o "UserKnownHostsFile=/dev/null" \
        -o "ConnectTimeout=5" \
        -p "${VM_SSH_PORT}" \
        root@127.0.0.1 \
        "$@"
}

# Wait up to 3 minutes for SSH to become available.
log "  Waiting for SSH (up to 3 minutes)..."
TIMEOUT=180
ELAPSED=0
until vm_ssh true 2>/dev/null; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [[ "${ELAPSED}" -ge "${TIMEOUT}" ]]; then
        VM_PID=$(cat "${VM_DIR}/vm.pid" 2>/dev/null || true)
        [[ -n "${VM_PID}" ]] && kill "${VM_PID}" 2>/dev/null || true
        die "Timed out waiting for VM SSH. Check vm/void-builder.qcow2 integrity."
    fi
done

log "SSH available. Running post-install configuration..."

# Install xtools (xchroot) and XBPS static binary — required by entrypoint.sh.
vm_ssh bash -s << 'REMOTE'
set -euo pipefail
echo "[vm-setup] Installing additional build dependencies..."

apt-get update -qq
apt-get install -y --no-install-recommends \
    xz-utils \
    curl \
    wget \
    binutils

# Install xbps-static so the Void Linux XBPS tool is available inside the VM.
XBPS_VERSION=$(curl -sf https://api.github.com/repos/void-linux/xbps/releases/latest | grep '"tag_name"' | sed 's/.*"tag_name": "\(.*\)".*/\1/')
if [[ -z "${XBPS_VERSION}" ]]; then
    echo "[vm-setup] ERROR: Could not determine latest xbps version from GitHub API." >&2
    exit 1
fi
echo "[vm-setup] Installing xbps-static ${XBPS_VERSION}..."
XBPS_TARBALL="xbps-static-${XBPS_VERSION}.x86_64-musl.tar.xz"
XBPS_URL="https://github.com/void-linux/xbps/releases/download/${XBPS_VERSION}/${XBPS_TARBALL}"
curl -fL "${XBPS_URL}" -o "/tmp/${XBPS_TARBALL}"
tar -xJ -C /usr/local -f "/tmp/${XBPS_TARBALL}"
rm -f "/tmp/${XBPS_TARBALL}"

echo "[vm-setup] Installing xchroot (xtools)..."
# xchroot is part of the xtools collection; install as a standalone script.
curl -sL https://raw.githubusercontent.com/leahneukirchen/xtools/master/xchroot \
    -o /usr/local/bin/xchroot
chmod +x /usr/local/bin/xchroot

echo "[vm-setup] Verifying tool availability..."
xbps-install --version 2>/dev/null || /usr/local/bin/xbps-install.static --version
xchroot --version 2>/dev/null || true

echo "[vm-setup] Post-install configuration complete."
REMOTE

log "Shutting down VM gracefully..."
vm_ssh poweroff || true

VM_PID=$(cat "${VM_DIR}/vm.pid" 2>/dev/null || true)
if [[ -n "${VM_PID}" ]]; then
    WAIT=0
    while kill -0 "${VM_PID}" 2>/dev/null && [[ "${WAIT}" -lt 30 ]]; do
        sleep 2; WAIT=$((WAIT + 2))
    done
    kill "${VM_PID}" 2>/dev/null || true
fi

log "VM setup complete."
log "VM disk: ${VM_DISK}"
log "Run ./wrappers/qemu-run-build.sh to execute the build inside the VM."
