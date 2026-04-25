#!/bin/bash
# device-loop.sh - Loopback-file device adapter for entrypoint.sh.
#
# Acquires a sparse raw image at OUTPUT_DIR, attaches it via losetup, and
# resolves partition nodes through per-partition offset loops to dodge
# unreliable kernel partition scanning inside containers.

ensure_loop_nodes() {
    [[ -c /dev/loop-control ]] || mknod -m 660 /dev/loop-control c 10 237 || true
    local i
    for i in $(seq 0 63); do
        [[ -b "/dev/loop${i}" ]] || mknod -m 660 "/dev/loop${i}" b 7 "${i}" || true
    done
}

device_acquire() {
    log "Ensuring loop device nodes are present..."
    ensure_loop_nodes

    VOID_BUILD_TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    VOID_OUTPUT_IMAGE_NAME="voidlinux_fde_${VOID_TARGET_ARCH}_${VOID_BUILD_TIMESTAMP}.img"
    VOID_DISK_IMAGE_PATH="${OUTPUT_DIR}/${VOID_OUTPUT_IMAGE_NAME}"
    export VOID_BUILD_TIMESTAMP VOID_OUTPUT_IMAGE_NAME VOID_DISK_IMAGE_PATH

    log "Creating ${VOID_DISK_SIZE_MIB} MiB disk image at ${VOID_DISK_IMAGE_PATH}..."
    truncate -s "${VOID_DISK_SIZE_MIB}M" "${VOID_DISK_IMAGE_PATH}"

    log "Attaching disk image to a loop device..."
    VOID_DEVICE=$(losetup --find --show --partscan "${VOID_DISK_IMAGE_PATH}")
    export VOID_DEVICE
    log "  loop device = ${VOID_DEVICE}"
}

device_resolve_partitions() {
    local device="$1"
    local sector_size efi_part_line luks_part_line
    local efi_start_sectors efi_size_sectors luks_start_sectors luks_size_sectors

    sector_size=$(blockdev --getss "${device}")
    efi_part_line=$(parted -ms "${device}" unit s print | awk -F: '$1=="1" {print $2":"$4}')
    luks_part_line=$(parted -ms "${device}" unit s print | awk -F: '$1=="2" {print $2":"$4}')

    if [[ -z "${efi_part_line}" ]]; then
        echo "[void-setup] ERROR: Could not read EFI partition layout from parted output" >&2
        return 1
    fi
    if [[ -z "${luks_part_line}" ]]; then
        echo "[void-setup] ERROR: Could not read LUKS partition layout from parted output" >&2
        return 1
    fi

    efi_start_sectors=${efi_part_line%:*}
    efi_size_sectors=${efi_part_line#*:}
    luks_start_sectors=${luks_part_line%:*}
    luks_size_sectors=${luks_part_line#*:}

    efi_start_sectors=${efi_start_sectors%s}
    efi_size_sectors=${efi_size_sectors%s}
    luks_start_sectors=${luks_start_sectors%s}
    luks_size_sectors=${luks_size_sectors%s}

    VOID_EFI_PARTITION=$(losetup --find --show \
        --offset "$((efi_start_sectors * sector_size))" \
        --sizelimit "$((efi_size_sectors * sector_size))" \
        "${VOID_DISK_IMAGE_PATH}")
    VOID_LUKS_PARTITION=$(losetup --find --show \
        --offset "$((luks_start_sectors * sector_size))" \
        --sizelimit "$((luks_size_sectors * sector_size))" \
        "${VOID_DISK_IMAGE_PATH}")
    export VOID_EFI_PARTITION VOID_LUKS_PARTITION

    log "  ${VOID_EFI_PARTITION}  -- EFI System Partition (FAT32)"
    log "  ${VOID_LUKS_PARTITION} -- LUKS1 encrypted partition (contains LVM)"
}

device_release() {
    if [[ -n "${VOID_EFI_PARTITION:-}" ]]; then
        losetup -d "${VOID_EFI_PARTITION}" 2>/dev/null || true
    fi
    if [[ -n "${VOID_LUKS_PARTITION:-}" ]]; then
        losetup -d "${VOID_LUKS_PARTITION}" 2>/dev/null || true
    fi
    if [[ -n "${VOID_DEVICE:-}" ]]; then
        losetup -d "${VOID_DEVICE}" 2>/dev/null || true
    fi
}

device_finalize() {
    local build_succeeded="$1"

    [[ "${build_succeeded}" -eq 1 ]] || return 0
    [[ "${VOID_BUILD_COMPLETED:-0}" -eq 1 ]] || return 0
    [[ -n "${VOID_DISK_IMAGE_PATH:-}" && -f "${VOID_DISK_IMAGE_PATH}" ]] || return 0

    if declare -F build_final_image_name >/dev/null 2>&1; then
        VOID_FINAL_IMAGE_NAME=$(build_final_image_name "${VOID_LAST_FILES_USED_HR:-}")
    else
        VOID_FINAL_IMAGE_NAME="${VOID_OUTPUT_IMAGE_NAME}"
    fi

    local finalized_image_path="${OUTPUT_DIR}/${VOID_FINAL_IMAGE_NAME}"
    log "Renaming completed image to ${finalized_image_path}..."
    mv "${VOID_DISK_IMAGE_PATH}" "${finalized_image_path}"
}
