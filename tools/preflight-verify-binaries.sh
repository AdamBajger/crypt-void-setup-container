#!/bin/bash
# preflight-verify-binaries.sh — Verify locally downloaded artifacts before build.
#
# Reads versions/hashes from binaries/manifest.json (produced by tools/fetch-binaries.sh).
# Strict failure on any missing file, signature mismatch, or checksum mismatch.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${REPO_ROOT}/binaries"
MANIFEST="${BIN_DIR}/manifest.json"

# Allow callers to point at a different binaries dir (e.g. /binaries inside the container).
if [[ -n "${BINARIES_DIR:-}" ]]; then
    BIN_DIR="${BINARIES_DIR}"
    MANIFEST="${BIN_DIR}/manifest.json"
fi

FF_DIR="${BIN_DIR}/firefox-developer"
VSC_DIR="${BIN_DIR}/vscode"
ISO_DIR="${BIN_DIR}/void-iso"

VERIFY_DIR="$(mktemp -d -t void-preflight-XXXXXX)"
GNUPGHOME="${VERIFY_DIR}/gnupg"
mkdir -p "${GNUPGHOME}"
chmod 700 "${GNUPGHOME}"
trap 'rm -rf "${VERIFY_DIR}"' EXIT

log() { echo "[preflight] $*"; }
die() { echo "[preflight] ERROR: $*" >&2; exit 1; }

command -v jq        >/dev/null 2>&1 || die "jq is required"
command -v gpg       >/dev/null 2>&1 || die "gpg is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"
command -v sha512sum >/dev/null 2>&1 || die "sha512sum is required"

[[ -f "${MANIFEST}" ]] || die "missing ${MANIFEST} — run tools/fetch-binaries.sh first"

# ---------------------------------------------------------------------------
# Firefox Developer Edition
# ---------------------------------------------------------------------------
log "Verifying Firefox Developer Edition signature and checksum..."
FF_FILE=$(jq -r '.firefox_developer.file'               "${MANIFEST}")
FF_SHA=$(jq  -r '.firefox_developer.sha512'             "${MANIFEST}")
FF_SHAPATH=$(jq -r '.firefox_developer.sha512sums_path' "${MANIFEST}")

[[ -f "${FF_DIR}/KEY" ]]            || die "missing ${FF_DIR}/KEY"
[[ -f "${FF_DIR}/SHA512SUMS" ]]     || die "missing ${FF_DIR}/SHA512SUMS"
[[ -f "${FF_DIR}/SHA512SUMS.asc" ]] || die "missing ${FF_DIR}/SHA512SUMS.asc"
[[ -f "${FF_DIR}/${FF_FILE}" ]]     || die "missing ${FF_DIR}/${FF_FILE}"

gpg --homedir "${GNUPGHOME}" --batch --import "${FF_DIR}/KEY" 2>/dev/null
gpg --homedir "${GNUPGHOME}" --batch --verify \
    "${FF_DIR}/SHA512SUMS.asc" "${FF_DIR}/SHA512SUMS"

# Cross-check: manifest hash must match the line in the GPG-verified SHA512SUMS.
SIGNED_SHA=$(awk -v p="${FF_SHAPATH}" '$2==p {print $1; exit}' "${FF_DIR}/SHA512SUMS")
[[ -n "${SIGNED_SHA}" ]] || die "no SHA512SUMS line for ${FF_SHAPATH}"
[[ "${SIGNED_SHA}" == "${FF_SHA}" ]] || die "manifest SHA differs from signed SHA512SUMS"

# Verify the actual tarball matches the signed hash.
( cd "${FF_DIR}" && echo "${SIGNED_SHA}  ${FF_FILE}" | sha512sum -c --quiet --strict - )

# TODO: Mozilla does not currently publish per-tarball detached .asc signatures
# for Developer Edition; verification chain is KEY → SHA512SUMS.asc → tarball.
# If they begin publishing per-tarball sigs, add: gpg --verify <ff>.asc <ff>.

# ---------------------------------------------------------------------------
# VS Code
# ---------------------------------------------------------------------------
log "Verifying VS Code checksum..."
VSC_FILE=$(jq -r '.vscode.file'   "${MANIFEST}")
VSC_SHA=$(jq  -r '.vscode.sha256' "${MANIFEST}")

[[ -f "${VSC_DIR}/${VSC_FILE}" ]] || die "missing ${VSC_DIR}/${VSC_FILE}"
[[ -f "${VSC_DIR}/SHA256" ]]      || die "missing ${VSC_DIR}/SHA256"

# Strict cross-check between manifest and sidecar SHA256 file.
SIDECAR_SHA=$(awk '{print $1; exit}' "${VSC_DIR}/SHA256")
[[ "${SIDECAR_SHA}" == "${VSC_SHA}" ]] || die "VS Code manifest hash differs from SHA256 sidecar"
( cd "${VSC_DIR}" && sha256sum -c --quiet --strict SHA256 )

# ---------------------------------------------------------------------------
# Void Linux live ISO
# ---------------------------------------------------------------------------
log "Verifying Void Linux live ISO checksum..."
ISO_FILE=$(jq -r '.void_iso.file'   "${MANIFEST}")
ISO_SHA=$(jq  -r '.void_iso.sha256' "${MANIFEST}")

# Void signs sha256sum.txt with minisign using a per-release ephemeral key
# whose .pub is not published in any canonical location, so signature
# verification cannot be bootstrapped without an OOB-trusted key.
# We rely on HTTPS + SHA256 cross-check between manifest and sha256sum.txt.
[[ -f "${ISO_DIR}/sha256sum.txt" ]]  || die "missing ${ISO_DIR}/sha256sum.txt"
[[ -f "${ISO_DIR}/${ISO_FILE}" ]]    || die "missing ${ISO_DIR}/${ISO_FILE}"

# Void uses BSD style ("SHA256 (file) = hash"); accept GNU style as fallback.
LISTED_ISO_SHA=$(awk -v n="${ISO_FILE}" '
    $1=="SHA256" && $2=="("n")"          {print $4; exit}
    $2==n || $2=="*"n || $2=="("n")"     {print $1; exit}
' "${ISO_DIR}/sha256sum.txt")
[[ -n "${LISTED_ISO_SHA}" ]] || die "no sha256sum.txt entry for ${ISO_FILE}"
[[ "${LISTED_ISO_SHA}" == "${ISO_SHA}" ]] || die "manifest ISO SHA differs from sha256sum.txt"

( cd "${ISO_DIR}" && echo "${LISTED_ISO_SHA}  ${ISO_FILE}" | sha256sum -c --quiet --strict - )

log "Verification complete."
