#!/usr/bin/env bash
###############################################################################
# setup.sh — Stage 4 Deployment Script
#
# Sources range.env, builds the rtu-server container, creates the network
# configurations, generates the assessment worksheet, and runs the container.
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

info "=== Stage 4 Setup — Remote Terminal Unit Simulator ==="

# 1. Load and validate range.env
if [[ ! -f "${RANGE_ENV}" ]]; then
    die "No range.env found at ${RANGE_ENV}. Please run Stage 1 setup first."
fi
source "${RANGE_ENV}"

# Verify required variables
for var in TARGET_IOA IOA_END RTU_IP INSTANCE_SEED OT_ZONE_SUBNET; do
    if [[ -z "${!var:-}" ]]; then
        die "Required environment variable $var is not set in range.env"
    fi
done

info "Loaded configuration:"
info "  - TARGET_IOA:    ${TARGET_IOA}"
info "  - IOA_END:       ${IOA_END}"
info "  - RTU_IP:        ${RTU_IP}"
info "  - OT_ZONE_SUBNET:${OT_ZONE_SUBNET}"

# 2. Build the rtu-server image
info "Building rtu-server container image..."
podman build -t rtu-server:latest "${SCRIPT_DIR}/rtu-server"

# 3. Create OT network if not exists
if ! podman network exists ot_zone_net; then
    info "Creating network ot_zone_net with subnet ${OT_ZONE_SUBNET}..."
    podman network create --subnet="${OT_ZONE_SUBNET}" ot_zone_net
else
    info "Network ot_zone_net already exists"
fi

# 4. Generate environment file for container
ENV_DIR="${SHARED_DIR}/env"
mkdir -p "${ENV_DIR}"
ENV_FILE="${ENV_DIR}/rtu-server.env"

info "Generating environment file at ${ENV_FILE}..."
cat <<EOF > "${ENV_FILE}"
# Generated automatically by Stage 4 setup.sh
TARGET_IOA=${TARGET_IOA}
IOA_END=${IOA_END}
RTU_IP=${RTU_IP}
INSTANCE_SEED=${INSTANCE_SEED}
EOF
chmod 600 "${ENV_FILE}"

# 5. Clean up old container if running
if podman ps -a --format '{{.Names}}' | grep -q '^rtu-server$'; then
    warn "Removing existing rtu-server container..."
    podman stop rtu-server 2>/dev/null || true
    podman rm rtu-server 2>/dev/null || true
fi

# 6. Run the container
info "Running rtu-server container on ${RTU_IP}..."
podman run -d \
    --name rtu-server \
    --network ot_zone_net \
    --ip "${RTU_IP}" \
    --env-file "${ENV_FILE}" \
    --restart unless-stopped \
    rtu-server:latest

# Ensure ews-node is connected to ot_zone_net
if podman ps --format '{{.Names}}' | grep -q '^ews-node$'; then
    info "Ensuring ews-node is connected to ot_zone_net..."
    podman network connect ot_zone_net ews-node 2>/dev/null || true
fi

# 7. Generate Assessment Spreadsheet
info "Generating Assessment.xlsx..."
python3 "${SCRIPT_DIR}/generate_assessment.py"

# 8. Verify the service is active
info "Verifying rtu-server deployment..."
sleep 2

if ! podman ps --format '{{.Names}}' | grep -q '^rtu-server$'; then
    die "rtu-server container failed to start."
fi

# Verify port 2404 is open internally (use python since ss may not be installed)
if ! podman exec rtu-server python3 -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    s.connect(('127.0.0.1', 2404))
    s.close()
except Exception:
    sys.exit(1)
"; then
    die "rtu-server container is running but port 2404 is not listening."
fi

info "rtu-server deployed successfully on ${RTU_IP}:2404!"
