#!/usr/bin/env bash
###############################################################################
# Chall1 / Stage 1 — VPN Gateway Setup
# Prabal Urja Pvt Ltd — OT/ICS Red-Team Range
#
# If ../shared/range.env does not exist, this script acts as the MASTER
# provisioner: it accepts RANGE_BASE_CIDR, derives 4 zone subnets + all
# per-instance artifacts, writes ../shared/range.env, and creates the
# Podman secret.  Then it builds and starts the vpn-gateway container.
#
# Usage:
#   ./setup.sh <RANGE_BASE_CIDR>          # first-time provisioning
#   ./setup.sh                             # re-run using existing range.env
#
# No hardcoded IP/subnet literals anywhere.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="$(cd "${SCRIPT_DIR}/../shared" && pwd)"
RANGE_ENV="${SHARED_DIR}/range.env"
VPN_DIR="${SCRIPT_DIR}/vpn-gateway"

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[-]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

# ---------------------------------------------------------------------------
# CIDR math helpers  (pure bash, no jq/ipcalc dependency)
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

# Given a base CIDR (e.g. 10.100.0.0/22), subdivide into 4 equal /24-class
# subnets.  Output: 4 lines of "subnet/mask".
subdivide_cidr() {
    local cidr="$1"
    local base_ip="${cidr%/*}"
    local prefix="${cidr#*/}"
    local base_int
    base_int=$(ip_to_int "$base_ip")

    # We need at least a /22 to carve 4 subnets — each gets prefix+2
    local sub_prefix=$(( prefix + 2 ))
    if (( sub_prefix > 30 )); then
        die "RANGE_BASE_CIDR /${prefix} is too small to carve 4 subnets (need at least /28 → 4×/30, ideally /22 → 4×/24)"
    fi

    local sub_size=$(( 1 << (32 - sub_prefix) ))
    for i in 0 1 2 3; do
        local sub_base=$(( base_int + i * sub_size ))
        echo "$(int_to_ip $sub_base)/${sub_prefix}"
    done
}

# First usable host in a subnet (network + 1)
first_host() {
    local cidr="$1"
    local base_ip="${cidr%/*}"
    local mask="${cidr#*/}"
    local base_int
    base_int=$(ip_to_int "$base_ip")
    echo "$(int_to_ip $(( base_int + 1 )))"
}

# Nth usable host in a subnet
nth_host() {
    local cidr="$1" n="$2"
    local base_ip="${cidr%/*}"
    local base_int
    base_int=$(ip_to_int "$base_ip")
    echo "$(int_to_ip $(( base_int + n )))"
}

# ---------------------------------------------------------------------------
# Artifact generation helpers
# ---------------------------------------------------------------------------
hmac_sha256() {
    # hmac_sha256 <key_hex> <message>
    echo -n "$2" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" 2>/dev/null | awk '{print $NF}'
}

derive_field_hash() {
    # Derive a password hash salt from INSTANCE_SEED so it's deterministic
    local seed="$1"
    local salt_hex
    salt_hex=$(hmac_sha256 "$seed" "field_tech_salt" | head -c 16)
    # Generate a SHA-512 crypt hash using the derived salt
    local salt_b64
    salt_b64=$(echo -n "$salt_hex" | base64 | head -c 16)
    # Use openssl passwd with the derived salt
    openssl passwd -6 -salt "$salt_b64" "FieldTech2024!" 2>/dev/null
}

random_hex() {
    openssl rand -hex "$1" 2>/dev/null
}

random_int_range() {
    # random_int_range <min> <max>
    local min=$1 max=$2
    local range=$(( max - min + 1 ))
    local rand
    rand=$(od -An -tu4 -N4 /dev/urandom | tr -d ' ')
    echo $(( min + rand % range ))
}

