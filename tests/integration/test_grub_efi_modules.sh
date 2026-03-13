#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_cmd losetup mount umount strings grep mktemp
require_root

IMAGE_PATH="${1:-}"
if [[ -z "$IMAGE_PATH" ]]; then
    IMAGE_PATH=$(resolve_latest_image "$SCRIPT_DIR/../../output")
fi

[[ -f "$IMAGE_PATH" ]] || fail "Image path does not exist: $IMAGE_PATH"
info "Using image: $IMAGE_PATH"

loop_dev=""
mount_dir=""

cleanup() {
    set +e
    if [[ -n "$mount_dir" && -d "$mount_dir" ]]; then
        mountpoint -q "$mount_dir" && umount "$mount_dir"
        rmdir "$mount_dir"
    fi
    if [[ -n "$loop_dev" ]]; then
        losetup -d "$loop_dev"
    fi
}
trap cleanup EXIT

loop_dev=$(losetup --find --show --partscan "$IMAGE_PATH")
info "Attached loop device: $loop_dev"

efi_partition="${loop_dev}p1"
for _ in $(seq 1 20); do
    [[ -b "$efi_partition" ]] && break
    sleep 0.1
done
[[ -b "$efi_partition" ]] || fail "EFI partition device not found: $efi_partition"

mount_dir=$(mktemp -d)
mount -o ro "$efi_partition" "$mount_dir"

boot_efi_binary="$mount_dir/EFI/BOOT/BOOTX64.EFI"
assert_file_exists "$boot_efi_binary"

strings_tmp=$(mktemp)
strings "$boot_efi_binary" > "$strings_tmp"

for module in part_gpt fat ext2 normal cryptodisk luks lvm; do
    assert_contains_word "$module" "$strings_tmp"
done

rm -f "$strings_tmp"
pass "GRUB EFI binary includes required preloaded module names"
