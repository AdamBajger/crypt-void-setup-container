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
return 24 # Fail early, as this file will not work. some Flatpaks cannot be installed inside of a container due to sandboxing limitations. QEMU implementation is necessary. 
set -euo pipefail

log() { echo "[void-setup-extras] $*"; }

# ---------------------------------------------------------------------------
# Install packages from a commented list
# ---------------------------------------------------------------------------
EXTRA_PACKAGES_FILE="/tmp/extra-packages.txt"
mapfile -t EXTRA_PACKAGES < <(
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "${EXTRA_PACKAGES_FILE}"
)

log "Installing extra packages from ${EXTRA_PACKAGES_FILE}..."
xbps-install -y "${EXTRA_PACKAGES[@]}"

# Ensure Flatpak is initialized and Flathub is added (idempotent)
if ! flatpak remote-list | grep -q flathub; then
  log "Adding Flathub Flatpak remote..."
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
fi

log "Installing Flatpak applications..."
flatpak install -y --noninteractive flathub \
  com.brave.Browser \
  org.mozilla.Thunderbird \
  org.gimp.GIMP \
  org.signal.Signal \
  com.slack.Slack \
  org.telegram.desktop \
  com.github.tchx84.Flatseal

log "Creating Brave desktop shortcut for system-wide access..."
cat > /usr/local/share/applications/brave-browser.desktop << 'EOF'
[Desktop Entry]
Name=Brave Web Browser
Comment=Browse the Web
GenericName=Web Browser
Exec=flatpak run com.brave.Browser %u
Icon=brave-browser
Terminal=false
Type=Application
Categories=Network;WebBrowser;
StartupNotify=true
EOF

log "Install Firefox Developer Edition from local artifacts..."
# Note: Files are verified on the host before entrypoint runs.
FIREFOX_DEVELOPER_TARBALL="/binaries/firefox-developer/firefox-150.0b5.tar.xz"
rm -rf /opt/firefox-developer
mkdir -p /opt
tar -xJf "$FIREFOX_DEVELOPER_TARBALL" -C /opt
mv /opt/firefox /opt/firefox-developer
ln -sf /opt/firefox-developer/firefox /usr/local/bin/firefox-developer
mkdir -p /usr/local/share/applications
cat > /usr/local/share/applications/firefox-developer.desktop << 'EOF'
[Desktop Entry]
Name=Firefox Developer Edition
Comment=Web Browser
GenericName=Web Browser
Exec=/opt/firefox-developer/firefox %u
Icon=/opt/firefox-developer/browser/chrome/icons/default/default128.png
Terminal=false
Type=Application
Categories=Network;WebBrowser;
StartupNotify=true
EOF
log "Install Visual Studio Code from local artifacts..."
# Find the downloaded VS Code tarball
VSCODE_TARBALL=$(find /binaries/vscode/ -name "code-*.tar.*" | head -n 1)
log "Extracting ${VSCODE_TARBALL} into /opt..."
rm -rf /opt/VSCode-linux-x64
mkdir -p /opt
tar -xzf "$VSCODE_TARBALL" -C /opt
ln -sf /opt/VSCode-linux-x64/bin/code /usr/local/bin/code

log "Creating Visual Studio Code desktop shortcut for system-wide access..."
mkdir -p /usr/local/share/applications
cat > /usr/local/share/applications/code.desktop << 'EOF'
[Desktop Entry]
Name=Visual Studio Code
Comment=Code Editing. Redefined.
GenericName=Text Editor
Exec=/usr/local/bin/code --no-sandbox --unity-launch %F
Icon=/opt/VSCode-linux-x64/resources/app/resources/linux/code.png
Terminal=false
Type=Application
Categories=Development;IDE;
StartupNotify=true
EOF


log "Creating Thunderbird desktop shortcut for system-wide access..."
mkdir -p /usr/local/share/applications
cat > /usr/local/share/applications/thunderbird.desktop << 'EOF'
[Desktop Entry]
Name=Thunderbird
Comment=Email and calendar client
GenericName=Mail Client
Exec=flatpak run org.mozilla.Thunderbird %u
Icon=org.mozilla.Thunderbird
Terminal=false
Type=Application
Categories=Network;Email;
StartupNotify=true
EOF

log "Creating GIMP desktop shortcut for system-wide access..."
mkdir -p /usr/local/share/applications
cat > /usr/local/share/applications/gimp.desktop << 'EOF'
[Desktop Entry]
Name=GIMP
Comment=Image editor
GenericName=Image Editor
Exec=flatpak run org.gimp.GIMP %U
Icon=org.gimp.GIMP
Terminal=false
Type=Application
Categories=Graphics;2DGraphics;RasterGraphics;
StartupNotify=true
EOF

log "Creating Signal desktop shortcut for system-wide access..."
mkdir -p /usr/local/share/applications
cat > /usr/local/share/applications/signal.desktop << 'EOF'
[Desktop Entry]
Name=Signal
Comment=Private messaging
GenericName=Messenger
Exec=flatpak run org.signal.Signal %U
Icon=org.signal.Signal
Terminal=false
Type=Application
Categories=Network;InstantMessaging;
StartupNotify=true
EOF

log "Creating Slack desktop shortcut for system-wide access..."
mkdir -p /usr/local/share/applications
cat > /usr/local/share/applications/slack.desktop << 'EOF'
[Desktop Entry]
Name=Slack
Comment=Team communication
GenericName=Messenger
Exec=flatpak run com.slack.Slack %U
Icon=com.slack.Slack
Terminal=false
Type=Application
Categories=Network;InstantMessaging;
StartupNotify=true
EOF

log "Creating Telegram desktop shortcut for system-wide access..."
mkdir -p /usr/local/share/applications
cat > /usr/local/share/applications/telegram.desktop << 'EOF'
[Desktop Entry]
Name=Telegram Desktop
Comment=Messaging app
GenericName=Messenger
Exec=flatpak run org.telegram.desktop %U
Icon=org.telegram.desktop
Terminal=false
Type=Application
Categories=Network;InstantMessaging;
StartupNotify=true
EOF

log "Creating Flatseal desktop shortcut for system-wide access..."
mkdir -p /usr/local/share/applications
cat > /usr/local/share/applications/flatseal.desktop << 'EOF'
[Desktop Entry]
Name=Flatseal
Comment=Manage Flatpak permissions
GenericName=Flatpak Permissions
Exec=flatpak run com.github.tchx84.Flatseal
Icon=com.github.tchx84.Flatseal
Terminal=false
Type=Application
Categories=Settings;System;
StartupNotify=true
EOF


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
