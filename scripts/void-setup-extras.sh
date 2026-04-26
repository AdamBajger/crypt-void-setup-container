#!/bin/bash
# void-setup-extras.sh - Additional packages and customisation for the
# installed VoidLinux system.
#
# Runs INSIDE the xchroot environment, called from entrypoint.sh AFTER
# void-setup-minimal.sh has completed. We are root inside the chroot, so
# no sudo is used.
#
# Receives the same environment variables as void-setup-minimal.sh
# (VOID_HOSTNAME, VOID_USERNAME, ROOT_PASSWORD, USER_PASSWORD, …).

set -euo pipefail

log() { echo "[void-setup-extras] $*"; }

# ---------------------------------------------------------------------------
# Install xbps packages from /tmp/extra-packages.txt
# ---------------------------------------------------------------------------
EXTRA_PACKAGES_FILE="/tmp/extra-packages.txt"
log "Reading extra packages from ${EXTRA_PACKAGES_FILE}..."
# Strip whole-line comments and blank lines; keep package tokens on a single line.
EXTRA_PACKAGES=$(grep -vE '^\s*(#|$)' "${EXTRA_PACKAGES_FILE}" | tr '\n' ' ')

if [[ -n "${EXTRA_PACKAGES// }" ]]; then
  log "Installing xbps packages: ${EXTRA_PACKAGES}"
  # shellcheck disable=SC2086
  xbps-install -y -S ${EXTRA_PACKAGES}
else
  log "No extra packages listed; skipping xbps install."
fi

# ---------------------------------------------------------------------------
# Install Firefox Developer Edition from local artifact
# ---------------------------------------------------------------------------
FF_DIR="/binaries/firefox-developer"
FF_VER="$(cat "${FF_DIR}/VERSION")"
FF_TARBALL="${FF_DIR}/firefox-${FF_VER}.tar.xz"

log "Installing Firefox Developer Edition ${FF_VER} from ${FF_TARBALL}..."
rm -rf /opt/firefox-devedition /opt/firefox
mkdir -p /opt
tar -xJf "${FF_TARBALL}" -C /opt
# Tarball top-level dir is "firefox/"; rename so we never collide with the stable build.
mv /opt/firefox /opt/firefox-devedition

mkdir -p /usr/local/bin
ln -sf /opt/firefox-devedition/firefox /usr/local/bin/firefox-developer

mkdir -p /usr/share/applications
cat > /usr/share/applications/firefox-developer.desktop << 'EOF'
[Desktop Entry]
Name=Firefox Developer Edition
Comment=Web Browser
GenericName=Web Browser
Exec=/opt/firefox-devedition/firefox %u
Icon=/opt/firefox-devedition/browser/chrome/icons/default/default128.png
Terminal=false
Type=Application
Categories=Network;WebBrowser;
StartupNotify=true
EOF

# ---------------------------------------------------------------------------
# Install Visual Studio Code from local artifact
# ---------------------------------------------------------------------------
VSC_DIR="/binaries/vscode"
VSC_VER="$(cat "${VSC_DIR}/VERSION")"
VSC_TARBALL="${VSC_DIR}/code-stable-x64-${VSC_VER}.tar.gz"

log "Installing Visual Studio Code ${VSC_VER} from ${VSC_TARBALL}..."
rm -rf /opt/vscode /opt/VSCode-linux-x64
mkdir -p /opt
# The tarball's top-level dir is "VSCode-linux-x64"; relocate to /opt/vscode for a stable path.
tar -xzf "${VSC_TARBALL}" -C /opt
mv /opt/VSCode-linux-x64 /opt/vscode

mkdir -p /usr/local/bin
ln -sf /opt/vscode/bin/code /usr/local/bin/code

cat > /usr/share/applications/code.desktop << 'EOF'
[Desktop Entry]
Name=Visual Studio Code
Comment=Code Editing. Redefined.
GenericName=Text Editor
Exec=/usr/local/bin/code --no-sandbox --unity-launch %F
Icon=/opt/vscode/resources/app/resources/linux/code.png
Terminal=false
Type=Application
Categories=Development;IDE;
StartupNotify=true
EOF

