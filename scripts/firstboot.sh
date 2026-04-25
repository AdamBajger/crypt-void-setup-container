#!/bin/bash
# void-firstboot.sh - Runs once on first boot to complete the parts of the
# installation that require a real DBus + session (Flatpak app install).
#
# Self-disabling: drops a sentinel file and removes its own runsvdir symlink.

set -euo pipefail

SENTINEL="/var/lib/void-firstboot.done"
LOG="/var/log/void-firstboot.log"

if [[ -e "${SENTINEL}" ]]; then
  exit 0
fi

mkdir -p "$(dirname "${LOG}")"
exec >>"${LOG}"
exec 2>&1

echo "=== void-firstboot starting at $(date -Is) ==="

EXTRA_PACKAGES_FILE="/etc/void-firstboot/extra-packages.txt"
DEFAULT_FLATPAKS=(
  org.signal.Signal
  com.bitwarden.desktop
  com.discordapp.Discord
)

# Parse a "# flatpak:" block from extra-packages.txt if available.
# Format expected: a line "# flatpak:" followed by lines of the form
# "#   org.example.App". Block ends at the first non-comment or different
# comment header.
parse_flatpak_block() {
  local file="$1"
  awk '
    /^[[:space:]]*#[[:space:]]*flatpak:/ { in_block = 1; next }
    in_block {
      if ($0 !~ /^[[:space:]]*#/) { in_block = 0; next }
      line = $0
      sub(/^[[:space:]]*#[[:space:]]*/, "", line)
      if (line ~ /^[a-zA-Z0-9._-]+$/) print line
    }
  ' "${file}"
}

FLATPAK_APPS=()
if [[ -r "${EXTRA_PACKAGES_FILE}" ]]; then
  mapfile -t FLATPAK_APPS < <(parse_flatpak_block "${EXTRA_PACKAGES_FILE}")
fi
if [[ "${#FLATPAK_APPS[@]}" -eq 0 ]]; then
  echo "No '# flatpak:' block found; using default KDE-friendly set."
  FLATPAK_APPS=("${DEFAULT_FLATPAKS[@]}")
fi
echo "Flatpak apps to install: ${FLATPAK_APPS[*]}"

echo "Adding Flathub remote..."
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

echo "Installing Flatpak apps..."
flatpak install -y --noninteractive flathub "${FLATPAK_APPS[@]}"

echo "Removing void-firstboot runsvdir symlink..."
rm -f /etc/runit/runsvdir/default/void-firstboot

touch "${SENTINEL}"
echo "=== void-firstboot done at $(date -Is) ==="
