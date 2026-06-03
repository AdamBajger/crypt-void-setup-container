#!/bin/bash
# tools/qemu-vm-setup.sh - QEMU command-line builder + run helpers.
#
# Provides:
#   run_install_vm <raw-disk> <live-iso> <seed-iso> <logfile> [timeout]
#   run_verify_vm  <raw-disk> <logfile> [timeout] [luks-passphrase]
#
# The install VM boots the Void live kernel/initrd DIRECTLY (qemu -kernel/
# -initrd/-append) so we can append `console=ttyS0,115200n8 live.autologin`
# to the cmdline without remastering the ISO. The live squashfs is still found
# on the attached cdrom via root=live:CDLABEL=VOID_LIVE. Both VMs are then
# driven over the serial console by an expect script (see tools/*.expect).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Distros disagree on OVMF filenames. Probe known locations; the env vars
# still let a caller override.
_qemu_first_existing() { for f in "$@"; do [[ -f "$f" ]] && { echo "$f"; return; }; done; }
QEMU_OVMF_CODE="${QEMU_OVMF_CODE:-$(_qemu_first_existing \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd)}"
QEMU_OVMF_VARS_TEMPLATE="${QEMU_OVMF_VARS_TEMPLATE:-$(_qemu_first_existing \
    /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/OVMF/OVMF_VARS.fd \
    /usr/share/edk2-ovmf/x64/OVMF_VARS.fd \
    /usr/share/edk2/ovmf/OVMF_VARS.fd)}"
QEMU_RAM="${QEMU_RAM:-4096}"
QEMU_VCPUS="${QEMU_VCPUS:-4}"
QEMU_WORK_DIR="${QEMU_WORK_DIR:-$(pwd)/output/qemu-work}"

mkdir -p "${QEMU_WORK_DIR}"

_qemu_log() { echo "[qemu] $*" >&2; }

# Echoes the cpu/accel flags for qemu based on /dev/kvm availability.
qemu_accel_args() {
    if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
        echo "-enable-kvm -cpu host -machine q35,accel=kvm"
    else
        _qemu_log "WARNING: /dev/kvm unavailable, falling back to TCG (slow)."
        echo "-cpu max -machine q35,accel=tcg"
    fi
}

# Prepares a writable per-run OVMF VARS file and echoes its path.
qemu_prepare_vars() {
    local tag="${1:-run}"
    local vars="${QEMU_WORK_DIR}/OVMF_VARS.${tag}.fd"
    if [[ ! -f "${QEMU_OVMF_VARS_TEMPLATE}" ]]; then
        _qemu_log "ERROR: OVMF VARS template not found at ${QEMU_OVMF_VARS_TEMPLATE}"
        return 1
    fi
    cp -f "${QEMU_OVMF_VARS_TEMPLATE}" "${vars}"
    echo "${vars}"
}

# Echoes the OVMF -drive args for both CODE (read-only) and VARS (writable).
qemu_ovmf_args() {
    local vars="$1"
    if [[ ! -f "${QEMU_OVMF_CODE}" ]]; then
        _qemu_log "ERROR: OVMF CODE not found at ${QEMU_OVMF_CODE}"
        return 1
    fi
    printf -- '-drive if=pflash,format=raw,readonly=on,file=%s -drive if=pflash,format=raw,file=%s' \
        "${QEMU_OVMF_CODE}" "${vars}"
}

# Extracts the live kernel + initrd and derives the boot cmdline from the ISO.
# Sets QEMU_KERNEL, QEMU_INITRD and QEMU_APPEND.
qemu_extract_live_boot() {
    local iso="$1"
    command -v xorriso >/dev/null || { _qemu_log "ERROR: xorriso required to extract live kernel"; return 1; }

    QEMU_KERNEL="${QEMU_WORK_DIR}/vmlinuz"
    QEMU_INITRD="${QEMU_WORK_DIR}/initrd"
    rm -f "${QEMU_KERNEL}" "${QEMU_INITRD}"

    _qemu_log "Extracting /boot/vmlinuz and /boot/initrd from ${iso}..."
    xorriso -osirrox on -indev "${iso}" \
        -extract /boot/vmlinuz "${QEMU_KERNEL}" \
        -extract /boot/initrd  "${QEMU_INITRD}" >/dev/null 2>&1 || true
    [[ -s "${QEMU_KERNEL}" && -s "${QEMU_INITRD}" ]] || {
        _qemu_log "ERROR: could not extract kernel/initrd from ${iso} (expected /boot/vmlinuz, /boot/initrd)"
        return 1
    }

    # Reuse the ISO's own kernel cmdline so we match its dracut live params
    # (CDLABEL, overlay, etc.) exactly, then append our serial + autologin bits.
    local grubcfg="${QEMU_WORK_DIR}/grub_void.cfg" base=""
    rm -f "${grubcfg}"
    xorriso -osirrox on -indev "${iso}" -extract /boot/grub/grub_void.cfg "${grubcfg}" >/dev/null 2>&1 || true
    [[ -s "${grubcfg}" ]] || xorriso -osirrox on -indev "${iso}" -extract /boot/grub/grub.cfg "${grubcfg}" >/dev/null 2>&1 || true
    if [[ -s "${grubcfg}" ]]; then
        # Take the first `linux`/`linuxefi` line and drop its first two tokens
        # (the `linux` keyword and the kernel-image path), leaving the cmdline.
        base=$(grep -m1 -E '^[[:space:]]*linux(efi)?[[:space:]]' "${grubcfg}" \
            | sed -E 's@^[[:space:]]*linux(efi)?[[:space:]]+[^[:space:]]+[[:space:]]+@@')
    fi
    if [[ -z "${base}" ]]; then
        _qemu_log "WARNING: could not parse live cmdline from grub config; using a default."
        base="root=live:CDLABEL=VOID_LIVE ro init=/sbin/init rd.luks=0 rd.md=0 rd.dm=0 loglevel=4 gpt rd.live.overlay.overlayfs=1"
    fi
    # Drop any console= the ISO set so ours win, then put ttyS0 last (primary).
    base=$(echo "${base}" | sed -E 's/console=[^[:space:]]+//g' | tr -s ' ')
    QEMU_APPEND="${base} console=tty0 console=ttyS0,115200n8 live.autologin"
    export QEMU_KERNEL QEMU_INITRD QEMU_APPEND
    _qemu_log "Live boot cmdline: ${QEMU_APPEND}"
}

