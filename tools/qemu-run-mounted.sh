#!/bin/bash
# tools/qemu-run-mounted.sh — run INSIDE a booted Void live VM when this repo
# is MOUNTED into the guest (9p/virtfs), not copied. No clone, no download, no
# seed image: it just points entrypoint.sh at the mounted tree and runs.
#
# Host (Linux / WSL2), add to the qemu line:
#   -virtfs local,path=/path/to/repo,mount_tag=cvs,security_model=none,readonly=on
#
# Guest (root):
#   modprobe 9pnet_virtio 2>/dev/null
#   mkdir -p /mnt/cvs
#   mount -t 9p -o trans=virtio,version=9p2000.L,ro cvs /mnt/cvs
#   bash /mnt/cvs/tools/qemu-run-mounted.sh
#
# Assumes the live ISO already has the installer tools (parted, cryptsetup,
# lvm2, mkfs.*) — i.e. a normal void-live image, NOT the stripped "-base" one.
# Override creds/target via the environment before running.

set -euo pipefail

M="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # the mounted repo root
log() { echo "[run-mounted] $*"; }
die() { echo "[run-mounted] ERROR: $*" >&2; exit 1; }

[[ $(id -u) -eq 0 ]] || die "run as root"
[[ -f "${M}/scripts/entrypoint.sh" ]] || die "repo not found at ${M} (is it mounted?)"

TARGET="${VOID_TARGET_DEVICE:-/dev/vda}"
[[ -b "${TARGET}" ]] || die "target ${TARGET} is not a block device (set VOID_TARGET_DEVICE)"

# Bring up networking (base-system is pulled from the repo mirror over the net).
if command -v dhcpcd >/dev/null 2>&1; then
    dhcpcd -w -t 20 2>/dev/null || dhcpcd -t 20 2>/dev/null || true
fi

# Wire the in-VM paths entrypoint.sh expects to the mounted tree.
mkdir -p /config /setup /tools /binaries /output
mountpoint -q /setup    || mount --bind "${M}/scripts"   /setup
mountpoint -q /tools    || mount --bind "${M}/tools"     /tools
mountpoint -q /binaries || mount --bind "${M}/binaries"  /binaries
cp -f "${M}/config/disk.conf"          /config/disk.conf
cp -f "${M}/config/system.conf"        /config/system.conf
cp -f "${M}/config/extra-packages.txt" /config/extra-packages.txt

# Reuse the SAME .env the Docker path uses (LUKS_PASSWORD, ROOT_PASSWORD,
# USER_PASSWORD, VOID_XBPS_REPOSITORY). It is on the mounted repo, so nothing
# has to be typed in the VM. System config (disk/system/packages) comes from
# config/ below, exactly as every other path.
if [[ -f "${M}/.env" ]]; then
    log "Loading credentials from ${M}/.env"
    set -a; . "${M}/.env"; set +a
    TARGET="${VOID_TARGET_DEVICE:-${TARGET}}"
    [[ -b "${TARGET}" ]] || die "target ${TARGET} (from .env) is not a block device"
else
    log "No .env on the share — falling back to default passwords ('voidlinux')."
fi

export VOID_DEVICE_BACKEND=raw
export VOID_TARGET_DEVICE="${TARGET}"
# The minimal live env has no jq/gpg; binaries are mounted from the (already
# host-verified) repo, so skip the in-VM preflight by default.
export VOID_SKIP_PREFLIGHT="${VOID_SKIP_PREFLIGHT:-1}"
export LUKS_PASSWORD="${LUKS_PASSWORD:-voidlinux}"
export ROOT_PASSWORD="${ROOT_PASSWORD:-voidlinux}"
export USER_PASSWORD="${USER_PASSWORD:-voidlinux}"

log "Installing Void onto ${TARGET} from mounted repo at ${M}..."
exec bash /setup/entrypoint.sh
