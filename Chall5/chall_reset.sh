#!/usr/bin/env bash
###############################################################################
# chall_reset.sh — Stage 5 Reset Script
#
# Stops and removes both substation-gw and bay-controller containers,
# clearing all flag state, and redeploys using setup.sh.
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

info "=== Stage 5 Reset — Substation Gateway & Bay Controller ==="

# Stop and remove containers
for name in substation-gw bay-controller; do
    if podman ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
        info "Stopping ${name} container..."
        podman stop "${name}" 2>/dev/null || true
        podman rm "${name}" 2>/dev/null || true
        info "${name} removed."
    else
        info "${name} container not found — nothing to stop."
    fi
done

# Verify range.env still exists
if [[ ! -f "${RANGE_ENV}" ]]; then
    die "No range.env found at ${RANGE_ENV}. Please run Stage 1 setup first."
fi

# Clean up host link if present (legacy macvlan support)
if ip link show dummy0 &>/dev/null 2>&1; then
    info "Removing dummy0 interface..."
    sudo ip link delete dummy0 2>/dev/null || true
fi

if podman network exists process_zone_net; then
    info "Removing Podman process_zone_net network..."
    podman network rm process_zone_net || echo arch | sudo -S podman network rm process_zone_net
fi


info "Redeploying Stage 5 from existing range.env..."
exec "${SCRIPT_DIR}/setup.sh"
