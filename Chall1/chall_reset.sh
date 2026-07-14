#!/usr/bin/env bash
###############################################################################
# chall_reset.sh — Stage 1 Reset
#
# Stop/remove the vpn-gateway container and redeploy from existing range.env.
# Does NOT rotate the seed by default.
#
# Options:
#   --rotate-seed    Delete range.env and regenerate everything. Requires
#                    RANGE_BASE_CIDR and re-running all 5 challenges' setup.sh.
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

ROTATE_SEED=false
RANGE_CIDR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rotate-seed)
            ROTATE_SEED=true
            shift
            ;;
        *)
            RANGE_CIDR="$1"
            shift
            ;;
    esac
done

info "=== Stage 1 Reset ==="

# Stop and remove vpn-gateway container
if sudo -E podman ps -a --format '{{.Names}}' | grep -q '^vpn-gateway$'; then
    info "Stopping vpn-gateway container..."
    sudo -E podman stop vpn-gateway 2>/dev/null || true
    sudo -E podman rm vpn-gateway 2>/dev/null || true
    info "vpn-gateway removed"
else
    info "vpn-gateway container not found — nothing to stop"
fi

if [[ "$ROTATE_SEED" == "true" ]]; then
    warn "Seed rotation requested — deleting range.env and all env files"
    warn "You MUST re-run ALL 5 challenges' setup.sh after this!"
    rm -f "${RANGE_ENV}"
    rm -f "${SHARED_DIR}"/env/*.env 2>/dev/null || true
    # Remove old Podman secret
    sudo -E podman secret rm ctf_seed 2>/dev/null || true
    # Remove public zone network
    sudo -E podman network rm public_zone_net 2>/dev/null || true
    info "Range state cleared"

    if [[ -z "$RANGE_CIDR" ]]; then
        die "Seed rotation requires a RANGE_BASE_CIDR argument.\nUsage: $0 --rotate-seed <RANGE_BASE_CIDR>"
    fi
    info "Re-provisioning with CIDR: ${RANGE_CIDR}"
    exec "${SCRIPT_DIR}/setup.sh" "${RANGE_CIDR}"
else
    if [[ ! -f "${RANGE_ENV}" ]]; then
        die "No range.env found. Run setup.sh with a RANGE_BASE_CIDR first."
    fi
    info "Redeploying from existing range.env (seed preserved)"
    exec "${SCRIPT_DIR}/setup.sh"
fi
