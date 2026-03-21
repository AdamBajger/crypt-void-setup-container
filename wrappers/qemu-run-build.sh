#!/usr/bin/env bash
# Run the Void Linux FDE build inside a QEMU VM.
#
# The repository root is shared into the VM via 9p virtfs — no SSH required.
# A custom /init replaces the Void live initrd's init so that the build runs
# automatically and the VM powers off when done.
#
# Required environment variables:
#   LUKS_PASSWORD, ROOT_PASSWORD, USER_PASSWORD, VOID_XBPS_REPOSITORY
#
# Optional environment variables:
#   VOID_ISO      — path to Void Linux live ISO (default: vm/void-live.iso)
#   QEMU_VM_RAM   — VM memory in MiB (default: 4096)
#   QEMU_VM_CPUS  — VM vCPU count (default: 2)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
VM_DIR="${REPO_ROOT}/vm"
VOID_ISO="${VOID_ISO:-${VM_DIR}/void-live.iso}"
VM_RAM="${QEMU_VM_RAM:-4096}"
VM_CPUS="${QEMU_VM_CPUS:-2}"
BOOT_DIR="${VM_DIR}/.boot"
SECRETS_FILE="${VM_DIR}/.build-env"

[[ -f "${VOID_ISO}" ]] || {
    echo "ERROR: ${VOID_ISO} not found. Run wrappers/qemu-setup-vm.sh first." >&2
    exit 1
}

[[ -n "${LUKS_PASSWORD:-}" ]]        || { echo "ERROR: LUKS_PASSWORD not set." >&2;        exit 1; }
[[ -n "${ROOT_PASSWORD:-}" ]]        || { echo "ERROR: ROOT_PASSWORD not set." >&2;        exit 1; }
[[ -n "${USER_PASSWORD:-}" ]]        || { echo "ERROR: USER_PASSWORD not set." >&2;        exit 1; }
[[ -n "${VOID_XBPS_REPOSITORY:-}" ]] || { echo "ERROR: VOID_XBPS_REPOSITORY not set." >&2; exit 1; }

mkdir -p "${REPO_ROOT}/output" "${BOOT_DIR}/initrd-work"

cleanup() {
    rm -f "${SECRETS_FILE}"
    rm -rf "${BOOT_DIR}"
}
trap cleanup EXIT

# Write build secrets to a temp file on the 9p share.
# The init script sources and immediately deletes this file.
{
    printf 'LUKS_PASSWORD=%s\n'        "${LUKS_PASSWORD@Q}"
    printf 'ROOT_PASSWORD=%s\n'        "${ROOT_PASSWORD@Q}"
    printf 'USER_PASSWORD=%s\n'        "${USER_PASSWORD@Q}"
    printf 'VOID_XBPS_REPOSITORY=%s\n' "${VOID_XBPS_REPOSITORY@Q}"
} > "${SECRETS_FILE}"
chmod 600 "${SECRETS_FILE}"

# Extract the Void Linux live kernel and initramfs from the ISO.
echo "Extracting boot files from ${VOID_ISO}..."
bsdtar --strip-components=1 -xf "${VOID_ISO}" -C "${BOOT_DIR}" boot/vmlinuz boot/initrd

# Build a small cpio archive containing our custom /init.
# When concatenated after the Void live initramfs, this /init overrides the
# Void live one, giving us full control while retaining all initramfs tools.
cat > "${BOOT_DIR}/initrd-work/init" << 'INIT_EOF'
#!/bin/sh
set -e

mount -t proc     proc     /proc
mount -t sysfs    sysfs    /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts
mount -t devpts   devpts   /dev/pts

echo 1 > /proc/sys/kernel/sysrq

for mod in virtio_pci virtio_blk virtio_scsi \
           9p 9pnet 9pnet_virtio \
           squashfs overlay loop dm_mod dm_crypt; do
    modprobe "$mod" 2>/dev/null || true
done

# Mount the 9p host share (repository root).
mkdir -p /mnt/host
mount -t 9p -o trans=virtio,version=9p2000.L hostshare /mnt/host

# Read build secrets from the host share and immediately remove the file.
. /mnt/host/vm/.build-env
rm -f /mnt/host/vm/.build-env

# Mount the Void Linux live ISO (presented as a CDROM).
mkdir -p /mnt/cdrom
mount -t iso9660 /dev/sr0 /mnt/cdrom

# Locate the squashfs rootfs inside the ISO.
SQUASHFS=''
for p in /mnt/cdrom/LiveOS/squashfs.img \
          /mnt/cdrom/boot/rootfs.squashfs \
          /mnt/cdrom/rootfs.squashfs; do
    [ -f "$p" ] && SQUASHFS="$p" && break
done
[ -n "$SQUASHFS" ] || {
    echo "ERROR: squashfs not found in Void live ISO." >&2
    sleep 2
    echo o > /proc/sysrq-trigger
}

# Mount the squashfs read-only, then layer a writable overlay on top.
mkdir -p /mnt/lower /mnt/upper /mnt/work /mnt/root
mount -t squashfs -o ro "$SQUASHFS" /mnt/lower
mount -t overlay overlay \
    -o lowerdir=/mnt/lower,upperdir=/mnt/upper,workdir=/mnt/work \
    /mnt/root

# Bind essential virtual filesystems into the new root.
for d in proc sys dev dev/pts; do
    mkdir -p "/mnt/root/$d"
    mount --bind "/$d" "/mnt/root/$d"
done

# Bind the 9p host share and the expected build directories into the new root.
mkdir -p /mnt/root/mnt/host
mount --bind /mnt/host /mnt/root/mnt/host

mkdir -p /mnt/root/config /mnt/root/output /mnt/root/setup
mount --bind /mnt/host/config  /mnt/root/config
mount --bind /mnt/host/output  /mnt/root/output
mount --bind /mnt/host/scripts /mnt/root/setup

# Run entrypoint.sh inside the Void Linux environment.
chroot /mnt/root env \
    LUKS_PASSWORD="$LUKS_PASSWORD" \
    ROOT_PASSWORD="$ROOT_PASSWORD" \
    USER_PASSWORD="$USER_PASSWORD" \
    VOID_XBPS_REPOSITORY="$VOID_XBPS_REPOSITORY" \
    /bin/sh /setup/entrypoint.sh

sync
echo o > /proc/sysrq-trigger
INIT_EOF

chmod +x "${BOOT_DIR}/initrd-work/init"

# Package the wrapper into a cpio archive.
( cd "${BOOT_DIR}/initrd-work" && find . | cpio -H newc -o 2>/dev/null ) \
    > "${BOOT_DIR}/wrapper.cpio"

# Concatenate: Void initramfs first (provides tools/modules), our wrapper
# second (overrides /init).
cat "${BOOT_DIR}/initrd" "${BOOT_DIR}/wrapper.cpio" \
    > "${BOOT_DIR}/combined-initrd.img"

echo "Starting QEMU VM (RAM=${VM_RAM}MiB, CPUs=${VM_CPUS})..."
qemu-system-x86_64 \
    -m "${VM_RAM}" \
    -smp "${VM_CPUS}" \
    -enable-kvm \
    -kernel "${BOOT_DIR}/vmlinuz" \
    -initrd "${BOOT_DIR}/combined-initrd.img" \
    -append "rdinit=/init console=ttyS0" \
    -cdrom "${VOID_ISO}" \
    -virtfs "local,path=${REPO_ROOT},mount_tag=hostshare,security_model=none" \
    -netdev "user,id=net0" \
    -device "virtio-net-pci,netdev=net0" \
    -nographic \
    -no-reboot
