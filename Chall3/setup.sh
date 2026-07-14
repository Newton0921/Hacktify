#!/usr/bin/env bash
###############################################################################
# Chall3 / Stage 3 — OPC UA Historian Service Setup
# Prabal Urja Pvt Ltd — OT/ICS Red-Team Range
#
# Sources ../shared/range.env, then builds and starts the historian-srv
# container (Linux, asyncua-based OPC UA server) on port 4840/TCP bound
# to the OT-zone IP.
#
# The server exposes a namespace tree 4-6 levels deep under:
#   <TAG_NAMESPACE_PREFIX>/Substation/Bay/<nodes>
# populated with a large set of decoy telemetry tags and a smaller set
# of control-oriented tag substrings at varying depths.
#
# One privileged node carries Description = ASDU_ADDR_DESC verbatim,
# placed at a realistic, non-obvious depth within the hierarchy.
#
# The stage flag is computed at startup from that Description string
# and stored at /run/ctf/stage3_flag only (never player-visible).
#
# Usage:
#   ./setup.sh          # uses existing range.env
#
# No hardcoded IP/subnet literals anywhere.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="$(cd "${SCRIPT_DIR}/../shared" && pwd)"
RANGE_ENV="${SHARED_DIR}/range.env"

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[-]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

# ---------------------------------------------------------------------------
# CIDR helpers (same as Chall1 — for gateway derivation)
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
# Load range.env
# ---------------------------------------------------------------------------
[[ -f "${RANGE_ENV}" ]] || die "range.env not found at ${RANGE_ENV}. Run Chall1/setup.sh first."
# shellcheck disable=SC1090
source "${RANGE_ENV}"

# Validate required variables
for var in INSTANCE_SEED OT_ZONE_SUBNET HISTORIAN_IP TAG_NAMESPACE_PREFIX ASDU_ADDR_DESC; do
    [[ -n "${!var:-}" ]] || die "${var} not set in range.env"
done

info "=== Prabal Urja Pvt Ltd — Stage 3: OPC UA Historian ==="
echo ""
info "Configuration:"
info "  OT Zone Subnet     : ${OT_ZONE_SUBNET}"
info "  Historian IP        : ${HISTORIAN_IP}"
info "  Namespace Prefix    : ${TAG_NAMESPACE_PREFIX}"
info "  ASDU Address Desc   : ${ASDU_ADDR_DESC}"

# ---------------------------------------------------------------------------
# Compute Stage 3 flag
# ---------------------------------------------------------------------------
compute_flag() {
    local seed="$1" artifact="$2"
    local flag_msg="STAGE3:${artifact}"
    local flag_hex
    flag_hex=$(echo -n "$flag_msg" | \
        openssl dgst -sha256 -mac HMAC -macopt "hexkey:${seed}" | \
        awk '{print $NF}' | head -c 16)
    echo "FLAG{S3-${flag_hex}}"
}

STAGE3_FLAG=$(compute_flag "${INSTANCE_SEED}" "${ASDU_ADDR_DESC}")
info "Stage 3 flag computed (will be stored in container at /run/ctf/stage3_flag)"

# ---------------------------------------------------------------------------
# Generate the historian OPC UA server Python script
# ---------------------------------------------------------------------------
HISTORIAN_DIR="${SCRIPT_DIR}/historian-srv"
mkdir -p "${HISTORIAN_DIR}"

cat > "${HISTORIAN_DIR}/historian_server.py" <<'PYEOF'
#!/usr/bin/env python3
"""
OPC UA Historian Server — Prabal Urja Pvt Ltd
Builds a deep namespace tree with decoy telemetry and one privileged node.
All configuration sourced from environment variables.
"""
import asyncio
import os
import sys
import random
import hashlib
import time

from asyncua import Server, ua

# ---------------------------------------------------------------------------
# Configuration from environment
# ---------------------------------------------------------------------------
TAG_PREFIX      = os.environ["TAG_NAMESPACE_PREFIX"]
ASDU_ADDR_DESC  = os.environ["ASDU_ADDR_DESC"]
HISTORIAN_IP    = os.environ.get("HISTORIAN_IP", "0.0.0.0")
INSTANCE_SEED   = os.environ["INSTANCE_SEED"]

