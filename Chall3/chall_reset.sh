#!/usr/bin/env bash
###############################################################################
# chall_reset.sh — Stage 3 Reset
#
# Stop/remove only the historian-srv container and redeploy from existing
# range.env.  Does NOT touch other stage containers or rotate the seed.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="$(cd "${SCRIPT_DIR}/../shared" && pwd)"
RANGE_ENV="${SHARED_DIR}/range.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[-]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

info "=== Stage 3 Reset — OPC UA Historian ==="

# Stop and remove historian-srv container only
if sudo -E podman ps -a --format '{{.Names}}' | grep -q '^historian-srv$'; then
    info "Stopping historian-srv container..."
    sudo -E podman stop historian-srv 2>/dev/null || true
    sudo -E podman rm historian-srv 2>/dev/null || true
    info "historian-srv removed"
else
    info "historian-srv container not found — nothing to stop"
fi

# Verify range.env still exists
if [[ ! -f "${RANGE_ENV}" ]]; then
    die "No range.env found at ${RANGE_ENV}. Run Chall1/setup.sh first."
fi

info "Redeploying historian-srv from existing range.env (seed preserved)"
exec "${SCRIPT_DIR}/setup.sh"
