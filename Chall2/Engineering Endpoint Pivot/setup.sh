#!/usr/bin/env bash
###############################################################################
# Chall2 / Stage 2 — Engineering Workstation Setup
# Prabal Urja Pvt Ltd — OT/ICS Red-Team Range
#
# Sources ../shared/range.env (or generates standalone defaults if missing)
# Builds and starts the ews-node container.
#
# No hardcoded IP/subnet literals.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="$(cd "${SCRIPT_DIR}/../../shared" && pwd)"
RANGE_ENV="${SHARED_DIR}/range.env"
EWS_DIR="${SCRIPT_DIR}/ews-node"

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[-]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

# ---------------------------------------------------------------------------
# CIDR math helpers
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# SOURCING OR PROVISIONING RANGE.ENV
# ---------------------------------------------------------------------------
if [[ ! -f "${RANGE_ENV}" ]]; then
    warn "range.env not found at ${RANGE_ENV}. Generating standalone defaults..."
    mkdir -p "${SHARED_DIR}/env"
    
    seed=$(openssl rand -hex 32)
    
    # Deriving 4 subnets just like Chall1
    PUBLIC_ZONE_SUBNET="10.100.0.0/24"
    OT_ZONE_SUBNET="10.100.1.0/24"
    STATION_ZONE_SUBNET="10.100.2.0/24"
    PROCESS_ZONE_SUBNET="10.100.3.0/24"
    VPN_SUBNET="10.100.4.0/24"
    
    PUBLIC_ZONE_GATEWAY_IP="10.100.0.2"
    STATION_ZONE_GATEWAY_IP="10.100.2.1"
    EWS_IP="10.100.2.2"
    ENGSTATION_ID="EWS-STANDALONE-99"
    FIELD_ACCT_HASH='$6$testsalt$oxMvwJ8OpQdGpJ/nRInHklXfchYSeKboxsGKhVOqCtkiXe7CV8iiYOJ8KlwraxsuBIwrEUIGSgEnLE8wsFbxy0'
    
    # Create the ctf_seed podman secret if missing
    podman secret rm ctf_seed 2>/dev/null || true
    echo -n "$seed" | podman secret create ctf_seed -
    
    cat > "${RANGE_ENV}" <<ENVEOF
# --- Standalone Defaults for Chall2 ---
PUBLIC_ZONE_SUBNET=${PUBLIC_ZONE_SUBNET}
OT_ZONE_SUBNET=${OT_ZONE_SUBNET}
STATION_ZONE_SUBNET=${STATION_ZONE_SUBNET}
PROCESS_ZONE_SUBNET=${PROCESS_ZONE_SUBNET}
VPN_SUBNET=${VPN_SUBNET}
PUBLIC_ZONE_GATEWAY_IP=${PUBLIC_ZONE_GATEWAY_IP}
STATION_ZONE_GATEWAY_IP=${STATION_ZONE_GATEWAY_IP}
EWS_IP=${EWS_IP}
INSTANCE_SEED=${seed}
FIELD_ACCT_HASH='${FIELD_ACCT_HASH}'
ENGSTATION_ID=${ENGSTATION_ID}
ENVEOF

    chmod 600 "${RANGE_ENV}"
    info "range.env generated with defaults"
fi

# Source range.env
info "Sourcing range.env from ${RANGE_ENV}"
# shellcheck disable=SC1090
source "${RANGE_ENV}"

# Validate required variables
[[ -n "${INSTANCE_SEED:-}" ]] || die "INSTANCE_SEED not found in range.env"
[[ -n "${PUBLIC_ZONE_SUBNET:-}" ]] || die "PUBLIC_ZONE_SUBNET not found"
[[ -n "${STATION_ZONE_SUBNET:-}" ]] || die "STATION_ZONE_SUBNET not found"
[[ -n "${EWS_IP:-}" ]] || die "EWS_IP not found"
[[ -n "${ENGSTATION_ID:-}" ]] || die "ENGSTATION_ID not found"
[[ -n "${FIELD_ACCT_HASH:-}" ]] || die "FIELD_ACCT_HASH not found"

# Check if podman secret ctf_seed exists, create it if missing
if ! podman secret inspect ctf_seed &>/dev/null; then
    info "Creating Podman secret 'ctf_seed' from range.env"
    echo -n "${INSTANCE_SEED}" | podman secret create ctf_seed -
fi

