#!/bin/bash
# tools/fetch-binaries.sh — Download upstream binaries + signing material.
#
# Populates ./binaries/ with everything the preflight verifier and the
# install scripts expect. Idempotent: re-runs skip files whose checksums
# already match the manifest.
#
# Outputs:
#   binaries/firefox-developer/{firefox-<ver>.tar.xz,SHA512SUMS,SHA512SUMS.asc,KEY,VERSION}
#   binaries/vscode/{code-stable-x64-<ver>.tar.gz,SHA256,VERSION}
#   binaries/void-iso/{void-live-x86_64-<date>.iso,sha256sum.txt,sha256sum.sig,KEY,VERSION}
#   binaries/manifest.json
#
# Run on: GitHub Actions ubuntu-latest, or any host with bash, curl, jq, gpg, sha256sum, sha512sum.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${REPO_ROOT}/binaries"
FF_DIR="${BIN_DIR}/firefox-developer"
VSC_DIR="${BIN_DIR}/vscode"
ISO_DIR="${BIN_DIR}/void-iso"
MANIFEST="${BIN_DIR}/manifest.json"

mkdir -p "${FF_DIR}" "${VSC_DIR}" "${ISO_DIR}"

log() { echo "[fetch] $*" >&2; }
die() { echo "[fetch] ERROR: $*" >&2; exit 1; }

CURL=(curl -fsSL --retry 5 --retry-delay 2 --connect-timeout 15)

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
need curl; need jq; need gpg; need sha256sum; need sha512sum; need awk; need sed; need grep

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
sha256_of() { sha256sum "$1" | awk '{print $1}'; }
sha512_of() { sha512sum "$1" | awk '{print $1}'; }

# Skip download if file already exists and its hash matches expected (when given).
# fetch_to <url> <dest> [<algo:expected_hash>]
fetch_to() {
    local url="$1" dest="$2" expected="${3:-}"
    if [[ -f "${dest}" && -n "${expected}" ]]; then
        local algo="${expected%%:*}" want="${expected#*:}" got=""
        case "${algo}" in
            sha256) got=$(sha256_of "${dest}") ;;
            sha512) got=$(sha512_of "${dest}") ;;
            *)      die "unsupported algo ${algo}" ;;
        esac
        if [[ "${got}" == "${want}" ]]; then
            log "  skip (cached, ${algo} match): ${dest##*/}"
            return 0
        fi
        log "  hash mismatch on cached ${dest##*/}, redownloading"
    fi
    log "  download: ${url}"
    "${CURL[@]}" "${url}" -o "${dest}.partial"
    mv "${dest}.partial" "${dest}"
}

# ---------------------------------------------------------------------------
# Firefox Developer Edition
# ---------------------------------------------------------------------------
log "Resolving Firefox Developer Edition version..."
FF_VERSIONS_JSON=$("${CURL[@]}" "https://product-details.mozilla.org/1.0/firefox_versions.json")
FF_VER=$(jq -r '.FIREFOX_DEVEDITION' <<<"${FF_VERSIONS_JSON}")
[[ -n "${FF_VER}" && "${FF_VER}" != "null" ]] || die "could not resolve Firefox DevEdition version"
log "  Firefox DevEdition version: ${FF_VER}"

FF_BASE="https://archive.mozilla.org/pub/devedition/releases/${FF_VER}"
FF_TARBALL_NAME="firefox-${FF_VER}.tar.xz"
FF_SHA_PATH="linux-x86_64/en-US/${FF_TARBALL_NAME}"

# SHA512SUMS first — we'll learn the expected tarball hash from it.
fetch_to "${FF_BASE}/SHA512SUMS"     "${FF_DIR}/SHA512SUMS"
fetch_to "${FF_BASE}/SHA512SUMS.asc" "${FF_DIR}/SHA512SUMS.asc"
fetch_to "https://archive.mozilla.org/pub/firefox/releases/KEY" "${FF_DIR}/KEY"

FF_EXPECTED_SHA512=$(awk -v p="${FF_SHA_PATH}" '$2==p {print $1; exit}' "${FF_DIR}/SHA512SUMS")
[[ -n "${FF_EXPECTED_SHA512}" ]] || die "no SHA512SUMS line for ${FF_SHA_PATH}"

fetch_to "${FF_BASE}/${FF_SHA_PATH}" "${FF_DIR}/${FF_TARBALL_NAME}" "sha512:${FF_EXPECTED_SHA512}"
echo "${FF_VER}" > "${FF_DIR}/VERSION"

# ---------------------------------------------------------------------------
# VS Code stable Linux x64
# ---------------------------------------------------------------------------
log "Resolving VS Code stable build..."
VSC_JSON=$("${CURL[@]}" "https://update.code.visualstudio.com/api/update/linux-x64/stable/latest")
VSC_URL=$(jq -r '.url'        <<<"${VSC_JSON}")
VSC_SHA256=$(jq -r '.sha256hash' <<<"${VSC_JSON}")
VSC_VER=$(jq -r '.productVersion // .name' <<<"${VSC_JSON}")
[[ -n "${VSC_URL}" && "${VSC_URL}" != "null" ]] || die "could not resolve VS Code URL"
[[ -n "${VSC_SHA256}" && "${VSC_SHA256}" != "null" ]] || die "could not resolve VS Code SHA256"
[[ -n "${VSC_VER}"    && "${VSC_VER}" != "null" ]] || VSC_VER="unknown"
log "  VS Code version: ${VSC_VER}, sha256=${VSC_SHA256}"

