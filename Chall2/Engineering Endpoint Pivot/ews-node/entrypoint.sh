#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# ews-node entrypoint — Stage 2
# Reads all config from environment variables, never hardcodes IPs/subnets.
# ===========================================================================

log() { echo "[ews-node] $(date '+%H:%M:%S') $*"; }

# ---- Validate required env vars ------------------------------------------
for v in STATION_ZONE_SUBNET EWS_IP ENGSTATION_ID FIELD_ACCT_HASH; do
    [[ -n "${!v:-}" ]] || { echo "FATAL: ${v} not set" >&2; exit 1; }
done

SEED_FILE="/run/secrets/ctf_seed"
if [[ ! -f "$SEED_FILE" ]]; then
    echo "FATAL: ctf_seed secret not mounted at ${SEED_FILE}" >&2
    exit 1
fi
INSTANCE_SEED=$(cat "$SEED_FILE")

# ---- 1. Create low-privilege field_tech account --------------------------
log "Creating field_tech account..."
if ! id field_tech &>/dev/null; then
    adduser -D -s /bin/bash -h /home/field_tech field_tech
fi
echo "field_tech:${FIELD_ACCT_HASH}" | chpasswd -e
chmod 755 /home/field_tech

# ---- 2. Derive stage 2 flag ---------------------------------------------
log "Deriving stage 2 flag..."
FLAG_MSG="STAGE2:${ENGSTATION_ID}"
FLAG_HEX=$(echo -n "$FLAG_MSG" | \
    openssl dgst -sha256 -mac HMAC -macopt "hexkey:${INSTANCE_SEED}" | \
    awk '{print $NF}' | head -c 16)
STAGE2_FLAG="FLAG{S2-${FLAG_HEX}}"
mkdir -p /run/ctf
echo -n "$STAGE2_FLAG" > /run/ctf/stage2_flag
chmod 600 /run/ctf/stage2_flag
chmod 400 "$SEED_FILE"
log "Stage 2 flag stored securely (root-only) at /run/ctf/stage2_flag"

# ---- 3. Configure SSH ---------------------------------------------------
log "Configuring SSH server..."
sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
echo "AllowUsers field_tech" >> /etc/ssh/sshd_config
sed -i 's/X11Forwarding no/X11Forwarding yes/g' /etc/ssh/sshd_config
sed -i 's/^#X11Forwarding.*/X11Forwarding yes/' /etc/ssh/sshd_config
sed -i 's/^#X11UseLocalhost.*/X11UseLocalhost no/' /etc/ssh/sshd_config
sed -i 's/AllowTcpForwarding no/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
sed -i 's/^#AllowTcpForwarding.*/AllowTcpForwarding yes/' /etc/ssh/sshd_config

# ---- 4. Start OPC UA server in background --------------------------------
log "Starting asyncua OPC UA server..."
python3 /app/ews_server.py &

# ---- 4b. Start local flag oracle service ----------------------------------
log "Writing local flag oracle..."
cat > /app/flag_oracle.py << 'EOF'
import socket
import os
import hmac
import hashlib

def main():
    engstation_id = os.environ.get("ENGSTATION_ID")
    try:
        with open("/run/secrets/ctf_seed", "r") as f:
            seed = f.read().strip()
    except Exception:
        seed = ""

    if not engstation_id or not seed:
        return

    flag_msg = f"STAGE2:{engstation_id}"
    flag_hex = hmac.new(bytes.fromhex(seed), flag_msg.encode(), hashlib.sha256).hexdigest()[:16]
    flag = f"FLAG{{S2-{flag_hex}}}"

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 9002))
    server.listen(5)

    while True:
        try:
            conn, _ = server.accept()
            conn.sendall(b"Enter Stage 2 Workstation ProductUri: ")
            data = b""
            while b"\n" not in data and len(data) < 1024:
                chunk = conn.recv(1)
                if not chunk:
                    break
                data += chunk
            user_input = data.decode().strip()
            if user_input == engstation_id:
                conn.sendall(f"ACCESS GRANTED. Flag: {flag}\n".encode())
            else:
                conn.sendall(b"ACCESS DENIED. Incorrect ProductUri.\n")
            conn.close()
        except Exception:
            pass

