#!/bin/bash
# device-raw.sh - Real-block-device adapter for entrypoint.sh.
#
# Targets a pre-existing block device named in VOID_TARGET_DEVICE (typically
# the virtio-blk node /dev/vda exposed by a QEMU CI runner). Owns no host-side
# image file: the QEMU host's backing file IS the etchable artifact.

part_of() {
    local d="$1" n="$2"
    case "${d##*/}" in
        loop*|nvme*|mmcblk*) echo "${d}p${n}" ;;
        *) echo "${d}${n}" ;;
    esac
}

device_acquire() {
    : "${VOID_TARGET_DEVICE:?VOID_TARGET_DEVICE must be set when VOID_DEVICE_BACKEND=raw}"

    if [[ ! -b "${VOID_TARGET_DEVICE}" ]]; then
        echo "[void-setup] ERROR: VOID_TARGET_DEVICE='${VOID_TARGET_DEVICE}' is not a block device" >&2
        return 1
    fi

    VOID_DEVICE="${VOID_TARGET_DEVICE}"
    VOID_DISK_IMAGE_PATH=""
    VOID_OUTPUT_IMAGE_NAME=""
    VOID_BUILD_TIMESTAMP="${VOID_BUILD_TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}"
    export VOID_DEVICE VOID_DISK_IMAGE_PATH VOID_OUTPUT_IMAGE_NAME VOID_BUILD_TIMESTAMP

    log "  target device = ${VOID_DEVICE} (caller-owned, no host-side image)"
}

device_resolve_partitions() {
    local device="$1"

    partprobe "${device}" 2>/dev/null || true
    udevadm settle || true

    VOID_EFI_PARTITION=$(part_of "${device}" "${VOID_EFI_PARTITION_INDEX}")
    VOID_LUKS_PARTITION=$(part_of "${device}" "${VOID_LUKS_PARTITION_INDEX}")
    export VOID_EFI_PARTITION VOID_LUKS_PARTITION

    if [[ ! -b "${VOID_EFI_PARTITION}" || ! -b "${VOID_LUKS_PARTITION}" ]]; then
        echo "[void-setup] ERROR: Partition nodes did not appear after partprobe+settle: ${VOID_EFI_PARTITION}, ${VOID_LUKS_PARTITION}" >&2
        return 1
    fi

    log "  ${VOID_EFI_PARTITION}  -- EFI System Partition (FAT32)"
    log "  ${VOID_LUKS_PARTITION} -- LUKS1 encrypted partition (contains LVM)"
}

device_release() {
    : # caller owns the device, nothing to release
}

device_finalize() {
    : # the host-side file backing virtio-blk is already the artifact
}