VSC_TARBALL_NAME="code-stable-x64-${VSC_VER}.tar.gz"
fetch_to "${VSC_URL}" "${VSC_DIR}/${VSC_TARBALL_NAME}" "sha256:${VSC_SHA256}"
echo "${VSC_SHA256}  ${VSC_TARBALL_NAME}" > "${VSC_DIR}/SHA256"
echo "${VSC_VER}" > "${VSC_DIR}/VERSION"

# ---------------------------------------------------------------------------
# Void Linux live ISO (used by the QEMU CI workflow)
# ---------------------------------------------------------------------------
log "Resolving latest Void Linux x86_64 live ISO..."
ISO_INDEX_URL="https://repo-default.voidlinux.org/live/current/"
ISO_INDEX=$("${CURL[@]}" "${ISO_INDEX_URL}")

# Pick newest void-live-x86_64-*.iso (NOT musl).
ISO_NAME=$(echo "${ISO_INDEX}" \
    | grep -oE 'void-live-x86_64-[0-9]{8}[^"<]*\.iso' \
    | grep -v musl \
    | sort -u | sort -V | tail -n1)
[[ -n "${ISO_NAME}" ]] || die "could not find a void-live-x86_64 ISO at ${ISO_INDEX_URL}"
log "  ISO: ${ISO_NAME}"

# Find the release-signing public key file (e.g. void-release-20240301.asc).
KEY_NAME=$(echo "${ISO_INDEX}" \
    | grep -oE 'void-release-[0-9]{8}\.asc' \
    | sort -u | sort -V | tail -n1)
[[ -n "${KEY_NAME}" ]] || die "could not find a void-release-*.asc key at ${ISO_INDEX_URL}"
log "  Key: ${KEY_NAME}"

fetch_to "${ISO_INDEX_URL}sha256sum.txt" "${ISO_DIR}/sha256sum.txt"
fetch_to "${ISO_INDEX_URL}sha256sum.sig" "${ISO_DIR}/sha256sum.sig"
fetch_to "${ISO_INDEX_URL}${KEY_NAME}"   "${ISO_DIR}/KEY"

ISO_EXPECTED_SHA256=$(awk -v n="${ISO_NAME}" '$2=="("n")" || $2==n {print $1; exit}' "${ISO_DIR}/sha256sum.txt" \
    || true)
# Fallback: some sha256sum.txt files use "*<file>" or just "<file>" on the second column
if [[ -z "${ISO_EXPECTED_SHA256}" ]]; then
    ISO_EXPECTED_SHA256=$(grep -E "[[:space:]][*]?${ISO_NAME}\$" "${ISO_DIR}/sha256sum.txt" \
        | awk '{print $1}' | head -n1)
fi
[[ -n "${ISO_EXPECTED_SHA256}" ]] || die "no sha256sum.txt entry for ${ISO_NAME}"

fetch_to "${ISO_INDEX_URL}${ISO_NAME}" "${ISO_DIR}/${ISO_NAME}" "sha256:${ISO_EXPECTED_SHA256}"

# Derive "version" (date stamp) from filename: void-live-x86_64-<DATE>[-extra].iso
ISO_VER=$(echo "${ISO_NAME}" | grep -oE '[0-9]{8}' | head -n1)
[[ -n "${ISO_VER}" ]] || ISO_VER="${ISO_NAME}"
echo "${ISO_VER}" > "${ISO_DIR}/VERSION"

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
log "Writing ${MANIFEST}..."
jq -n \
    --arg ff_ver  "${FF_VER}" \
    --arg ff_url  "${FF_BASE}/${FF_SHA_PATH}" \
    --arg ff_file "${FF_TARBALL_NAME}" \
    --arg ff_sha  "${FF_EXPECTED_SHA512}" \
    --arg ff_shapath "${FF_SHA_PATH}" \
    --arg vsc_ver "${VSC_VER}" \
    --arg vsc_url "${VSC_URL}" \
    --arg vsc_file "${VSC_TARBALL_NAME}" \
    --arg vsc_sha "${VSC_SHA256}" \
    --arg iso_ver "${ISO_VER}" \
    --arg iso_url "${ISO_INDEX_URL}${ISO_NAME}" \
    --arg iso_file "${ISO_NAME}" \
    --arg iso_sha "${ISO_EXPECTED_SHA256}" \
    --arg iso_key "${KEY_NAME}" \
    '{
       firefox_developer: {
         version: $ff_ver, url: $ff_url, file: $ff_file,
         sha512: $ff_sha, sha512sums_path: $ff_shapath
       },
       vscode: {
         version: $vsc_ver, url: $vsc_url, file: $vsc_file, sha256: $vsc_sha
       },
       void_iso: {
         version: $iso_ver, url: $iso_url, file: $iso_file,
         sha256: $iso_sha, key_file: $iso_key
       }
     }' > "${MANIFEST}"

log "Done."
echo "${MANIFEST}"
