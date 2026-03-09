#!/bin/bash
# void-installation-script.sh — VoidLinux system configuration script.
#
# This script runs INSIDE the xchroot environment set up by entrypoint.sh.
# It receives its configuration through environment variables exported by
# entrypoint.sh:
#
#   VOID_HOSTNAME        — system hostname
#   VOID_USERNAME        — name of the regular user to create
#   VOID_TIMEZONE        — timezone (e.g. "Europe/Prague")
#   VOID_LOCALE          — locale  (e.g. "en_US.UTF-8")
#   VOID_KEYMAP          — keymap  (e.g. "us")
#   VOID_EFI_PARTITION   — block device path of the EFI partition
#   VOID_BOOT_PARTITION  — block device path of the boot partition
#   VOID_LUKS_PARTITION  — block device path of the LUKS partition
#   VOID_LUKS_DEVICE_NAME  — dm name for the opened LUKS container
#   VOID_LVM_VG_NAME       — LVM volume group name
#   VOID_LVM_ROOT_LV_NAME  — root logical volume name
#   VOID_LVM_SWAP_LV_NAME  — swap logical volume name
#   LUKS_PASSWORD        — LUKS passphrase (used only if you add an additional
#                          keyslot or need to reference it here)
#   ROOT_PASSWORD        — password for the root account
#   USER_PASSWORD        — password for VOID_USERNAME
#
# Customise this file freely.  It is the single place for any adjustments to
# the installed system — additional packages, extra services, dotfiles, etc.

set -euo pipefail

log() { echo "[void-install] $*"; }

# ---------------------------------------------------------------------------
# Hostname
# ---------------------------------------------------------------------------
log "Setting hostname to ${VOID_HOSTNAME}..."
echo "${VOID_HOSTNAME}" > /etc/hostname

# ---------------------------------------------------------------------------
# Timezone
# ---------------------------------------------------------------------------
log "Setting timezone to ${VOID_TIMEZONE}..."
ln -sf "/usr/share/zoneinfo/${VOID_TIMEZONE}" /etc/localtime

# ---------------------------------------------------------------------------
# Locale
# ---------------------------------------------------------------------------
log "Configuring locale ${VOID_LOCALE}..."
echo "LANG=${VOID_LOCALE}" > /etc/locale.conf
# Append the locale to /etc/default/libc-locales if not already present.
if ! grep -qF "${VOID_LOCALE}" /etc/default/libc-locales; then
    echo "${VOID_LOCALE} UTF-8" >> /etc/default/libc-locales
fi
xbps-reconfigure -f glibc-locales

# ---------------------------------------------------------------------------
# Console keymap
# ---------------------------------------------------------------------------
log "Setting console keymap to ${VOID_KEYMAP}..."
echo "KEYMAP=${VOID_KEYMAP}" > /etc/vconsole.conf

# ---------------------------------------------------------------------------
# Root password
# ---------------------------------------------------------------------------
log "Setting root password..."
echo "root:${ROOT_PASSWORD}" | chpasswd

# ---------------------------------------------------------------------------
# Regular user
# ---------------------------------------------------------------------------
log "Creating user ${VOID_USERNAME}..."
useradd -m -G wheel,audio,video,cdrom,floppy,optical,kvm,input,storage \
    "${VOID_USERNAME}"
echo "${VOID_USERNAME}:${USER_PASSWORD}" | chpasswd

# Allow members of the wheel group to use sudo.
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel-sudo

# ---------------------------------------------------------------------------
# /etc/fstab
# ---------------------------------------------------------------------------
log "Generating /etc/fstab..."

VOID_EFI_UUID=$(blkid -s UUID -o value "${VOID_EFI_PARTITION}")
VOID_BOOT_UUID=$(blkid -s UUID -o value "${VOID_BOOT_PARTITION}")
VOID_ROOT_UUID=$(blkid -s UUID -o value \
    "/dev/${VOID_LVM_VG_NAME}/${VOID_LVM_ROOT_LV_NAME}")
VOID_SWAP_UUID=$(blkid -s UUID -o value \
    "/dev/${VOID_LVM_VG_NAME}/${VOID_LVM_SWAP_LV_NAME}")

cat > /etc/fstab << FSTAB
# <file system>               <mount point>  <type>  <options>              <dump>  <pass>
UUID=${VOID_ROOT_UUID}        /              ext4    defaults,relatime      0       1
UUID=${VOID_BOOT_UUID}        /boot          ext4    defaults,relatime      0       2
UUID=${VOID_EFI_UUID}         /boot/efi      vfat    defaults,relatime      0       2
UUID=${VOID_SWAP_UUID}        none           swap    sw                     0       0
tmpfs                         /tmp           tmpfs   defaults,nosuid,nodev  0       0
FSTAB

# ---------------------------------------------------------------------------
# /etc/crypttab
# ---------------------------------------------------------------------------
log "Generating /etc/crypttab..."

VOID_LUKS_UUID=$(blkid -s UUID -o value "${VOID_LUKS_PARTITION}")

cat > /etc/crypttab << CRYPTTAB
# <name>                <device>                           <key>  <options>
${VOID_LUKS_DEVICE_NAME}  UUID=${VOID_LUKS_UUID}  none   luks,discard
CRYPTTAB

# ---------------------------------------------------------------------------
# dracut — include crypt + lvm modules in the initramfs.
# ---------------------------------------------------------------------------
log "Configuring dracut for LUKS and LVM..."
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/void-crypt-lvm.conf << DRACUT
add_dracutmodules+=" crypt lvm "
install_items+=" /etc/crypttab "
DRACUT

# ---------------------------------------------------------------------------
# GRUB — configure and install the EFI bootloader.
# ---------------------------------------------------------------------------
log "Configuring GRUB..."

# Kernel parameters passed to the initramfs:
#   rd.luks.uuid  — tells dracut which LUKS partition to unlock.
#   rd.lvm.vg     — activates the correct volume group after unlock.
#   root          — the root device once LVM is active.
cat > /etc/default/grub << GRUBCONF
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Void Linux"
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 rd.luks.uuid=${VOID_LUKS_UUID} rd.lvm.vg=${VOID_LVM_VG_NAME} root=/dev/${VOID_LVM_VG_NAME}/${VOID_LVM_ROOT_LV_NAME}"
GRUB_CMDLINE_LINUX=""
GRUBCONF

log "Installing GRUB to EFI partition..."
grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=void-linux \
    --recheck

log "Generating GRUB configuration..."
grub-mkconfig -o /boot/grub/grub.cfg

# ---------------------------------------------------------------------------
# Initramfs — regenerate with the crypt+lvm dracut configuration.
# ---------------------------------------------------------------------------
log "Regenerating initramfs with dracut..."
dracut --force --hostonly

# ---------------------------------------------------------------------------
# runit services
# ---------------------------------------------------------------------------
log "Enabling runit services..."
ln -sf /etc/sv/dhcpcd /etc/runit/runsvdir/default/
ln -sf /etc/sv/sshd   /etc/runit/runsvdir/default/

# ---------------------------------------------------------------------------
# Finalise xbps package configuration.
# ---------------------------------------------------------------------------
log "Reconfiguring all installed packages..."
xbps-reconfigure -fa

log "VoidLinux installation configuration complete."