# Seed the PRNG deterministically so the tree is consistent per instance
random.seed(INSTANCE_SEED)

# ---------------------------------------------------------------------------
# Internal constants — NOT player-facing
# ---------------------------------------------------------------------------
# Control-oriented substrings placed at varying depths (implementation detail)
_CTRL_SUBS = [
    "RemoteAddr", "ProtocolCfg", "CommLink", "AsduConfig",
    "TelecontrolRef", "StationParam", "LinkAddr", "FieldUnit",
    "RemoteTerminal", "CtrlEndpoint", "ctlSelOn", "stVal",
    "stNum", "ctlVal",
]

# Telemetry/decoy substrings for bulk noise
_TELEM_SUBS = [
    "Voltage_kV", "Current_A", "Power_MW", "ReactivePower_MVAR",
    "Frequency_Hz", "Temperature_C", "Pressure_kPa", "FlowRate_m3h",
    "BusbarVoltage", "TransformerTap", "CircuitBreakerSts", "DisconnectorSts",
    "LoadProfile", "EnergyAccum_kWh", "PowerFactor", "HarmonicDistortion",
    "CoolingFanSts", "OilLevel_pct", "AmbientTemp_C", "WindSpeed_ms",
    "SolarIrradiance", "BatterySOC_pct", "InverterOutput_kW", "TurbineRPM",
    "GeneratorMW", "SteamPressure_bar", "FuelConsumption_Lh",
    "ExhaustTemp_C", "StackEmission_ppm", "WaterLevel_m",
    "PumpFlowRate", "ValvePosition_pct", "CompressorSts", "FilterDiffP_kPa",
    "MotorCurrent_A", "MotorTemp_C", "BearingVibration_mms",
    "CapacitorBank_MVAR", "ReactorBank_MVAR", "GroundFaultCurrent_mA",
    "SurgeArresterCnt", "BushingTemp_C", "InsulationResistance_MOhm",
    "TapChangerPos", "GasAnalysis_ppm", "MoistureContent_ppm",
    "DGA_H2_ppm", "DGA_CH4_ppm", "DGA_C2H2_ppm", "DGA_CO_ppm",
    "PartialDischarge_pC", "ContactWear_pct", "OperationCounter",
    "TripCoilCurrent_A", "ClosingTime_ms", "OpeningTime_ms",
    "SpringChargeSts", "GasPressure_bar", "SF6_Density_kgm3",
]

# Bay/feeder names for tree branching
_BAY_NAMES = [
    "Bay01_Feeder", "Bay02_Transformer", "Bay03_BusCoupler",
    "Bay04_LineProtection", "Bay05_CapBank", "Bay06_Auxiliary",
    "Bay07_Generator", "Bay08_MotorControl", "Bay09_BusTie",
    "Bay10_ReactorBank", "Bay11_SolarInverter", "Bay12_BESS",
]

# Sub-equipment groupings for deeper levels
_EQUIPMENT_GROUPS = [
    "Protection", "Measurement", "Control", "Monitoring",
    "Communication", "Diagnostics", "Maintenance", "HistoricalLog",
]


