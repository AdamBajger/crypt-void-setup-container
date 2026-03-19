#!/bin/bash
# reporting.sh — Disk usage reporting and image naming helpers for entrypoint.

bytes_to_mib() {
    awk -v bytes="$1" 'BEGIN { printf "%.2f", bytes / 1048576 }'
}

bytes_to_gib() {
    awk -v bytes="$1" 'BEGIN { printf "%.2f", bytes / 1073741824 }'
}

get_df_value_bytes() {
    local mount_path="$1"
    local field_name="$2"

    df -B1P "${mount_path}" | awk -v field_name="${field_name}" '
        NR == 2 {
            if (field_name == "size") {
                print $2
            } else if (field_name == "used") {
                print $3
            } else if (field_name == "avail") {
                print $4
            }
        }
    '
}

report_phase_usage() {
    local phase_label="$1"
    local root_size_bytes root_used_bytes root_avail_bytes
    local efi_size_bytes efi_used_bytes efi_avail_bytes
    local files_used_bytes image_consumed_bytes image_total_bytes

    root_size_bytes=$(get_df_value_bytes "${VOID_INSTALL_MOUNT}" size)
    root_used_bytes=$(get_df_value_bytes "${VOID_INSTALL_MOUNT}" used)
    root_avail_bytes=$(get_df_value_bytes "${VOID_INSTALL_MOUNT}" avail)

    efi_size_bytes=$(get_df_value_bytes "${VOID_INSTALL_MOUNT}/boot/efi" size)
    efi_used_bytes=$(get_df_value_bytes "${VOID_INSTALL_MOUNT}/boot/efi" used)
    efi_avail_bytes=$(get_df_value_bytes "${VOID_INSTALL_MOUNT}/boot/efi" avail)

    files_used_bytes=$((root_used_bytes + efi_used_bytes))
    image_total_bytes=$(blockdev --getsize64 "${VOID_LOOP_DEVICE}")
    image_consumed_bytes=$((image_total_bytes - root_avail_bytes - efi_avail_bytes))
    VOID_LAST_FILES_USED_BYTES="${files_used_bytes}"

    log "Disk usage after ${phase_label}:"
    log "  root_fs_used          = ${root_used_bytes} bytes ($(bytes_to_mib "${root_used_bytes}") MiB, $(bytes_to_gib "${root_used_bytes}") GiB)"
    log "  root_fs_free          = ${root_avail_bytes} bytes ($(bytes_to_mib "${root_avail_bytes}") MiB, $(bytes_to_gib "${root_avail_bytes}") GiB)"
    log "  root_fs_size          = ${root_size_bytes} bytes ($(bytes_to_mib "${root_size_bytes}") MiB, $(bytes_to_gib "${root_size_bytes}") GiB)"
    log "  efi_fs_used           = ${efi_used_bytes} bytes ($(bytes_to_mib "${efi_used_bytes}") MiB, $(bytes_to_gib "${efi_used_bytes}") GiB)"
    log "  efi_fs_free           = ${efi_avail_bytes} bytes ($(bytes_to_mib "${efi_avail_bytes}") MiB, $(bytes_to_gib "${efi_avail_bytes}") GiB)"
    log "  efi_fs_size           = ${efi_size_bytes} bytes ($(bytes_to_mib "${efi_size_bytes}") MiB, $(bytes_to_gib "${efi_size_bytes}") GiB)"
    log "  files_used_total      = ${files_used_bytes} bytes ($(bytes_to_mib "${files_used_bytes}") MiB, $(bytes_to_gib "${files_used_bytes}") GiB)"
    log "  image_space_consumed  = ${image_consumed_bytes} bytes ($(bytes_to_mib "${image_consumed_bytes}") MiB, $(bytes_to_gib "${image_consumed_bytes}") GiB)"
}

build_final_image_name() {
    local files_used_bytes="$1"
    local files_used_gib

    files_used_gib=$(bytes_to_gib "${files_used_bytes}")
    printf 'voidlinux_fde_%s_du%sgib_%s.img' "${VOID_TARGET_ARCH}" "${files_used_gib}" "${VOID_BUILD_TIMESTAMP}"
}
