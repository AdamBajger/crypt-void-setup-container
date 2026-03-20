#!/bin/bash
# reporting.sh - Disk usage reporting and image naming helpers for entrypoint.

report_phase_usage() {
    local phase_label="$1"
    local root_used efi_used image_consumed

    log "Disk usage after ${phase_label}:"
    
    root_used=$(du -shx "${VOID_INSTALL_MOUNT}" 2>/dev/null | awk '{print $1}' || echo "N/A")
    log "  root_used_total       = ${root_used}"
    
    efi_used=$(du -sh "${VOID_INSTALL_MOUNT}/boot/efi" 2>/dev/null | awk '{print $1}' || echo "N/A")
    log "  efi_used_total        = ${efi_used}"
    
    image_consumed=$(du -sh "${VOID_DISK_IMAGE_PATH}" 2>/dev/null | awk '{print $1}' || echo "N/A")
    log "  image_space_consumed  = ${image_consumed}"

    # Store human-readable size for final image naming
    VOID_LAST_FILES_USED_HR="${root_used}"
}

build_final_image_name() {
    local files_used_hr="$1"

    printf 'voidlinux_fde_%s_du%s_%s.img' "${VOID_TARGET_ARCH}" "${files_used_hr}" "${VOID_BUILD_TIMESTAMP}"
}