async def build_namespace(server: Server) -> None:
    """
    Build a 4-6 level deep namespace tree.
    Structure:
        ns:TAG_PREFIX/Substation
          └─ Bay/
             └─ <bay_name>/
                └─ <equipment_group>/
                   └─ <tag_node>          (depth 4-5 for decoys)
                   └─ <sub_folder>/
                      └─ <tag_node>       (depth 5-6 for some tags)

    One privileged node carries Description = ASDU_ADDR_DESC and is placed
    at a realistic depth (5-6 levels) within a control-oriented branch.
    """
    ns_uri = f"urn:prabalurja:{TAG_PREFIX}:historian"
    idx = await server.register_namespace(ns_uri)

    # Root: <TAG_PREFIX>
    root_obj = server.get_objects_node()
    prefix_node = await root_obj.add_folder(idx, TAG_PREFIX)

    # Level 1: Substation
    substation = await prefix_node.add_folder(idx, "Substation")

    # Level 2: Bay
    bay_root = await substation.add_folder(idx, "Bay")

    privileged_placed = False
    # Choose a random bay and group for the privileged node
    priv_bay_idx = random.randint(0, len(_BAY_NAMES) - 1)
    priv_grp_idx = random.randint(0, len(_EQUIPMENT_GROUPS) - 1)
    # Ensure it lands in a "Communication" or "Control" style group for realism
    while _EQUIPMENT_GROUPS[priv_grp_idx] not in ("Communication", "Control", "Monitoring"):
        priv_grp_idx = random.randint(0, len(_EQUIPMENT_GROUPS) - 1)

    for bay_i, bay_name in enumerate(_BAY_NAMES):
        bay_node = await bay_root.add_folder(idx, bay_name)

        for grp_i, grp_name in enumerate(_EQUIPMENT_GROUPS):
            grp_node = await bay_node.add_folder(idx, grp_name)

            # Decide how many tags in this group (5-15 for telemetry)
            num_tags = random.randint(5, 15)
            tag_pool = random.sample(
                _TELEM_SUBS, min(num_tags, len(_TELEM_SUBS))
            )

            # Some groups get control-oriented tags mixed in (depth 4)
            if grp_name in ("Control", "Communication", "Monitoring"):
                ctrl_count = random.randint(1, 3)
                ctrl_tags = random.sample(_CTRL_SUBS, ctrl_count)
                tag_pool.extend(ctrl_tags)

            for tag_name in tag_pool:
                qualified = f"{bay_name}_{grp_name}_{tag_name}"
                var = await grp_node.add_variable(
                    idx, qualified,
                    ua.Variant(round(random.uniform(0, 500), 2), ua.VariantType.Double)
                )
                await var.set_writable(False)
                # Set a generic description for decoy nodes
                desc = ua.LocalizedText(f"Telemetry point: {qualified}")
                await var.write_attribute(
                    ua.AttributeIds.Description,
                    ua.DataValue(ua.Variant(desc, ua.VariantType.LocalizedText))
                )

            # Add deeper sub-folders for some groups (depth 5-6)
            if grp_name in ("Communication", "Control", "Diagnostics", "HistoricalLog"):
                sub_folders = ["Archive", "Config", "Runtime", "Parameters"]
                chosen_subs = random.sample(sub_folders, random.randint(1, 3))

                for sub_name in chosen_subs:
                    sub_node = await grp_node.add_folder(idx, sub_name)

                    # Add tags at depth 5
                    deep_count = random.randint(3, 8)
                    deep_tags = random.sample(
                        _TELEM_SUBS + _CTRL_SUBS,
                        min(deep_count, len(_TELEM_SUBS) + len(_CTRL_SUBS))
                    )

                    for dtag in deep_tags:
                        dqualified = f"{bay_name}_{sub_name}_{dtag}"
                        dvar = await sub_node.add_variable(
                            idx, dqualified,
                            ua.Variant(round(random.uniform(0, 1000), 3), ua.VariantType.Double)
                        )
                        await dvar.set_writable(False)
                        ddesc = ua.LocalizedText(f"Deep record: {dqualified}")
                        await dvar.write_attribute(
                            ua.AttributeIds.Description,
                            ua.DataValue(ua.Variant(ddesc, ua.VariantType.LocalizedText))
                        )

                    # === PRIVILEGED NODE PLACEMENT ===
                    # Place at depth 6 inside a nested sub-folder for non-obviousness
                    if (bay_i == priv_bay_idx and grp_i == priv_grp_idx
                            and sub_name == "Config" and not privileged_placed):
                        # One more level deep
                        inner_node = await sub_node.add_folder(idx, "DeviceRegistry")
                        priv_tag_name = f"{bay_name}_DeviceRegistry_RemoteUnit"
                        priv_var = await inner_node.add_variable(
                            idx, priv_tag_name,
                            ua.Variant(float(ASDU_ADDR_DESC), ua.VariantType.Double)
                        )
                        await priv_var.set_writable(False)
                        # Set Description to ASDU_ADDR_DESC VERBATIM
                        priv_desc = ua.LocalizedText(ASDU_ADDR_DESC)
                        await priv_var.write_attribute(
                            ua.AttributeIds.Description,
                            ua.DataValue(ua.Variant(priv_desc, ua.VariantType.LocalizedText))
                        )
                        privileged_placed = True
                        print(f"[SETUP] Privileged node placed: {priv_tag_name} "
                              f"(Description={ASDU_ADDR_DESC})", flush=True)

    # Fallback: if the random path didn't include "Config", place it now
    if not privileged_placed:
        fb_bay = await bay_root.get_children()
        fb_bay_node = fb_bay[priv_bay_idx % len(fb_bay)]
        fb_grps = await fb_bay_node.get_children()
        fb_grp_node = fb_grps[priv_grp_idx % len(fb_grps)]
        fb_config = await fb_grp_node.add_folder(idx, "Config")
        fb_inner = await fb_config.add_folder(idx, "DeviceRegistry")
        fb_name = f"FallbackUnit_DeviceRegistry_RemoteUnit"
        fb_var = await fb_inner.add_variable(
            idx, fb_name,
            ua.Variant(float(ASDU_ADDR_DESC), ua.VariantType.Double)
        )
        await fb_var.set_writable(False)
        fb_desc = ua.LocalizedText(ASDU_ADDR_DESC)
        await fb_var.write_attribute(
            ua.AttributeIds.Description,
            ua.DataValue(ua.Variant(fb_desc, ua.VariantType.LocalizedText))
        )
        print(f"[SETUP] Privileged node placed (fallback): {fb_name} "
              f"(Description={ASDU_ADDR_DESC})", flush=True)

    total_count = 0
    for bay_n in await bay_root.get_children():
        for grp_n in await bay_n.get_children():
            children = await grp_n.get_children()
            total_count += len(children)
            for child in children:
                sub_children = await child.get_children()
                total_count += len(sub_children)
                for sc in sub_children:
                    total_count += len(await sc.get_children())

    print(f"[SETUP] Namespace tree built: ~{total_count} nodes under "
          f"{TAG_PREFIX}/Substation/Bay/", flush=True)


