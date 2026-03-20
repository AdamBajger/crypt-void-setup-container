#!/usr/bin/env bash
# run-docker-privileged.sh — Run the Void Linux FDE build inside a privileged
# Docker container.
#
# This is the same execution path used by docker-compose.yml, but callable as
# a standalone script so that run-build.sh and CI pipelines can invoke it
# without requiring Docker Compose.
#
# Required environment variables:
#   LUKS_PASSWORD   — LUKS1 passphrase
#   ROOT_PASSWORD   — root account password
#   USER_PASSWORD   — regular user account password
#
# Optional environment variables:
#   VOID_XBPS_REPOSITORY — XBPS mirror (default: https://repo-default.voidlinux.org/current)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

log()  { echo "[docker-wrapper] $*"; }
die()  { echo "[docker-wrapper] ERROR: $*" >&2; exit 1; }

VOID_XBPS_REPOSITORY="${VOID_XBPS_REPOSITORY:-https://repo-default.voidlinux.org/current}"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH."
docker info >/dev/null 2>&1       || die "Docker daemon is not running or current user cannot reach it."

[[ -n "${LUKS_PASSWORD:-}" ]] || die "LUKS_PASSWORD is not set."
[[ -n "${ROOT_PASSWORD:-}" ]] || die "ROOT_PASSWORD is not set."
[[ -n "${USER_PASSWORD:-}" ]] || die "USER_PASSWORD is not set."

# ---------------------------------------------------------------------------
# Build the Docker image if it does not exist or the Dockerfile has changed.
# ---------------------------------------------------------------------------
IMAGE_TAG="void-fde-builder:local"

log "Building Docker image ${IMAGE_TAG}..."
docker build \
    --build-arg "VOID_XBPS_REPOSITORY=${VOID_XBPS_REPOSITORY}" \
    -t "${IMAGE_TAG}" \
    "${REPO_ROOT}"

# ---------------------------------------------------------------------------
# Ensure the output directory exists on the host.
# ---------------------------------------------------------------------------
mkdir -p "${REPO_ROOT}/output"

# ---------------------------------------------------------------------------
# Run the container with privileged access and the required bind-mounts.
# ---------------------------------------------------------------------------
log "Starting privileged build container..."
docker run --rm \
    --privileged \
    --device /dev/loop-control \
    -v "${REPO_ROOT}/config:/config:ro" \
    -v "${REPO_ROOT}/output:/output" \
    -v "${REPO_ROOT}/scripts:/setup" \
    -e LUKS_PASSWORD \
    -e ROOT_PASSWORD \
    -e USER_PASSWORD \
    -e VOID_XBPS_REPOSITORY \
    "${IMAGE_TAG}"

log "Build complete. Check ${REPO_ROOT}/output/ for the disk image."
