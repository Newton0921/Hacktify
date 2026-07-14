#!/usr/bin/env bash
###############################################################################
# chall_reset.sh — Stage 2 Reset
#
# Stop/remove only the ews-node container and redeploy from setup.sh
# using the existing range.env.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="$(cd "${SCRIPT_DIR}/../../shared" && pwd)"
RANGE_ENV="${SHARED_DIR}/range.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[-]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

info "=== Stage 2 Reset ==="

# Stop and remove ews-node container
if sudo -E podman ps -a --format '{{.Names}}' | grep -q '^ews-node$'; then
    info "Stopping ews-node container..."
    sudo -E podman stop ews-node 2>/dev/null || true
    sudo -E podman rm ews-node 2>/dev/null || true
    info "ews-node removed"
else
    info "ews-node container not found — nothing to stop"
fi

if [[ ! -f "${RANGE_ENV}" ]]; then
    die "No range.env found. Run setup.sh first."
fi

info "Redeploying from existing range.env (seed preserved)"
exec "${SCRIPT_DIR}/setup.sh"
