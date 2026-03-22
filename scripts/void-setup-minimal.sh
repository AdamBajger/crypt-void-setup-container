#!/bin/bash
# void-setup-minimal.sh - Minimal system configuration for a bootable
# VoidLinux installation.
#
# This script runs INSIDE the xchroot environment, called from entrypoint.sh
# after the base packages have been installed and the target rootfs has been
# mounted.

set -euo pipefail

echo "Setting hostname to ${VOID_HOSTNAME}..."
echo "${VOID_HOSTNAME}" > /etc/hostname

# ---------------------------------------------------------------------------
# Timezone
# ---------------------------------------------------------------------------
echo "Setting timezone to ${VOID_TIMEZONE}..."
ln -sf "/usr/share/zoneinfo/${VOID_TIMEZONE}" /etc/localtime

# ---------------------------------------------------------------------------
# Locale
# ---------------------------------------------------------------------------
echo "Configuring locale ${VOID_LOCALE}..."
echo "LANG=${VOID_LOCALE}" > /etc/locale.conf
if ! grep -qxF "${VOID_LOCALE} UTF-8" /etc/default/libc-locales 2>/dev/null; then
    sed -i "s/^#\(${VOID_LOCALE} .\+\)/\1/" /etc/default/libc-locales
    if ! grep -qF "${VOID_LOCALE}" /etc/default/libc-locales; then
        echo "${VOID_LOCALE} UTF-8" >> /etc/default/libc-locales
    fi
fi
xbps-reconfigure -f glibc-locales

# ---------------------------------------------------------------------------
# Console keymap
# ---------------------------------------------------------------------------
echo "Setting console keymap to ${VOID_KEYMAP}..."
echo "KEYMAP=${VOID_KEYMAP}" > /etc/vconsole.conf

# ---------------------------------------------------------------------------
# Install runtime services
# ---------------------------------------------------------------------------
echo "Installing runtime services (dhcpcd, openssh)..."
XBPS_ARCH="${VOID_TARGET_ARCH}" xbps-install -y \
    --repository="${VOID_XBPS_REPOSITORY}" \
    dhcpcd openssh pam

[ -f /etc/pam.d/passwd ] || { echo "ERROR: /etc/pam.d/passwd missing"; exit 1; }

if [ -f /etc/pam.d/system-auth ]; then
    pam_include_file="/etc/pam.d/system-auth"
elif [ -f /etc/pam.d/system-login ]; then
    pam_include_file="/etc/pam.d/system-login"
else
    echo "ERROR: neither /etc/pam.d/system-auth nor /etc/pam.d/system-login exists"
    exit 1
fi

cat > /etc/pam.d/chpasswd << 'PAMCHPASSWD'
auth       sufficient   pam_rootok.so
account    required     pam_permit.so
password   required     pam_unix.so nullok sha512
session    required     pam_permit.so
PAMCHPASSWD

[ -f /etc/pam.d/chpasswd ] || { echo "ERROR: /etc/pam.d/chpasswd missing"; exit 1; }

sed -i '/pam_pwquality\.so/d;/pam_cracklib\.so/d' /etc/pam.d/passwd
sed -i '/pam_pwquality\.so/d;/pam_cracklib\.so/d' "${pam_include_file}"

sed -Ei '/pam_unix\.so/ s/(^|[[:space:]])(retry=[^[:space:]]+|minlen=[^[:space:]]+|ucredit=[^[:space:]]+|lcredit=[^[:space:]]+|dcredit=[^[:space:]]+|ocredit=[^[:space:]]+)//g' /etc/pam.d/passwd
sed -Ei '/pam_unix\.so/ s/(^|[[:space:]])(retry=[^[:space:]]+|minlen=[^[:space:]]+|ucredit=[^[:space:]]+|lcredit=[^[:space:]]+|dcredit=[^[:space:]]+|ocredit=[^[:space:]]+)//g' "${pam_include_file}"

[ -f /usr/lib/security/pam_unix.so ] || [ -f /lib/security/pam_unix.so ] || { echo "ERROR: pam_unix.so not found"; exit 1; }

