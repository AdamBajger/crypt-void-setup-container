#!/bin/bash
# tools/qemu-vm-setup.sh - QEMU command-line builder + run helpers.
#
# Provides:
#   run_install_vm <raw-disk> <live-iso> <seed-iso> <signal-socket> [logfile]
#   run_verify_vm  <raw-disk> [logfile] [timeout-seconds]
#
# Both functions assemble qemu-system-x86_64 invocations with OVMF, KVM if
# available, and headless serial-on-stdio.

set -euo pipefail

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

run_install_vm() {
    local disk="$1" live_iso="$2" seed_iso="$3" signal_sock="$4" logfile="${5:-${QEMU_WORK_DIR}/install.log}"

    [[ -f "${disk}" ]]      || { _qemu_log "missing disk ${disk}"; return 1; }
    [[ -f "${live_iso}" ]]  || { _qemu_log "missing live ISO ${live_iso}"; return 1; }
    [[ -f "${seed_iso}" ]]  || { _qemu_log "missing seed ISO ${seed_iso}"; return 1; }

    local vars; vars=$(qemu_prepare_vars install)
    local accel; accel=$(qemu_accel_args)
    local ovmf;  ovmf=$(qemu_ovmf_args "${vars}")

    rm -f "${signal_sock}"

    _qemu_log "Booting install VM (disk=${disk}, live=${live_iso}, seed=${seed_iso})"
    _qemu_log "  signal socket: ${signal_sock}"
    _qemu_log "  serial log:    ${logfile}"

    # shellcheck disable=SC2086
    qemu-system-x86_64 \
        ${accel} \
        -m "${QEMU_RAM}" \
        -smp "${QEMU_VCPUS}" \
        ${ovmf} \
        -drive if=virtio,format=raw,file="${disk}",cache=none,discard=unmap \
        -drive media=cdrom,readonly=on,file="${live_iso}" \
        -drive media=cdrom,readonly=on,file="${seed_iso}" \
        -boot order=d,menu=off \
        -device virtio-serial-pci \
        -chardev socket,id=instchan,path="${signal_sock}",server=on,wait=off \
        -device virtserialport,chardev=instchan,name=qemu-install-status \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -display none \
        -serial "file:${logfile}" \
        -monitor none \
        -no-reboot
}

run_verify_vm() {
    local disk="$1" logfile="${2:-${QEMU_WORK_DIR}/verify.log}" timeout="${3:-180}"

    [[ -f "${disk}" ]] || { _qemu_log "missing disk ${disk}"; return 1; }

    local vars; vars=$(qemu_prepare_vars verify)
    local accel; accel=$(qemu_accel_args)
    local ovmf;  ovmf=$(qemu_ovmf_args "${vars}")

    _qemu_log "Booting verify VM (disk=${disk}, timeout=${timeout}s)"
    _qemu_log "  serial log: ${logfile}"

    : >"${logfile}"

    # shellcheck disable=SC2086
    timeout --foreground -s KILL "${timeout}" \
        qemu-system-x86_64 \
            ${accel} \
            -m "${QEMU_RAM}" \
            -smp "${QEMU_VCPUS}" \
            ${ovmf} \
            -drive if=virtio,format=raw,file="${disk}",cache=none,discard=unmap \
            -boot order=c,menu=off \
            -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
            -display none \
            -serial "file:${logfile}" \
            -monitor none \
            -no-reboot || true
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
