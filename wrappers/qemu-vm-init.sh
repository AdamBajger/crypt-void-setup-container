#!/bin/sh
# VM init — runs as /init inside the QEMU initramfs.
# Mounts the Void live squashfs + 9p host share, binds the build directories,
# then runs entrypoint.sh inside a chroot. Powers the VM off when done.
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

mkdir -p /mnt/host
mkdir -p /mnt/cdrom
mount -t iso9660 /dev/sr0 /mnt/cdrom

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

mkdir -p /mnt/lower /mnt/upper /mnt/work /mnt/root
mount -t squashfs -o ro "$SQUASHFS" /mnt/lower
mount -t overlay overlay \
    -o lowerdir=/mnt/lower,upperdir=/mnt/upper,workdir=/mnt/work \
    /mnt/root

# Try current root first, then Void live lower/root paths after overlay is mounted.
if ! modprobe 9pnet_virtio 2>/dev/null \
    && ! modprobe -d /mnt/lower 9pnet_virtio 2>/dev/null \
    && ! modprobe -d /mnt/root 9pnet_virtio 2>/dev/null; then
    echo "WARNING: could not pre-load 9pnet_virtio module; mount may still work if built in." >&2
fi

mount -t 9p -o trans=virtio,version=9p2000.L hostshare /mnt/host || {
    echo "ERROR: failed to mount hostshare at /mnt/host; verify 9pnet_virtio support and QEMU hostshare settings (-fsdev local + -device virtio-9p-pci)." >&2
    # Brief delay so the error is visible on serial console before poweroff.
    sleep 2
    echo o > /proc/sysrq-trigger
}

. /mnt/host/vm/.build-env
rm -f /mnt/host/vm/.build-env

for d in proc sys dev dev/pts; do
    mkdir -p "/mnt/root/$d"
    mount --bind "/$d" "/mnt/root/$d"
done

mkdir -p /mnt/root/mnt/host
mount --bind /mnt/host /mnt/root/mnt/host

mkdir -p /mnt/root/config /mnt/root/output /mnt/root/setup
mount --bind /mnt/host/config  /mnt/root/config
mount --bind /mnt/host/output  /mnt/root/output
mount --bind /mnt/host/scripts /mnt/root/setup

chroot /mnt/root env \
    LUKS_PASSWORD="$LUKS_PASSWORD" \
    ROOT_PASSWORD="$ROOT_PASSWORD" \
    USER_PASSWORD="$USER_PASSWORD" \
    VOID_XBPS_REPOSITORY="$VOID_XBPS_REPOSITORY" \
    /bin/sh /setup/entrypoint.sh

sync
echo o > /proc/sysrq-trigger
