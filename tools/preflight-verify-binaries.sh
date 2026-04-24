#!/bin/bash
# preflight-verify-binaries.sh - Verify locally downloaded artifacts before build.

set -euo pipefail

BINARIES_DIR="/binaries"

FIREFOX_DIR="${BINARIES_DIR}/firefox-developer"
FIREFOX_TARBALL="${FIREFOX_DIR}/firefox-150.0b5.tar.xz"
FIREFOX_SHA_PATH="linux-x86_64/cs/firefox-150.0b5.tar.xz"
FIREFOX_TARBALL_ASC="${FIREFOX_DIR}/firefox-150.0b5.tar.xz.asc"

VSCODE_TARBALL="${BINARIES_DIR}/vscode/code-stable-x64-1775036184.tar.gz"
VSCODE_SHA256="0fed895a30b492eb5f90417940a38ac21f59f3e8d680c80c3766fca4ac186b2b"

VERIFY_DIR="/tmp/void-binaries-verify"
GNUPGHOME="${VERIFY_DIR}/gnupg"
SHA_FILE="${VERIFY_DIR}/SHA512SUMS"

mkdir -p "${VERIFY_DIR}" "${GNUPGHOME}"

log() { echo "[preflight] $*"; }

log "Verifying Firefox Developer Edition signature and checksum..."
[ -f "${FIREFOX_DIR}/KEY" ] || { echo "Missing ${FIREFOX_DIR}/KEY"; exit 1; }
[ -f "${FIREFOX_DIR}/SHA512SUMS" ] || { echo "Missing ${FIREFOX_DIR}/SHA512SUMS"; exit 1; }
[ -f "${FIREFOX_DIR}/SHA512SUMS.asc" ] || { echo "Missing ${FIREFOX_DIR}/SHA512SUMS.asc"; exit 1; }
[ -f "${FIREFOX_TARBALL}" ] || { echo "Missing ${FIREFOX_TARBALL}"; exit 1; }

gpg --homedir "${GNUPGHOME}" --import "${FIREFOX_DIR}/KEY"
gpg --homedir "${GNUPGHOME}" --verify "${FIREFOX_DIR}/SHA512SUMS.asc" "${FIREFOX_DIR}/SHA512SUMS"
 
if [ -f "${FIREFOX_TARBALL_ASC}" ]; then
	gpg --homedir "${GNUPGHOME}" --verify "${FIREFOX_TARBALL_ASC}" "${FIREFOX_TARBALL}"
fi

awk -v f="${FIREFOX_SHA_PATH}" -v t="${FIREFOX_TARBALL}" '$2==f {print $1"  "t}' "${FIREFOX_DIR}/SHA512SUMS" > "${SHA_FILE}"
sha512sum -c "${SHA_FILE}" --quiet --strict

log "Verifying VS Code checksum..."
[ -f "${VSCODE_TARBALL}" ] || { echo "Missing ${VSCODE_TARBALL}"; exit 1; }

echo "${VSCODE_SHA256}  ${VSCODE_TARBALL}" | sha256sum -c -

log "Verification complete."