run_install_vm() {
    local disk="$1" live_iso="$2" seed_iso="$3" logfile="${4:-${QEMU_WORK_DIR}/install.log}" timeout="${5:-3600}"

    [[ -f "${disk}" ]]      || { _qemu_log "missing disk ${disk}"; return 1; }
    [[ -f "${live_iso}" ]]  || { _qemu_log "missing live ISO ${live_iso}"; return 1; }
    [[ -f "${seed_iso}" ]]  || { _qemu_log "missing seed ISO ${seed_iso}"; return 1; }
    command -v expect >/dev/null || { _qemu_log "ERROR: expect is required"; return 1; }

    qemu_extract_live_boot "${live_iso}" || return 1

    local accel; accel=$(qemu_accel_args)

    _qemu_log "Booting install VM (disk=${disk}, live=${live_iso}, seed=${seed_iso})"
    _qemu_log "  serial log: ${logfile}"

    # Built as a single string for expect's `eval spawn`. Paths in CI contain
    # no whitespace; -append is double-quoted so it stays a single arg.
    local cmd="qemu-system-x86_64 ${accel} -m ${QEMU_RAM} -smp ${QEMU_VCPUS}"
    cmd+=" -kernel ${QEMU_KERNEL} -initrd ${QEMU_INITRD} -append \"${QEMU_APPEND}\""
    cmd+=" -drive if=virtio,format=raw,file=${disk},cache=none,discard=unmap"
    cmd+=" -drive media=cdrom,readonly=on,file=${live_iso}"
    cmd+=" -drive media=cdrom,readonly=on,file=${seed_iso}"
    cmd+=" -netdev user,id=n0 -device virtio-net-pci,netdev=n0"
    cmd+=" -display none -serial stdio -monitor none -no-reboot"

    : >"${logfile}"
    QX_QEMU="${cmd}" QX_LOGFILE="${logfile}" QX_TIMEOUT="${timeout}" \
        expect -f "${REPO_ROOT}/tools/qemu-install.expect"
}

run_verify_vm() {
    local disk="$1" logfile="${2:-${QEMU_WORK_DIR}/verify.log}" timeout="${3:-300}" luks="${4:-ci-luks-password-not-secret}"

    [[ -f "${disk}" ]] || { _qemu_log "missing disk ${disk}"; return 1; }
    command -v expect >/dev/null || { _qemu_log "ERROR: expect is required"; return 1; }

    local vars; vars=$(qemu_prepare_vars verify)
    local accel; accel=$(qemu_accel_args)
    local ovmf;  ovmf=$(qemu_ovmf_args "${vars}")

    _qemu_log "Booting verify VM (disk=${disk}, timeout=${timeout}s)"
    _qemu_log "  serial log: ${logfile}"

    local cmd="qemu-system-x86_64 ${accel} -m ${QEMU_RAM} -smp ${QEMU_VCPUS} ${ovmf}"
    cmd+=" -drive if=virtio,format=raw,file=${disk},cache=none,discard=unmap"
    cmd+=" -boot order=c,menu=off"
    cmd+=" -netdev user,id=n0 -device virtio-net-pci,netdev=n0"
    cmd+=" -display none -serial stdio -monitor none -no-reboot"

    : >"${logfile}"
    QX_QEMU="${cmd}" QX_LOGFILE="${logfile}" QX_TIMEOUT="${timeout}" QX_LUKS="${luks}" \
        expect -f "${REPO_ROOT}/tools/qemu-verify.expect"
}

# When this file is executed (not sourced), print the resolved settings so
# operators can sanity-check the wrapper.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "QEMU_OVMF_CODE=${QEMU_OVMF_CODE}"
    echo "QEMU_OVMF_VARS_TEMPLATE=${QEMU_OVMF_VARS_TEMPLATE}"
    echo "QEMU_RAM=${QEMU_RAM}"
    echo "QEMU_VCPUS=${QEMU_VCPUS}"
    echo "QEMU_WORK_DIR=${QEMU_WORK_DIR}"
    echo "accel: $(qemu_accel_args)"
fi
