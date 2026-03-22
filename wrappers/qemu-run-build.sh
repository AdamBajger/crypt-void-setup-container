#!/usr/bin/env bash
# Run the Void Linux FDE build inside a QEMU VM.
#
# Required environment variables:
#   LUKS_PASSWORD, ROOT_PASSWORD, USER_PASSWORD, VOID_XBPS_REPOSITORY
#
# Optional environment variables:
#   VOID_ISO     — path to Void Linux live ISO (default: vm/void-live.iso)
#   QEMU_VM_RAM  — VM memory in MiB (default: 4096)
#   QEMU_VM_CPUS — VM vCPU count (default: 2)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
VM_DIR="${REPO_ROOT}/vm"
VOID_ISO="${VOID_ISO:-${VM_DIR}/void-live.iso}"
VM_RAM="${QEMU_VM_RAM:-4096}"
VM_CPUS="${QEMU_VM_CPUS:-2}"
BOOT_DIR="${VM_DIR}/.boot"
SECRETS_FILE="${VM_DIR}/.build-env"

[[ -f "${VOID_ISO}" ]] || { echo "ERROR: ${VOID_ISO} not found." >&2; exit 1; }
[[ -n "${LUKS_PASSWORD:-}" ]]        || { echo "ERROR: LUKS_PASSWORD not set." >&2;        exit 1; }
[[ -n "${ROOT_PASSWORD:-}" ]]        || { echo "ERROR: ROOT_PASSWORD not set." >&2;        exit 1; }
[[ -n "${USER_PASSWORD:-}" ]]        || { echo "ERROR: USER_PASSWORD not set." >&2;        exit 1; }
[[ -n "${VOID_XBPS_REPOSITORY:-}" ]] || { echo "ERROR: VOID_XBPS_REPOSITORY not set." >&2; exit 1; }

mkdir -p "${REPO_ROOT}/output" "${BOOT_DIR}/initrd-work"

cleanup() { rm -f "${SECRETS_FILE}"; rm -rf "${BOOT_DIR}"; }
trap cleanup EXIT

{
    printf 'LUKS_PASSWORD=%s\n'        "${LUKS_PASSWORD@Q}"
    printf 'ROOT_PASSWORD=%s\n'        "${ROOT_PASSWORD@Q}"
    printf 'USER_PASSWORD=%s\n'        "${USER_PASSWORD@Q}"
    printf 'VOID_XBPS_REPOSITORY=%s\n' "${VOID_XBPS_REPOSITORY@Q}"
} > "${SECRETS_FILE}"
chmod 600 "${SECRETS_FILE}"

echo "Extracting boot files from ${VOID_ISO}..."
bsdtar --strip-components=1 -xf "${VOID_ISO}" -C "${BOOT_DIR}" boot/vmlinuz boot/initrd

cp "${SCRIPT_DIR}/qemu-vm-init.sh" "${BOOT_DIR}/initrd-work/init"
chmod +x "${BOOT_DIR}/initrd-work/init"

( cd "${BOOT_DIR}/initrd-work" && find . | cpio -H newc -o 2>/dev/null ) \
    > "${BOOT_DIR}/wrapper.cpio"

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