[ -f /etc/nsswitch.conf ] || { echo "ERROR: /etc/nsswitch.conf missing"; exit 1; }
if grep -q '^passwd:' /etc/nsswitch.conf; then
    sed -i 's/^passwd:.*/passwd: files/' /etc/nsswitch.conf
else
    echo 'passwd: files' >> /etc/nsswitch.conf
fi
if grep -q '^shadow:' /etc/nsswitch.conf; then
    sed -i 's/^shadow:.*/shadow: files/' /etc/nsswitch.conf
else
    echo 'shadow: files' >> /etc/nsswitch.conf
fi
if grep -q '^group:' /etc/nsswitch.conf; then
    sed -i 's/^group:.*/group: files/' /etc/nsswitch.conf
else
    echo 'group: files' >> /etc/nsswitch.conf
fi

[ -f /etc/passwd ] || { echo "ERROR: /etc/passwd missing"; exit 1; }
[ -f /etc/shadow ] || { echo "ERROR: /etc/shadow missing"; exit 1; }
chmod 644 /etc/passwd
chmod 600 /etc/shadow
[ -w /etc/passwd ] || { echo "ERROR: /etc/passwd not writable"; exit 1; }
[ -w /etc/shadow ] || { echo "ERROR: /etc/shadow not writable"; exit 1; }

mountpoint -q /proc || mount -t proc proc /proc
mountpoint -q /sys || mount -t sysfs sys /sys
mountpoint -q /dev || mount --bind /dev /dev

# ---------------------------------------------------------------------------
# Root password
# ---------------------------------------------------------------------------
echo "Creating user ${VOID_USERNAME}..."
getent passwd root
id -u "${VOID_USERNAME}" >/dev/null 2>&1 || useradd -m -G wheel,audio,video,cdrom,floppy,optical,kvm,input,storage "${VOID_USERNAME}"

set +e
printf 'root:%s\n' "${ROOT_PASSWORD}" | chpasswd
rc=$?
set -e
if [ "${rc}" -ne 0 ]; then
    echo "chpasswd failed for root"
    dmesg | tail
    if [ -f /var/log/auth.log ]; then
        cat /var/log/auth.log
    fi
    exit 1
fi

set +e
printf '%s:%s\n' "${VOID_USERNAME}" "${USER_PASSWORD}" | chpasswd
rc=$?
set -e
if [ "${rc}" -ne 0 ]; then
    echo "chpasswd failed for user"
    dmesg | tail
    if [ -f /var/log/auth.log ]; then
        cat /var/log/auth.log
    fi
    exit 1
fi

getent passwd root
getent shadow root
getent passwd "${VOID_USERNAME}"
getent shadow "${VOID_USERNAME}"

grep '^root:' /etc/shadow | grep -Eq '^[^:]+:[^!*]' || { echo "root password not set"; exit 1; }
grep "^${VOID_USERNAME}:" /etc/shadow | grep -Eq '^[^:]+:[^!*]' || { echo "user password not set"; exit 1; }

root_status="$(passwd -S root)"
user_status="$(passwd -S "${VOID_USERNAME}")"
echo "${root_status}"
echo "${user_status}"
passwd -S root | grep -q ' P ' || { echo "root not active"; exit 1; }
passwd -S "${VOID_USERNAME}" | grep -q ' P ' || { echo "user not active"; exit 1; }

# Allow members of the wheel group to use sudo.
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel-sudo

# ---------------------------------------------------------------------------
# /etc/fstab
# ---------------------------------------------------------------------------
echo "Generating /etc/fstab..."
VOID_EFI_UUID=$(blkid -s UUID -o value "${VOID_EFI_PARTITION}")
VOID_ROOT_UUID=$(blkid -s UUID -o value \
    "/dev/${VOID_LVM_VG_NAME}/${VOID_LVM_ROOT_LV_NAME}")
VOID_SWAP_UUID=$(blkid -s UUID -o value \
    "/dev/${VOID_LVM_VG_NAME}/${VOID_LVM_SWAP_LV_NAME}")

cat > /etc/fstab << FSTAB
# <file system>               <mount point>  <type>  <options>              <dump>  <pass>
UUID=${VOID_ROOT_UUID}        /              ext4    defaults,relatime      0       1
UUID=${VOID_EFI_UUID}         /boot/efi      vfat    defaults,relatime      0       2
UUID=${VOID_SWAP_UUID}        none           swap    sw                     0       0
tmpfs                         /tmp           tmpfs   defaults,nosuid,nodev  0       0
FSTAB