# Ensure ews-node.env exists and is up to date
mkdir -p "${SHARED_DIR}/env"
cat > "${SHARED_DIR}/env/ews-node.env" <<ENVEOF
STATION_ZONE_SUBNET=${STATION_ZONE_SUBNET}
EWS_IP=${EWS_IP}
ENGSTATION_ID=${ENGSTATION_ID}
INSTANCE_SEED=${INSTANCE_SEED}
ASDU_ADDR_DESC=${ASDU_ADDR_DESC:-196}
TARGET_IOA=${TARGET_IOA:-2947}
IOA_END=${IOA_END:-3146}
ENVEOF
chmod 600 "${SHARED_DIR}/env/ews-node.env"

# ---------------------------------------------------------------------------
# DEPLOYMENT
# ---------------------------------------------------------------------------
info "Building ews-node container image..."
podman build --network host -t ews-node:latest "${EWS_DIR}/"

# Stop/remove existing container
podman stop ews-node 2>/dev/null || true
podman rm ews-node 2>/dev/null || true

# Setup networks
pub_net_name="public_zone_net"
station_net_name="station_zone_net"

if ! podman network exists "${pub_net_name}"; then
    info "Creating bridge network: ${pub_net_name} (${PUBLIC_ZONE_SUBNET})"
    podman network create \
        --driver bridge \
        --subnet "${PUBLIC_ZONE_SUBNET}" \
        --gateway "$(nth_host "${PUBLIC_ZONE_SUBNET}" 1)" \
        "${pub_net_name}"
fi

if ! podman network exists "${station_net_name}"; then
    info "Creating bridge network: ${station_net_name} (${STATION_ZONE_SUBNET})"
    podman network create \
        --driver bridge \
        --subnet "${STATION_ZONE_SUBNET}" \
        --gateway "$(nth_host "${STATION_ZONE_SUBNET}" 1)" \
        "${station_net_name}"
fi

# EWS public zone IP (gateway .1, vpn-gw .2, ews-node .3)
EWS_PUBLIC_IP=$(nth_host "${PUBLIC_ZONE_SUBNET}" 3)

info "Starting ews-node container at public zone IP: ${EWS_PUBLIC_IP}"
podman run -d \
    --name ews-node \
    --hostname ews-node \
    --network "${pub_net_name}:ip=${EWS_PUBLIC_IP}" \
    --env-file "${SHARED_DIR}/env/ews-node.env" \
    --env FIELD_ACCT_HASH="${FIELD_ACCT_HASH}" \
    --secret ctf_seed,type=mount,target=/run/secrets/ctf_seed \
    --restart unless-stopped \
    ews-node:latest

# Connect to OT/Station zone network
info "Connecting ews-node to ${station_net_name} at OT zone IP: ${EWS_IP}"
podman network connect "${station_net_name}" ews-node --ip "${EWS_IP}"

# Connect to OT zone network if it exists or create it
ot_net_name="ot_zone_net"
if ! podman network exists "${ot_net_name}" &>/dev/null; then
    info "Creating Podman bridge network: ${ot_net_name} (${OT_ZONE_SUBNET:-10.100.1.0/24})"
    podman network create \
        --driver bridge \
        --subnet "${OT_ZONE_SUBNET:-10.100.1.0/24}" \
        --gateway "$(nth_host "${OT_ZONE_SUBNET:-10.100.1.0/24}" 1)" \
        "${ot_net_name}"
fi
info "Connecting ews-node to ${ot_net_name}"
podman network connect "${ot_net_name}" ews-node 2>/dev/null || true

# Ensure host's forwarding policy (e.g. Docker's FORWARD DROP) doesn't block traffic
if command -v iptables &>/dev/null; then
    iptables -C FORWARD -d "${STATION_ZONE_SUBNET}" -j ACCEPT &>/dev/null || iptables -I FORWARD -d "${STATION_ZONE_SUBNET}" -j ACCEPT || true
    iptables -C FORWARD -s "${STATION_ZONE_SUBNET}" -j ACCEPT &>/dev/null || iptables -I FORWARD -s "${STATION_ZONE_SUBNET}" -j ACCEPT || true
fi

info "Waiting for container initialization..."
sleep 5

# Verify flag was generated inside
flag_check=$(podman exec ews-node cat /run/ctf/stage2_flag 2>/dev/null) || true
if [[ -n "${flag_check}" ]]; then
    info "Stage 2 flag verified (stored inside container at /run/ctf/stage2_flag)"
else
    warn "Flag file not yet available — container may still be initializing"
fi

info "Stage 2 deployment complete"
echo ""
info "Connection info:"
info "  SSH:            ssh field_tech@${EWS_PUBLIC_IP}"
info "  OPC UA Server:  opc.tcp://${EWS_IP}:4840"
