#!/usr/bin/env bash
###############################################################################
# setup.sh — Stage 5 Deployment Script
#
# Sources range.env, builds the substation-gw and bay-controller containers,
# creates isolated networks, runs them, and generates the assessment sheet.
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

# CIDR math helpers to find gateways/IPs without hardcoding
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

info "=== Stage 5 Setup — Substation Gateway & Bay Controller ==="

# 1. Load and validate range.env
if [[ ! -f "${RANGE_ENV}" ]]; then
    die "No range.env found at ${RANGE_ENV}. Please run Stage 1 setup first."
fi
source "${RANGE_ENV}"

# Verify required variables
for var in STATION_ZONE_SUBNET PROCESS_ZONE_SUBNET STATION_ZONE_GATEWAY_IP PROCESS_ZONE_GATEWAY_IP BAY_CONTROLLER_IP SCIL_EXPECTED_IOA GOOSE_CONF_REV GOOSE_APPID INSTANCE_SEED FIELD_ACCT_HASH; do
    if [[ -z "${!var:-}" ]]; then
        die "Required environment variable $var is not set in range.env"
    fi
done

# Derived IPs/configurations
SUBSTATION_GW_STATION_IP=$(nth_host "${STATION_ZONE_SUBNET}" 254) # e.g. 10.100.2.254
BAY_CONTROLLER_STATION_IP=$(nth_host "${STATION_ZONE_SUBNET}" 10)  # e.g. 10.100.2.10

info "Configuration Loaded:"
info "  - Station Zone Subnet:  ${STATION_ZONE_SUBNET}"
info "  - Process Zone Subnet:  ${PROCESS_ZONE_SUBNET}"
info "  - Substation GW IP:     ${SUBSTATION_GW_STATION_IP} (station) / ${PROCESS_ZONE_GATEWAY_IP} (process)"
info "  - Bay Controller IP:    ${BAY_CONTROLLER_STATION_IP} (station) / ${BAY_CONTROLLER_IP} (process)"
info "  - GOOSE ConfRev:        ${GOOSE_CONF_REV}"
info "  - GOOSE APPID:          ${GOOSE_APPID}"
info "  - SCIL Expected IOA:    ${SCIL_EXPECTED_IOA}"

# 2. Build container images
info "Building substation-gw container image..."
sudo -E podman build --network host -t substation-gw:latest "${SCRIPT_DIR}/substation-gw"

info "Building bay-controller container image..."
sudo -E podman build --network host -t bay-controller:latest "${SCRIPT_DIR}/bay-controller"

# 3. Network Configuration
# 3a. Station Zone Bridge
if ! sudo -E podman network exists station_zone_net; then
    info "Creating network station_zone_net with subnet ${STATION_ZONE_SUBNET}..."
    sudo -E podman network create --subnet="${STATION_ZONE_SUBNET}" station_zone_net
else
    info "Network station_zone_net already exists."
fi

# 3b. Process Zone bridge (isolated L2 segment for GOOSE multicast)
if ! sudo -E podman network exists process_zone_net; then
    info "Creating process_zone_net bridge network (isolated L2 for GOOSE)..."
    sudo -E podman network create \
        --internal \
        --subnet="${PROCESS_ZONE_SUBNET}" \
        process_zone_net
else
    info "Network process_zone_net already exists."
fi

# 4. Generate Environment Files
ENV_DIR="${SHARED_DIR}/env"
mkdir -p "${ENV_DIR}"

GW_ENV_FILE="${ENV_DIR}/substation-gw.env"
BC_ENV_FILE="${ENV_DIR}/bay-controller.env"

info "Generating environment files..."
cat <<EOF > "${GW_ENV_FILE}"
# Generated automatically by Stage 5 setup.sh
FIELD_ACCT_HASH=${FIELD_ACCT_HASH}
INSTANCE_SEED=${INSTANCE_SEED}
EOF
chmod 600 "${GW_ENV_FILE}"

cat <<EOF > "${BC_ENV_FILE}"
# Generated automatically by Stage 5 setup.sh
PROCESS_ZONE_SUBNET=${PROCESS_ZONE_SUBNET}
BAY_CONTROLLER_IP=${BAY_CONTROLLER_IP}
SCIL_EXPECTED_IOA=${SCIL_EXPECTED_IOA}
GOOSE_CONF_REV=${GOOSE_CONF_REV}
GOOSE_APPID=${GOOSE_APPID}
INSTANCE_SEED=${INSTANCE_SEED}
EOF
chmod 600 "${BC_ENV_FILE}"

# 5. Clean up old containers
for name in substation-gw bay-controller; do
    if sudo -E podman ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
        warn "Removing existing ${name} container..."
        sudo -E podman stop "${name}" 2>/dev/null || true
        sudo -E podman rm "${name}" 2>/dev/null || true
    fi
done

# 6. Deploy containers
info "Running substation-gw container..."
sudo -E podman run -d \
    --name substation-gw \
    --network "station_zone_net:ip=${SUBSTATION_GW_STATION_IP}" \
    --env-file "${GW_ENV_FILE}" \
    --cap-add=NET_RAW \
    --restart unless-stopped \
    substation-gw:latest


info "Connecting substation-gw to process_zone_net..."
sudo -E podman network connect process_zone_net substation-gw --ip "${PROCESS_ZONE_GATEWAY_IP}"