# ---------------------------------------------------------------------------
# /etc/crypttab
# ---------------------------------------------------------------------------
echo "Generating /etc/crypttab..."
VOID_LUKS_UUID=$(blkid -s UUID -o value "${VOID_LUKS_PARTITION}")

cat > /etc/crypttab << CRYPTTAB
# <name>                  <device>                <key>   <options>
${VOID_LUKS_DEVICE_NAME}  UUID=${VOID_LUKS_UUID}  none    luks,discard
CRYPTTAB

# ---------------------------------------------------------------------------
# dracut - include crypt + lvm modules in the initramfs.
# ---------------------------------------------------------------------------
echo "Configuring dracut for LUKS and LVM..."
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/void-crypt-lvm.conf << DRACUT
hostonly="no"
add_dracutmodules+=" crypt lvm "
install_items+=" /etc/crypttab "
DRACUT

# ---------------------------------------------------------------------------
# GRUB - configure and install the EFI bootloader.
# ---------------------------------------------------------------------------
echo "Configuring GRUB..."

cat > /etc/default/grub << GRUBCONF
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Void Linux"
GRUB_ENABLE_CRYPTODISK=y
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 rd.luks.uuid=${VOID_LUKS_UUID} rd.lvm.vg=${VOID_LVM_VG_NAME} root=/dev/${VOID_LVM_VG_NAME}/${VOID_LVM_ROOT_LV_NAME}"
GRUB_CMDLINE_LINUX=""
GRUBCONF

echo "Installing GRUB to EFI partition..."
grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=void-linux \
    --modules="part_gpt fat ext2 normal cryptodisk luks lvm" \
    --no-nvram \
    --removable \
    --recheck

echo "Generating GRUB configuration..."
grub-mkconfig -o /boot/grub/grub.cfg

# ---------------------------------------------------------------------------
# runit services
# ---------------------------------------------------------------------------
echo "Enabling runit services..."
ln -sf /etc/sv/dhcpcd /etc/runit/runsvdir/default/
ln -sf /etc/sv/sshd   /etc/runit/runsvdir/default/

# ---------------------------------------------------------------------------
# Finalise xbps package configuration.
# ---------------------------------------------------------------------------
echo "Reconfiguring all installed packages (this regenerates the initramfs)..."
xbps-reconfigure -fa

# Re-apply credentials as the final step in case any package hook touched
# account state during bulk reconfigure.
getent passwd root
id -u "${VOID_USERNAME}" >/dev/null 2>&1 || useradd -m "${VOID_USERNAME}"

set +e
printf 'root:%s\n' "${ROOT_PASSWORD}" | chpasswd
rc=$?
set -e
if [ "${rc}" -ne 0 ]; then
    echo "chpasswd failed for root"
    dmesg | tail
    if [ -f /var/log/auth.log ]; then
        cat /var/log/auth.log
    fi
    exit 1
fi

set +e
printf '%s:%s\n' "${VOID_USERNAME}" "${USER_PASSWORD}" | chpasswd
rc=$?
set -e
if [ "${rc}" -ne 0 ]; then
    echo "chpasswd failed for user"
    dmesg | tail
    if [ -f /var/log/auth.log ]; then
        cat /var/log/auth.log
    fi
    exit 1
fi

getent passwd root
getent shadow root
getent passwd "${VOID_USERNAME}"
getent shadow "${VOID_USERNAME}"

grep '^root:' /etc/shadow | grep -Eq '^[^:]+:[^!*]' || { echo "root password not set"; exit 1; }
grep "^${VOID_USERNAME}:" /etc/shadow | grep -Eq '^[^:]+:[^!*]' || { echo "user password not set"; exit 1; }

root_status="$(passwd -S root)"
user_status="$(passwd -S "${VOID_USERNAME}")"
echo "${root_status}"
echo "${user_status}"
passwd -S root | grep -q ' P ' || { echo "root not active"; exit 1; }
passwd -S "${VOID_USERNAME}" | grep -q ' P ' || { echo "user not active"; exit 1; }

echo "Minimal system setup complete."