random_namespace() {
    # Generate a plausible fictional facility namespace prefix
    local prefixes=("PBLURJ" "PRJENG" "URBPWR" "PBLSTN" "URJFLD" "PWRDST" "ENGSVC" "FLDOPS")
    local suffixes=("NTH" "STH" "EST" "WST" "CTR" "ZN1" "ZN2" "DIV")
    local pi pr si sr
    pi=$(random_int_range 0 $(( ${#prefixes[@]} - 1 )))
    si=$(random_int_range 0 $(( ${#suffixes[@]} - 1 )))
    pr="${prefixes[$pi]}"
    sr="${suffixes[$si]}"
    local num
    num=$(random_int_range 100 999)
    echo "${pr}_${sr}_${num}"
}

random_engstation_id() {
    # Generate a plausible engineering workstation identifier
    local r1 r2
    r1=$(random_hex 4)
    r2=$(random_int_range 1 254)
    echo "EWS-$(echo "$r1" | tr '[:lower:]' '[:upper:]')-$(printf '%03d' $r2)"
}

# ---------------------------------------------------------------------------
# MASTER PROVISIONING — only if range.env doesn't exist
# ---------------------------------------------------------------------------
provision_range() {
    local base_cidr="$1"
    info "Master provisioning with RANGE_BASE_CIDR=${base_cidr}"

    # 1. Derive 4 zone subnets
    local subnet_output
    subnet_output=$(subdivide_cidr "$base_cidr")
    local PUBLIC_ZONE_SUBNET OT_ZONE_SUBNET STATION_ZONE_SUBNET PROCESS_ZONE_SUBNET
    PUBLIC_ZONE_SUBNET=$(echo "$subnet_output" | sed -n '1p')
    OT_ZONE_SUBNET=$(echo "$subnet_output" | sed -n '2p')
    STATION_ZONE_SUBNET=$(echo "$subnet_output" | sed -n '3p')
    PROCESS_ZONE_SUBNET=$(echo "$subnet_output" | sed -n '4p')

    # Derive non-overlapping VPN client subnet (5th subnet of the same size)
    local base_ip="${base_cidr%/*}"
    local prefix="${base_cidr#*/}"
    local base_int sub_prefix sub_size VPN_SUBNET
    base_int=$(ip_to_int "$base_ip")
    sub_prefix=$(( prefix + 2 ))
    sub_size=$(( 1 << (32 - sub_prefix) ))
    VPN_SUBNET="$(int_to_ip $(( base_int + 4 * sub_size )))/${sub_prefix}"

    info "Zone allocation:"
    info "  PUBLIC  : ${PUBLIC_ZONE_SUBNET}"
    info "  OT      : ${OT_ZONE_SUBNET}"
    info "  STATION : ${STATION_ZONE_SUBNET}"
    info "  PROCESS : ${PROCESS_ZONE_SUBNET}"
    info "  VPN POOL: ${VPN_SUBNET}"

    # 2. Assign per-container IPs
    local PUBLIC_ZONE_GATEWAY_IP
    PUBLIC_ZONE_GATEWAY_IP=$(nth_host "$PUBLIC_ZONE_SUBNET" 2)

    local OT_ZONE_GATEWAY_IP HISTORIAN_IP RTU_IP
    OT_ZONE_GATEWAY_IP=$(nth_host "$OT_ZONE_SUBNET" 1)
    HISTORIAN_IP=$(nth_host "$OT_ZONE_SUBNET" 2)
    RTU_IP=$(nth_host "$OT_ZONE_SUBNET" 3)

    local STATION_ZONE_GATEWAY_IP EWS_IP
    STATION_ZONE_GATEWAY_IP=$(nth_host "$STATION_ZONE_SUBNET" 1)
    EWS_IP=$(nth_host "$STATION_ZONE_SUBNET" 2)

    local PROCESS_ZONE_GATEWAY_IP BAY_CONTROLLER_IP
    PROCESS_ZONE_GATEWAY_IP=$(nth_host "$PROCESS_ZONE_SUBNET" 1)
    BAY_CONTROLLER_IP=$(nth_host "$PROCESS_ZONE_SUBNET" 2)

    # 3. Generate INSTANCE_SEED
    local INSTANCE_SEED
    INSTANCE_SEED=$(openssl rand -hex 32)
    info "INSTANCE_SEED generated (length=${#INSTANCE_SEED})"

    # 4. Create/replace Podman secret
    sudo -E podman secret rm ctf_seed 2>/dev/null || true
    echo -n "$INSTANCE_SEED" | sudo -E podman secret create ctf_seed -
    info "Podman secret 'ctf_seed' created"

    # 5. Generate all per-instance artifact values
    local FIELD_ACCT_HASH
    FIELD_ACCT_HASH=$(derive_field_hash "$INSTANCE_SEED")
    info "FIELD_ACCT_HASH derived from seed"

    local ENGSTATION_ID
    ENGSTATION_ID=$(random_engstation_id)

    local TAG_NAMESPACE_PREFIX
    TAG_NAMESPACE_PREFIX=$(random_namespace)

    # RTU config: ASDU address (1-65534), target IOA and IOA end in safe range
    local ASDU_ADDR_DESC TARGET_IOA IOA_END
    ASDU_ADDR_DESC=$(random_int_range 1 200)
    TARGET_IOA=$(random_int_range 1000 5000)
    IOA_END=$(( TARGET_IOA + $(random_int_range 50 200) ))

    local SCIL_EXPECTED_IOA="${TARGET_IOA}"

    local GOOSE_CONF_REV GOOSE_APPID
    GOOSE_CONF_REV=$(random_int_range 1 9999)
    GOOSE_APPID=$(printf '0x%04X' "$(random_int_range 1 65534)")

    # 6. Write range.env (shared across all stages)
    cat > "${RANGE_ENV}" <<ENVEOF
# ============================================================================
# Prabal Urja Pvt Ltd — Range Instance Configuration
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# RANGE_BASE_CIDR: ${base_cidr}
# ============================================================================

# --- Zone Subnets ---
PUBLIC_ZONE_SUBNET=${PUBLIC_ZONE_SUBNET}
OT_ZONE_SUBNET=${OT_ZONE_SUBNET}
STATION_ZONE_SUBNET=${STATION_ZONE_SUBNET}
PROCESS_ZONE_SUBNET=${PROCESS_ZONE_SUBNET}
VPN_SUBNET=${VPN_SUBNET}

# --- Public Zone Container IPs ---
PUBLIC_ZONE_GATEWAY_IP=${PUBLIC_ZONE_GATEWAY_IP}

# --- OT Zone Container IPs ---
OT_ZONE_GATEWAY_IP=${OT_ZONE_GATEWAY_IP}
HISTORIAN_IP=${HISTORIAN_IP}
RTU_IP=${RTU_IP}

# --- Station Zone Container IPs ---
STATION_ZONE_GATEWAY_IP=${STATION_ZONE_GATEWAY_IP}
EWS_IP=${EWS_IP}

# --- Process Zone Container IPs ---
PROCESS_ZONE_GATEWAY_IP=${PROCESS_ZONE_GATEWAY_IP}
BAY_CONTROLLER_IP=${BAY_CONTROLLER_IP}

# --- Instance Seed ---
INSTANCE_SEED=${INSTANCE_SEED}

# --- Stage 1: VPN Gateway ---
FIELD_ACCT_HASH='${FIELD_ACCT_HASH}'

# --- Stage 2: Engineering Workstation ---
ENGSTATION_ID=${ENGSTATION_ID}

# --- Stage 3: Historian ---
TAG_NAMESPACE_PREFIX=${TAG_NAMESPACE_PREFIX}

# --- Stage 3/4: RTU Config ---
ASDU_ADDR_DESC=${ASDU_ADDR_DESC}
TARGET_IOA=${TARGET_IOA}
IOA_END=${IOA_END}

# --- Stage 4: Bay Controller ---
SCIL_EXPECTED_IOA=${SCIL_EXPECTED_IOA}
GOOSE_CONF_REV=${GOOSE_CONF_REV}
GOOSE_APPID=${GOOSE_APPID}
ENVEOF

    chmod 600 "${RANGE_ENV}"
    info "range.env written to ${RANGE_ENV}"

    # 7. Write per-container env files
    mkdir -p "${SHARED_DIR}/env"

    # vpn-gateway.env
    cat > "${SHARED_DIR}/env/vpn-gateway.env" <<EOF
PUBLIC_ZONE_SUBNET=${PUBLIC_ZONE_SUBNET}
PUBLIC_ZONE_GATEWAY_IP=${PUBLIC_ZONE_GATEWAY_IP}
FIELD_ACCT_HASH=${FIELD_ACCT_HASH}
INSTANCE_SEED=${INSTANCE_SEED}
VPN_SUBNET=${VPN_SUBNET}
EOF

    # ews-node.env
    cat > "${SHARED_DIR}/env/ews-node.env" <<EOF
STATION_ZONE_SUBNET=${STATION_ZONE_SUBNET}
EWS_IP=${EWS_IP}
ENGSTATION_ID=${ENGSTATION_ID}
INSTANCE_SEED=${INSTANCE_SEED}
EOF

    # historian-srv.env
    cat > "${SHARED_DIR}/env/historian-srv.env" <<EOF
OT_ZONE_SUBNET=${OT_ZONE_SUBNET}
HISTORIAN_IP=${HISTORIAN_IP}
TAG_NAMESPACE_PREFIX=${TAG_NAMESPACE_PREFIX}
ASDU_ADDR_DESC=${ASDU_ADDR_DESC}
TARGET_IOA=${TARGET_IOA}
IOA_END=${IOA_END}
INSTANCE_SEED=${INSTANCE_SEED}
EOF

    # rtu-server.env
    cat > "${SHARED_DIR}/env/rtu-server.env" <<EOF
OT_ZONE_SUBNET=${OT_ZONE_SUBNET}
RTU_IP=${RTU_IP}
ASDU_ADDR_DESC=${ASDU_ADDR_DESC}
TARGET_IOA=${TARGET_IOA}
IOA_END=${IOA_END}
INSTANCE_SEED=${INSTANCE_SEED}
EOF

    # bay-controller.env
    cat > "${SHARED_DIR}/env/bay-controller.env" <<EOF
PROCESS_ZONE_SUBNET=${PROCESS_ZONE_SUBNET}
BAY_CONTROLLER_IP=${BAY_CONTROLLER_IP}
SCIL_EXPECTED_IOA=${SCIL_EXPECTED_IOA}
GOOSE_CONF_REV=${GOOSE_CONF_REV}
GOOSE_APPID=${GOOSE_APPID}
INSTANCE_SEED=${INSTANCE_SEED}
EOF

    # jump-host.env (OT zone gateway — bridges public→OT)
    cat > "${SHARED_DIR}/env/jump-host.env" <<EOF
PUBLIC_ZONE_SUBNET=${PUBLIC_ZONE_SUBNET}
OT_ZONE_SUBNET=${OT_ZONE_SUBNET}
OT_ZONE_GATEWAY_IP=${OT_ZONE_GATEWAY_IP}
INSTANCE_SEED=${INSTANCE_SEED}
EOF

    chmod 600 "${SHARED_DIR}"/env/*.env
    info "Per-container env files written to ${SHARED_DIR}/env/"

    # 8. Write artifact-contract.json
    cat > "${SHARED_DIR}/artifact-contract.json" <<JSONEOF
{
  "range_base_cidr": "${base_cidr}",
  "generated_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "artifacts": {
    "INSTANCE_SEED": {
      "generation": "openssl rand -hex 32",
      "delivered_to": "all containers (Podman secret ctf_seed)",
      "precomputable": true
    },
    "zone_subnets": {
      "PUBLIC_ZONE_SUBNET": "${PUBLIC_ZONE_SUBNET}",
      "OT_ZONE_SUBNET": "${OT_ZONE_SUBNET}",
      "STATION_ZONE_SUBNET": "${STATION_ZONE_SUBNET}",
      "PROCESS_ZONE_SUBNET": "${PROCESS_ZONE_SUBNET}",
      "generation": "deterministic subdivision of RANGE_BASE_CIDR",
      "delivered_to": "all containers via per-container .env"
    },
    "FIELD_ACCT_HASH": {
      "generation": "HMAC-SHA256 derived salt from INSTANCE_SEED",
      "delivered_to": "vpn-gateway",
      "env_var": "FIELD_ACCT_HASH"
    },
    "ENGSTATION_ID": {
      "generation": "random per instance",
      "delivered_to": "ews-node",
      "env_var": "ENGSTATION_ID"
    },
    "TAG_NAMESPACE_PREFIX": {
      "generation": "random plausible fictional label",
      "delivered_to": "historian-srv",
      "env_var": "TAG_NAMESPACE_PREFIX"
    },
    "RTU_CONFIG": {
      "ASDU_ADDR_DESC": "${ASDU_ADDR_DESC}",
      "TARGET_IOA": "${TARGET_IOA}",
      "IOA_END": "${IOA_END}",
      "generation": "random offset within safe range",
      "delivered_to": ["historian-srv", "rtu-server"]
    },
    "SCIL_EXPECTED_IOA": {
      "value": "${SCIL_EXPECTED_IOA}",
      "generation": "same as TARGET_IOA",
      "delivered_to": "bay-controller",
      "env_var": "SCIL_EXPECTED_IOA"
    },
    "GOOSE_CONFIG": {
      "GOOSE_CONF_REV": "${GOOSE_CONF_REV}",
      "GOOSE_APPID": "${GOOSE_APPID}",
      "generation": "random per instance",
      "delivered_to": "bay-controller"
    }
  },
  "flags": {
    "S1":  {"precomputable": true,  "stage": 1, "description": "Gateway credential file access"},
    "S2":  {"precomputable": true,  "stage": 2, "description": "Engineering workstation pivot"},
    "S3":  {"precomputable": true,  "stage": 3, "description": "Historian data extraction"},
    "S4":  {"precomputable": true,  "stage": 4, "description": "RTU protocol manipulation"},
    "S4b": {"precomputable": false, "stage": 4, "description": "Bay controller lateral move (lazy)"},
    "S5A": {"precomputable": false, "stage": 5, "description": "Process zone initial access (lazy)"},
    "S5B": {"precomputable": false, "stage": 5, "description": "Process zone objective (lazy)"}
  }
}
JSONEOF
    info "artifact-contract.json written"

    # 9. Write artifact-contract.md
    cat > "${SHARED_DIR}/artifact-contract.md" <<'MDEOF'
# Artifact Contract — Prabal Urja Pvt Ltd Range

| Artifact | Generation | Delivered to | Env var |
|---|---|---|---|
| INSTANCE_SEED | `openssl rand -hex 32` | all containers | Podman secret `ctf_seed` |
| Zone subnets + container IPs | derived from `RANGE_BASE_CIDR` | all containers | `PUBLIC_ZONE_SUBNET`, `OT_ZONE_SUBNET`, `STATION_ZONE_SUBNET`, `PROCESS_ZONE_SUBNET` + per-container `*_IP` vars |
| field_tech account hash | salt derived from INSTANCE_SEED | vpn-gateway | `FIELD_ACCT_HASH` |
| Engineering endpoint identifier | random per instance | ews-node | `ENGSTATION_ID` |
| Facility namespace prefix | random plausible fictional label | historian-srv | `TAG_NAMESPACE_PREFIX` |
| RTU config string | random offset within safe range | historian-srv + rtu-server | `ASDU_ADDR_DESC`, `TARGET_IOA`, `IOA_END` |
| SCIL expected IOA | same as TARGET_IOA | bay-controller | `SCIL_EXPECTED_IOA` |
| GOOSE confRev / APPID | random per instance | bay-controller | `GOOSE_CONF_REV`, `GOOSE_APPID` |

## Flag Precomputability

| Flag | Stage | Precomputable at Provision | Description |
|---|---|---|---|
| S1 | 1 | Yes | Gateway credential file access |
| S2 | 2 | Yes | Engineering workstation pivot |
| S3 | 3 | Yes | Historian data extraction |
| S4 | 4 | Yes | RTU protocol manipulation |
| S4b | 4 | No (lazy) | Bay controller lateral move |
| S5A | 5 | No (lazy) | Process zone initial access |
| S5B | 5 | No (lazy) | Process zone objective |
MDEOF
    info "artifact-contract.md written"
}

# ---------------------------------------------------------------------------
# STAGE 1 DEPLOYMENT — vpn-gateway container
# ---------------------------------------------------------------------------
deploy_vpn_gateway() {
    info "Loading range.env from ${RANGE_ENV}"
    # shellcheck disable=SC1090
    source "${RANGE_ENV}"

    if ! sudo -E podman secret inspect ctf_seed &>/dev/null; then
        info "Creating Podman secret 'ctf_seed' from range.env"
        echo -n "${INSTANCE_SEED}" | sudo -E podman secret create ctf_seed -
    fi

    info "Building vpn-gateway container image..."

    # Build the Dockerfile
    sudo -E podman build --network host -t vpn-gateway:latest "${VPN_DIR}/"

    # Determine subnet prefix for network creation
    local pub_net_name="public_zone_net"

    # Remove existing network/container if present
    sudo -E podman stop vpn-gateway 2>/dev/null || true
    sudo -E podman rm vpn-gateway 2>/dev/null || true
    if ! sudo -E podman network exists "${pub_net_name}" &>/dev/null; then
        # Create the public zone bridge network
        info "Creating Podman bridge network: ${pub_net_name} (${PUBLIC_ZONE_SUBNET})"
        sudo -E podman network create \
            --driver bridge \
            --subnet "${PUBLIC_ZONE_SUBNET}" \
            --gateway "$(nth_host "${PUBLIC_ZONE_SUBNET}" 1)" \
            "${pub_net_name}"
    else
        info "Podman bridge network '${pub_net_name}' already exists"
    fi

    # Start vpn-gateway container
    info "Starting vpn-gateway container at ${PUBLIC_ZONE_GATEWAY_IP}"
    sudo -E podman run -d \
        --name vpn-gateway \
        --hostname vpn-gateway \
        --network "${pub_net_name}:ip=${PUBLIC_ZONE_GATEWAY_IP}" \
        --env-file "${SHARED_DIR}/env/vpn-gateway.env" \
        --secret ctf_seed,type=mount,target=/run/secrets/ctf_seed \
        --cap-add NET_ADMIN \
        --device /dev/net/tun \
        -p 1194:1194/udp \
        -p 2222:22/tcp \
        --restart unless-stopped \
        vpn-gateway:latest

    info "vpn-gateway container started"

    # Ensure host's forwarding policy (e.g. Docker's FORWARD DROP) doesn't block traffic
    if command -v iptables &>/dev/null; then
        iptables -C FORWARD -d "${PUBLIC_ZONE_SUBNET}" -j ACCEPT &>/dev/null || iptables -I FORWARD -d "${PUBLIC_ZONE_SUBNET}" -j ACCEPT || true
        iptables -C FORWARD -s "${PUBLIC_ZONE_SUBNET}" -j ACCEPT &>/dev/null || iptables -I FORWARD -s "${PUBLIC_ZONE_SUBNET}" -j ACCEPT || true
    fi

    # Wait for entrypoint initialization
    info "Waiting for container initialization..."
    sleep 5

    # Extract the generated .ovpn client profile
    local ovpn_out="${SCRIPT_DIR}/client-connect.ovpn"
    sudo -E podman cp vpn-gateway:/etc/openvpn/client/client-connect.ovpn "${ovpn_out}" 2>/dev/null || \
        warn "Could not extract .ovpn profile — container may still be initializing"

    if [[ -f "${ovpn_out}" ]]; then
        info "Client .ovpn profile extracted to: ${ovpn_out}"
    fi

    # Verify the flag was generated
    local flag_check
    flag_check=$(sudo -E podman exec vpn-gateway cat /run/ctf/stage1_flag 2>/dev/null) || true
    if [[ -n "${flag_check}" ]]; then
        info "Stage 1 flag verified (stored inside container at /run/ctf/stage1_flag)"
    else
        warn "Flag file not yet available — container may still be initializing"
    fi

    info "Stage 1 deployment complete"
    echo ""
    info "Connection info:"
    info "  SSH:    ssh field_tech@<HOST_IP> -p 2222"
    info "  OpenVPN: use ${ovpn_out} for client connection"
    info "  Public Zone Subnet: ${PUBLIC_ZONE_SUBNET}"
    info "  VPN Gateway IP: ${PUBLIC_ZONE_GATEWAY_IP}"
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
main() {
    info "=== Prabal Urja Pvt Ltd — Stage 1: VPN Gateway ==="
    echo ""

    # Check if range.env exists
    if [[ ! -f "${RANGE_ENV}" ]]; then
        # Need RANGE_BASE_CIDR argument
        if [[ $# -lt 1 ]]; then
            die "No range.env found and no RANGE_BASE_CIDR supplied.\nUsage: $0 <RANGE_BASE_CIDR>\nExample: $0 10.100.0.0/22"
        fi
        provision_range "$1"
    else
        info "Using existing range.env at ${RANGE_ENV}"
        if [[ $# -ge 1 ]]; then
            warn "range.env already exists — ignoring supplied CIDR '$1'"
            warn "To re-provision, delete ${RANGE_ENV} first or use chall_reset.sh --rotate-seed"
        fi
    fi

    deploy_vpn_gateway

    info "=== Stage 1 setup complete ==="
}

main "$@"