if __name__ == "__main__":
    main()
EOF
python3 /app/flag_oracle.py &

# ---- 4c. Start local Stage 3 flag oracle service --------------------------
log "Writing local Stage 3 flag oracle..."
cat > /app/flag_oracle_s3.py << 'EOF'
import socket
import os
import hmac
import hashlib

def main():
    asdu_addr = os.environ.get("ASDU_ADDR_DESC")
    try:
        with open("/run/secrets/ctf_seed", "r") as f:
            seed = f.read().strip()
    except Exception:
        seed = ""

    if not asdu_addr or not seed:
        return

    flag_msg = f"STAGE3:{asdu_addr}"
    flag_hex = hmac.new(bytes.fromhex(seed), flag_msg.encode(), hashlib.sha256).hexdigest()[:16]
    flag = f"FLAG{{S3-{flag_hex}}}"

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 9003))
    server.listen(5)

    while True:
        try:
            conn, _ = server.accept()
            conn.sendall(b"Enter Stage 3 Artifact (ASDU Address Descriptor): ")
            data = b""
            while b"\n" not in data and len(data) < 1024:
                chunk = conn.recv(1)
                if not chunk:
                    break
                data += chunk
            user_input = data.decode().strip()
            if user_input == asdu_addr:
                conn.sendall(f"ACCESS GRANTED. Flag: {flag}\n".encode())
            else:
                conn.sendall(b"ACCESS DENIED. Incorrect ASDU Address.\n")
            conn.close()
        except Exception:
            pass

if __name__ == "__main__":
    main()
EOF
python3 /app/flag_oracle_s3.py &

# ---- 4d. Start local Stage 4 flag oracle service --------------------------
log "Writing local Stage 4 flag oracle..."
cat > /app/flag_oracle_s4.py << 'EOF'
import socket
import os
import hmac
import hashlib

def main():
    target_ioa = os.environ.get("TARGET_IOA")
    try:
        with open("/run/secrets/ctf_seed", "r") as f:
            seed = f.read().strip()
    except Exception:
        seed = ""

    if not target_ioa or not seed:
        return

    ioa_num = int(target_ioa)
    type_str = "C_SC_NA_1" if ioa_num % 2 != 0 else "C_DC_NA_1"
    expected_artifact = f"IOA:{ioa_num}:TYPE:{type_str}:ACK"

    flag_msg = f"STAGE4:{expected_artifact}"
    flag_hex = hmac.new(bytes.fromhex(seed), flag_msg.encode(), hashlib.sha256).hexdigest()[:16]
    flag = f"FLAG{{S4-{flag_hex}}}"

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 9004))
    server.listen(5)

    while True:
        try:
            conn, _ = server.accept()
            conn.sendall(b"Enter Stage 4 Artifact (e.g. IOA:1234:TYPE:C_SC_NA_1:ACK): ")
            data = b""
            while b"\n" not in data and len(data) < 1024:
                chunk = conn.recv(1)
                if not chunk:
                    break
                data += chunk
            user_input = data.decode().strip()
            if user_input == expected_artifact:
                conn.sendall(f"ACCESS GRANTED. Flag: {flag}\n".encode())
            else:
                conn.sendall(b"ACCESS DENIED. Incorrect RTU Artifact.\n")
            conn.close()
        except Exception:
            pass

if __name__ == "__main__":
    main()
EOF
python3 /app/flag_oracle_s4.py &

# ---- 5. Start SSH server in foreground ----------------------------------
log "Starting SSH server..."
exec /usr/sbin/sshd -D -e