async def main():
    server = Server()
    await server.init()

    server.set_endpoint(f"opc.tcp://0.0.0.0:4840/prabalurja/historian")
    server.set_server_name("Prabal Urja Historian Service")

    # Security: anonymous access (lab environment)
    server.set_security_policy([ua.SecurityPolicyType.NoSecurity])

    await build_namespace(server)

    # Write flag file
    os.makedirs("/run/ctf", exist_ok=True)
    flag_msg = f"STAGE3:{ASDU_ADDR_DESC}"
    import hmac as _hmac
    flag_hex = _hmac.new(
        bytes.fromhex(INSTANCE_SEED),
        flag_msg.encode(),
        hashlib.sha256
    ).hexdigest()[:16]
    stage_flag = f"FLAG{{S3-{flag_hex}}}"
    with open("/run/ctf/stage3_flag", "w") as fh:
        fh.write(stage_flag)
    os.chmod("/run/ctf/stage3_flag", 0o644)
    print(f"[SETUP] Stage 3 flag written to /run/ctf/stage3_flag", flush=True)

    print(f"[SETUP] OPC UA server starting on opc.tcp://0.0.0.0:4840/", flush=True)
    async with server:
        while True:
            await asyncio.sleep(1)


if __name__ == "__main__":
    asyncio.run(main())
PYEOF

info "historian_server.py generated"

# ---------------------------------------------------------------------------
# Generate Dockerfile
# ---------------------------------------------------------------------------
cat > "${HISTORIAN_DIR}/Dockerfile" <<'DKEOF'
FROM python:3.11-slim

RUN pip install --no-cache-dir asyncua

COPY historian_server.py /opt/historian/historian_server.py

EXPOSE 4840

CMD ["python3", "-u", "/opt/historian/historian_server.py"]
DKEOF

info "Dockerfile generated"

