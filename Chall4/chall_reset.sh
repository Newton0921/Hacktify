#!/usr/bin/env bash
###############################################################################
# chall_reset.sh — Stage 4 Reset Script
#
# Stops and removes the rtu-server container, and redeploys it using the
# existing configuration files.
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

info "=== Stage 4 Reset — RTU Simulator ==="

# Stop and remove rtu-server container only
if podman ps -a --format '{{.Names}}' | grep -q '^rtu-server$'; then
    info "Stopping rtu-server container..."
    podman stop rtu-server 2>/dev/null || true
    podman rm rtu-server 2>/dev/null || true
    info "rtu-server removed"
else
    info "rtu-server container not found — nothing to stop"
fi

# Verify range.env still exists
if [[ ! -f "${RANGE_ENV}" ]]; then
    die "No range.env found at ${RANGE_ENV}. Run Chall1/setup.sh first."
fi

info "Redeploying rtu-server from existing range.env (seed preserved)"
exec "${SCRIPT_DIR}/setup.sh"