# ---------------------------------------------------------------------------
# User groups
# ---------------------------------------------------------------------------
log "Adding ${VOID_USERNAME} to audio, video, network, docker groups..."
usermod -a -G audio,video,network "${VOID_USERNAME}"
usermod -a -G docker "${VOID_USERNAME}"

# ---------------------------------------------------------------------------
# NetworkManager: drop conflicting services, enable dbus
# ---------------------------------------------------------------------------
# /var/service is a symlink to /etc/runit/runsvdir/default; in the chroot
# the target directory may not have been created yet. Ensure it exists and
# write through the canonical path so a dangling /var/service symlink
# doesn't trip ln.
RUNSVDIR=/etc/runit/runsvdir/default
mkdir -p "${RUNSVDIR}"

log "Removing conflicting network services (dhcpcd, wpa_supplicant)..."
rm -f "${RUNSVDIR}/dhcpcd" /var/service/dhcpcd 2>/dev/null || true
rm -f "${RUNSVDIR}/wpa_supplicant" /var/service/wpa_supplicant 2>/dev/null || true

ln -sf /etc/sv/dbus "${RUNSVDIR}/dbus"

# ---------------------------------------------------------------------------
# PipeWire + WirePlumber + ALSA glue
# ---------------------------------------------------------------------------
log "Configuring PipeWire / WirePlumber / ALSA..."
mkdir -p /etc/pipewire/pipewire.conf.d
ln -sf /usr/share/examples/wireplumber/10-wireplumber.conf /etc/pipewire/pipewire.conf.d/
ln -sf /usr/share/examples/pipewire/20-pipewire-pulse.conf /etc/pipewire/pipewire.conf.d/

mkdir -p /etc/alsa/conf.d
ln -sf /usr/share/alsa/alsa.conf.d/50-pipewire.conf /etc/alsa/conf.d
ln -sf /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf /etc/alsa/conf.d

# ---------------------------------------------------------------------------
# Docker daemon config
# ---------------------------------------------------------------------------
log "Writing Docker daemon config..."
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

# ---------------------------------------------------------------------------
# Time sync
# ---------------------------------------------------------------------------
ln -sf /etc/sv/chronyd "${RUNSVDIR}/chronyd"

# ---------------------------------------------------------------------------
# Shell + service wiring
# ---------------------------------------------------------------------------
chsh -s /bin/bash "${VOID_USERNAME}"

log "Disabling acpid to avoid conflicts with elogind..."
rm -f "${RUNSVDIR}/acpid" /var/service/acpid 2>/dev/null || true

log "Enabling system services..."
ln -sf /etc/sv/sddm           "${RUNSVDIR}/sddm"
ln -sf /etc/sv/NetworkManager "${RUNSVDIR}/NetworkManager"
ln -sf /etc/sv/tlp            "${RUNSVDIR}/tlp"
ln -sf /etc/sv/tlp-pd         "${RUNSVDIR}/tlp-pd"
ln -sf /etc/sv/bluetoothd     "${RUNSVDIR}/bluetoothd"
ln -sf /etc/sv/docker         "${RUNSVDIR}/docker"

# ---------------------------------------------------------------------------
# First-boot service: completes Flatpak install on real hardware where
# DBus + a session are actually available (cannot be done inside the build
# container due to sandboxing).
# ---------------------------------------------------------------------------
log "Installing void-firstboot runit service..."
install -m 0755 /tmp/firstboot.sh           /usr/local/sbin/void-firstboot.sh

mkdir -p /etc/sv/void-firstboot
install -m 0755 /tmp/firstboot-runit-run    /etc/sv/void-firstboot/run

# Stash a copy of extra-packages.txt where firstboot.sh expects it on the live system.
mkdir -p /etc/void-firstboot
install -m 0644 "${EXTRA_PACKAGES_FILE}"    /etc/void-firstboot/extra-packages.txt

mkdir -p /etc/runit/runsvdir/default
ln -sf /etc/sv/void-firstboot /etc/runit/runsvdir/default/void-firstboot

log "Extra customisation complete."
log "KDE6 Plasma desktop configured with PipeWire audio and essential tools."
log "Flatpak apps will install on first boot via void-firstboot runit service."