# ---------------------------------------------------------------------------
# Build and deploy historian-srv container
# ---------------------------------------------------------------------------
deploy_historian() {
    local ot_net_name="ot_zone_net"
    local ot_gw
    ot_gw=$(nth_host "${OT_ZONE_SUBNET}" 1)

    # Stop/remove existing
    podman stop historian-srv 2>/dev/null || true
    podman rm historian-srv 2>/dev/null || true

    # Create OT zone network if it doesn't already exist
    if ! podman network inspect "${ot_net_name}" &>/dev/null; then
        info "Creating Podman bridge network: ${ot_net_name} (${OT_ZONE_SUBNET})"
        podman network create \
            --driver bridge \
            --subnet "${OT_ZONE_SUBNET}" \
            --gateway "${ot_gw}" \
            "${ot_net_name}"
    else
        info "OT zone network '${ot_net_name}' already exists"
    fi

    # Build container image
    info "Building historian-srv container image..."
    podman build --network host -t historian-srv:latest "${HISTORIAN_DIR}/"

    # Prepare env file for this container
    local env_file="${SHARED_DIR}/env/historian-srv.env"
    info "Generating historian-srv.env from range.env"
    mkdir -p "${SHARED_DIR}/env"
    cat > "${env_file}" <<ENVEOF
OT_ZONE_SUBNET=${OT_ZONE_SUBNET}
HISTORIAN_IP=${HISTORIAN_IP}
TAG_NAMESPACE_PREFIX=${TAG_NAMESPACE_PREFIX}
ASDU_ADDR_DESC=${ASDU_ADDR_DESC}
TARGET_IOA=${TARGET_IOA:-0}
IOA_END=${IOA_END:-0}
INSTANCE_SEED=${INSTANCE_SEED}
ENVEOF
    chmod 600 "${env_file}"

    # Start historian-srv container
    info "Starting historian-srv container at ${HISTORIAN_IP} on port 4840/TCP"
    podman run -d \
        --name historian-srv \
        --hostname historian-srv \
        --network "${ot_net_name}:ip=${HISTORIAN_IP}" \
        --env-file "${env_file}" \
        --secret ctf_seed,type=mount,target=/run/secrets/ctf_seed \
        --restart unless-stopped \
        historian-srv:latest

    info "historian-srv container started"

    # Ensure host's forwarding policy (e.g. Docker's FORWARD DROP) doesn't block traffic
    if command -v iptables &>/dev/null; then
        iptables -C FORWARD -d "${OT_ZONE_SUBNET}" -j ACCEPT &>/dev/null || iptables -I FORWARD -d "${OT_ZONE_SUBNET}" -j ACCEPT || true
        iptables -C FORWARD -s "${OT_ZONE_SUBNET}" -j ACCEPT &>/dev/null || iptables -I FORWARD -s "${OT_ZONE_SUBNET}" -j ACCEPT || true
    fi

    # Wait for OPC UA server initialization
    info "Waiting for OPC UA server to initialize (namespace build)..."
    sleep 8

    # Verify flag was generated
    local flag_check
    flag_check=$(podman exec historian-srv cat /run/ctf/stage3_flag 2>/dev/null) || true
    if [[ -n "${flag_check}" ]]; then
        info "Stage 3 flag verified (stored inside container at /run/ctf/stage3_flag)"
    else
        warn "Flag file not yet available — server may still be building namespace"
    fi

    # Verify OPC UA port is listening
    if timeout 5 bash -c "echo >/dev/tcp/127.0.0.1/4840" 2>/dev/null; then
        info "OPC UA port 4840/TCP is reachable"
    else
        warn "OPC UA port 4840/TCP not yet reachable — server may still be starting"
    fi

    info "Stage 3 deployment complete"
    echo ""
    info "Connection info:"
    info "  OPC UA Endpoint : opc.tcp://${HISTORIAN_IP}:4840/prabalurja/historian"
    info "  Published Port  : 4840/TCP (from host: opc.tcp://127.0.0.1:4840/)"
    info "  Namespace Root  : ${TAG_NAMESPACE_PREFIX}/Substation/Bay/"
    info "  OT Zone Subnet  : ${OT_ZONE_SUBNET}"
}

deploy_historian

info "=== Stage 3 setup complete ==="
