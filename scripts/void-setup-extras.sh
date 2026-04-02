#!/bin/bash
# void-setup-extras.sh - Additional packages and customisation for the
# installed VoidLinux system.
#
# This script runs INSIDE the xchroot environment, called from
# entrypoint.sh AFTER void-setup-minimal.sh has completed.
# None of the steps here are critical for the system to boot; they add
# convenience, tooling, or personalisation on top of the minimal base.
#
# Customise this file freely.  It is the intended place for:
#   • Extra packages  (editors, shells, desktop environments, etc.)
#   • Additional runit service links
#   • Configuration file tweaks
#   • Dotfiles or other user-specific setup
#
# Receives the same environment variables as void-setup-minimal.sh
# (VOID_HOSTNAME, VOID_USERNAME, ROOT_PASSWORD, USER_PASSWORD, …).

set -euo pipefail

log() { echo "[void-setup-extras] $*"; }

# ---------------------------------------------------------------------------
# Install packages - organized by theme
# ---------------------------------------------------------------------------

log "Installing system fundamentals..."
xbps-install -y bash dbus elogind

log "Installing KDE6 Plasma desktop environment..."
xbps-install -y kde-plasma kde-baseapps sddm sddm-kcm dolphin xorg

log "Installing GPU drivers (pick the right block)..."
# Intel/AMD (Mesa, robust default across laptops)
xbps-install -y mesa-dri mesa-vulkan-intel mesa-vulkan-radeon
# Intel legacy (older Intel iGPU; usually not needed with modesetting)
# xbps-install -y xf86-video-intel
# AMD (modern Radeon iGPU/dGPU; usually not needed with modesetting)
# xbps-install -y xf86-video-amdgpu
# NVIDIA proprietary (preferred for recent NVIDIA dGPU; needs extra setup)
# xbps-install -y nvidia nvidia-libs
# NVIDIA open driver (nouveau) uses Mesa; no extra packages beyond Mesa

log "Installing desktop integration tools..."
xbps-install -y xdg-desktop-portal-kde flatpak kdeconnect

log "Installing networking tools..."
# Note: python3-dbus is required for Eduroam support with the eduroam_cat installer
xbps-install -y NetworkManager plasma-nm python3-dbus

log "Installing multimedia & graphics tools..."
xbps-install -y kdegraphics-thumbnailers ffmpegthumbs spectacle

log "Installing audio subsystem (PipeWire)..."
xbps-install -y pipewire wireplumber pulseaudio-utils alsa-pipewire libspa-bluetooth

log "Installing Bluetooth support..."
xbps-install -y blueman

log "Installing security & cryptography tools..."
xbps-install -y gnupg gnome-keyring kleopatra

log "Installing power management..."
xbps-install -y tlp tlp-pd tlp-rdw

log "Installing browser and web tools..."
xbps-install -y brave wget curl ping

log "Download Firefox Developer Edition from web and install it as a local package..."
# Note: Firefox Developer Edition is not available in VoidLinux repositories, so we download and install it manually.
FIREFOX_DEVELOPER_URL="https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64&lang=cs"
# TODO: Verify the downloaded file's integrity using gpg signatures or checksums from Mozilla's official sources.
# TODO: install

log "Installing archive tools..."
xbps-install -y ark

log "Installing text editors..."
xbps-install -y vim kate

log "Installing development tools..."
xbps-install -y gcc python3-setuptools uv

log "Installing input device managers..."
xbps-install -y Solaar

log "Installing system administration tools..."
xbps-install -y htop lsof lvm2 mdadm cryptsetup libparted libparted-devel gvfs

log "Installing container, virtualization, and Kubernetes tools..."
xbps-install -y docker docker-buildx docker-compose qemu kubectl helm

log "Installing networking & VPN tools..."
xbps-install -y eduvpn-client nm-tray

log "Installing firewall management..."
xbps-install -y nftables plasma-firewall

log "Installing bootloader (UEFI)..."
xbps-install -y grub-x86_64-efi

log "Installing time synchronization..."
xbps-install -y chrony

log "Installing media & office applications..."
xbps-install -y libreoffice vlc thunderbird

log "Installing system utilities..."
xbps-install -y pigz postgresql-client rtkit void-docs-browse xmirror xtools




# ---------------------------------------------------------------------------
# Configure user groups for audio, video, and network
# ---------------------------------------------------------------------------
log "Adding ${VOID_USERNAME} to audio, video, and network groups..."
usermod -a -G audio,video,network "${VOID_USERNAME}"

# ---------------------------------------------------------------------------
# Configure NetworkManager
# ---------------------------------------------------------------------------
log "Configuring NetworkManager..."
# Disable conflicting network services to prevent interference
log "Removing conflicting network services (dhcpcd, wpa_supplicant)..."
rm -f /var/service/dhcpcd 2>/dev/null || true
rm -f /var/service/wpa_supplicant 2>/dev/null || true

# Enable d-bus (required by NetworkManager and KDE6)
sudo ln -s /etc/sv/dbus /var/service/

# ---------------------------------------------------------------------------
# Configure PipeWire with WirePlumber session manager (system-wide)
# ---------------------------------------------------------------------------
log "Configuring PipeWire with WirePlumber session manager..."
mkdir -p /etc/pipewire/pipewire.conf.d
ln -sf /usr/share/examples/wireplumber/10-wireplumber.conf /etc/pipewire/pipewire.conf.d/

# ---------------------------------------------------------------------------
# Configure PipeWire PulseAudio interface (system-wide)
# ---------------------------------------------------------------------------
log "Configuring PipeWire PulseAudio interface (for app compatibility)..."
mkdir -p /etc/pipewire/pipewire.conf.d
ln -sf /usr/share/examples/pipewire/20-pipewire-pulse.conf /etc/pipewire/pipewire.conf.d/

# ---------------------------------------------------------------------------
# Configure ALSA integration with PipeWire
# ---------------------------------------------------------------------------
log "Configuring ALSA integration..."
mkdir -p /etc/alsa/conf.d
ln -sf /usr/share/alsa/alsa.conf.d/50-pipewire.conf /etc/alsa/conf.d
ln -sf /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf /etc/alsa/conf.d

# ---------------------------------------------------------------------------
# Configure Docker daemon
# ---------------------------------------------------------------------------
log "Configuring Docker..."
sudo usermod -a -G docker "${VOID_USERNAME}"
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
# Configure time synchronization with Chrony
# ---------------------------------------------------------------------------
log "Configuring Chrony NTP..."
sudo ln -s /etc/sv/chronyd /var/service/

# ---------------------------------------------------------------------------
# Configure shell and services
# ---------------------------------------------------------------------------
chsh -s /bin/bash "${VOID_USERNAME}"

log "Disabling acpid to avoid conflicts with elogind..."
rm -f /var/service/acpid

log "Enabling system services..."
sudo ln -s /etc/sv/sddm /var/service/
sudo ln -s /etc/sv/NetworkManager /var/service/
sudo ln -s /etc/sv/tlp /var/service/
sudo ln -s /etc/sv/tlp-pd /var/service/
sudo ln -s /etc/sv/bluetoothd /var/service/
sudo ln -s /etc/sv/docker /var/service/

log "Extra customisation complete."
log "KDE6 Plasma desktop configured with PipeWire audio and essential tools."
