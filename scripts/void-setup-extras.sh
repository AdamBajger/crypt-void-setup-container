#!/bin/bash
# void-setup-extras.sh — Additional packages and customisation for the
# installed VoidLinux system.
#
# This script runs INSIDE the xchroot environment, called from
# void-installation-script.sh AFTER void-setup-minimal.sh has completed.
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
# Extra packages — add your own below.
# ---------------------------------------------------------------------------
# Example: install a text editor and network tools.
#
# xbps-install -y \
#     vim \
#     curl \
#     wget

log "No extra packages configured — skipping."

# ---------------------------------------------------------------------------
# Additional runit services — uncomment or add your own below.
# ---------------------------------------------------------------------------
# Example: enable ntpd for time synchronisation.
#
# ln -sf /etc/sv/ntpd /etc/runit/runsvdir/default/

# ---------------------------------------------------------------------------
# User dotfiles / configuration — add your own below.
# ---------------------------------------------------------------------------
# Example: set a custom shell for the regular user.
#
# chsh -s /bin/bash "${VOID_USERNAME}"

log "Extra customisation complete."