info "Running bay-controller container..."
sudo -E podman run -d \
    --name bay-controller \
    --network "station_zone_net:ip=${BAY_CONTROLLER_STATION_IP}" \
    --env-file "${BC_ENV_FILE}" \
    --cap-add=NET_RAW \
    --cap-add=NET_ADMIN \
    --restart unless-stopped \
    bay-controller:latest

info "Connecting bay-controller to process_zone_net..."
sudo -E podman network connect process_zone_net bay-controller --ip "${BAY_CONTROLLER_IP}"

# 7. Generate Assessment Spreadsheet
info "Generating Assessment.xlsx..."
python3 - <<'EOF'
import openpyxl
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter
import os

wb = openpyxl.Workbook()
ws = wb.active
ws.title = "Stage 5 Assessment"

header_font = Font(name="Calibri", bold=True, size=12, color="FFFFFF")
header_fill = PatternFill(start_color="2F5496", end_color="2F5496", fill_type="solid")
header_align = Alignment(horizontal="center", vertical="center", wrap_text=True)
row_font = Font(name="Calibri", size=11)
row_align = Alignment(vertical="center", wrap_text=True)

border = Border(
    left=Side(style="thin"),
    right=Side(style="thin"),
    top=Side(style="thin"),
    bottom=Side(style="thin"),
)

ws.merge_cells("A1:E1")
title_cell = ws["A1"]
title_cell.value = "Stage 5 — Substation Gateway and Bay Controller Assessment"
title_cell.font = Font(name="Calibri", bold=True, size=14, color="2F5496")
title_cell.alignment = Alignment(horizontal="center", vertical="center")
ws.row_dimensions[1].height = 30
ws.row_dimensions[2].height = 10

headers = ["Objective", "Points", "Evidence Required", "Tripwire Penalty", "Pass/Fail Criteria"]
col_widths = [45, 10, 40, 25, 45]

for col_idx, (header, width) in enumerate(zip(headers, col_widths), start=1):
    cell = ws.cell(row=3, column=col_idx, value=header)
    cell.font = header_font
    cell.fill = header_fill
    cell.alignment = header_align
    cell.border = border
    ws.column_dimensions[get_column_letter(col_idx)].width = width

data = [
    [
        "Stage 4b: Post-authentication interface enumeration of substation-gw to confirm process-zone adjacency",
        100,
        "Artifact MAC address of process-zone interface captured on interface enumeration",
        "None",
        "Submitted flag FLAG{S4b-...} matches stored value computed from HMAC-SHA256(INSTANCE_SEED, 'STAGE4b:<mac>')"
    ],
    [
        "Stage 5a: Correctly sequenced/confRev-matched L2 trip message sent to L2 multicast responder on process-zone macvlan",
        200,
        "Artifact SHA256 hash of the valid trip message packet bytes",
        "Tripwire penalty for mismatched confRev/sequence frames or MMS connection attempts before 4b complete",
        "Submitted flag FLAG{S5a-...} matches stored value computed from HMAC-SHA256(INSTANCE_SEED, 'STAGE5a:<hash>')"
    ],
    [
        "Stage 5b: Upload syntactically valid script targeting SCIL_EXPECTED_IOA to the legacy scripting interface",
        200,
        "TOKEN_OK:<ts>:<addr>:<hash> captured from legacy scripting interface stdout",
        "Tripwire penalty for >3 failed legacy-interface parses",
        "Submitted flag FLAG{S5b-...} matches stored value computed from HMAC-SHA256(INSTANCE_SEED, 'STAGE5b:<token>')"
    ]
]

for row_idx, row_data in enumerate(data, start=4):
    for col_idx, value in enumerate(row_data, start=1):
        cell = ws.cell(row=row_idx, column=col_idx, value=value)
        cell.font = row_font
        cell.alignment = row_align
        cell.border = border
    ws.row_dimensions[row_idx].height = 50

output_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Assessment.xlsx")
wb.save(output_path)
print(f"[+] Assessment.xlsx written to {output_path}")
EOF


# 8. Verify the services are active
info "Verifying deployment..."
sleep 4

# Check container running status
for name in substation-gw bay-controller; do
    if ! sudo -E podman ps --format '{{.Names}}' | grep -q "^${name}$"; then
        die "${name} container failed to start."
    fi
done

# Verify SSH on substation-gw
if ! sudo -E podman exec substation-gw ss -tlnp | grep -q ':22 '; then
    die "substation-gw is running but port 22 is not listening."
fi

# Verify port 102 and 9022 on bay-controller
if ! sudo -E podman exec bay-controller ss -tlnp | grep -q ':102 '; then
    die "bay-controller is running but MMS port 102 is not listening."
fi
if ! sudo -E podman exec bay-controller ss -tlnp | grep -q ':9022 '; then
    die "bay-controller is running but legacy scripting port 9022 is not listening."
fi

info "Stage 5 deployment complete and verified!"
info "Connection Details:"
info "  - substation-gw:  ssh field_tech@${SUBSTATION_GW_STATION_IP} (Password: FieldTech2024!)"
info "  - bay-controller: MMS on ${BAY_CONTROLLER_STATION_IP}:102"
info "                    SCIL scripting on ${BAY_CONTROLLER_STATION_IP}:9022"
