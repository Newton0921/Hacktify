#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# vpn-gateway entrypoint — Stage 1
# Reads all config from environment variables, never hardcodes IPs/subnets.
# ===========================================================================

log() { echo "[vpn-gw] $(date '+%H:%M:%S') $*"; }

# ---- Validate required env vars ------------------------------------------
for v in PUBLIC_ZONE_SUBNET PUBLIC_ZONE_GATEWAY_IP FIELD_ACCT_HASH VPN_SUBNET; do
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

# ---- 2. Write field_accounts.conf (realistic misconfig) ------------------
log "Writing field_accounts.conf..."
ACCT_LINE="field_tech:${FIELD_ACCT_HASH}:19000:0:99999:7:::"
mkdir -p /etc/openvpn/server
echo "$ACCT_LINE" > /etc/openvpn/server/field_accounts.conf
# Misconfig: readable by field_tech (requires SSH auth first)
chown field_tech:field_tech /etc/openvpn/server/field_accounts.conf
chmod 640 /etc/openvpn/server/field_accounts.conf

# ---- 3. Derive stage 1 flag ---------------------------------------------
log "Deriving stage 1 flag..."
FLAG_MSG="STAGE1:${ACCT_LINE}"
FLAG_HEX=$(echo -n "$FLAG_MSG" | \
    openssl dgst -sha256 -mac HMAC -macopt "hexkey:${INSTANCE_SEED}" | \
    awk '{print $NF}' | head -c 16)
STAGE1_FLAG="FLAG{S1-${FLAG_HEX}}"
mkdir -p /run/ctf
echo -n "$STAGE1_FLAG" > /run/ctf/stage1_flag
chmod 600 /run/ctf/stage1_flag
chmod 400 "$SEED_FILE"
log "Stage 1 flag stored securely (root-only) at /run/ctf/stage1_flag"

# ---- 4. Set up self-signed CA and OpenVPN server -------------------------
log "Generating PKI for OpenVPN..."
EASYRSA_DIR="/etc/openvpn/easy-rsa"
mkdir -p "$EASYRSA_DIR"
cd "$EASYRSA_DIR"

# Locate the easy-rsa script
EASYRSA_BIN=$(command -v easyrsa || echo "/usr/share/easy-rsa/easyrsa")
if [[ ! -x "$EASYRSA_BIN" ]]; then
    # Try common alpine paths
    for p in /usr/share/easy-rsa/easyrsa /usr/bin/easyrsa; do
        [[ -x "$p" ]] && EASYRSA_BIN="$p" && break
    done
fi

export EASYRSA_PKI="$EASYRSA_DIR/pki"
export EASYRSA_BATCH=1
export EASYRSA_REQ_CN="PrabalUrja-Lab-CA"

"$EASYRSA_BIN" init-pki
"$EASYRSA_BIN" build-ca nopass
# Unset REQ_CN after CA creation — it conflicts with build-*-full commands
unset EASYRSA_REQ_CN
"$EASYRSA_BIN" gen-dh
"$EASYRSA_BIN" build-server-full vpn-server nopass
"$EASYRSA_BIN" build-client-full vpn-client nopass

# Generate TLS auth key
openvpn --genkey secret /etc/openvpn/server/ta.key

# ---- 5. Write OpenVPN server config -------------------------------------
# Extract network and mask from CIDR for OpenVPN "server" directive
IFS='/' read -r NET_ADDR NET_PREFIX <<< "$VPN_SUBNET"
# Compute netmask from prefix
MASK_INT=$(( 0xFFFFFFFF << (32 - NET_PREFIX) & 0xFFFFFFFF ))
NETMASK="$(( (MASK_INT >> 24) & 255 )).$(( (MASK_INT >> 16) & 255 )).$(( (MASK_INT >> 8) & 255 )).$(( MASK_INT & 255 ))"

cat > /etc/openvpn/server/server.conf <<OVPNCFG
port 1194
proto udp
dev tun
ca   ${EASYRSA_PKI}/ca.crt
cert ${EASYRSA_PKI}/issued/vpn-server.crt
key  ${EASYRSA_PKI}/private/vpn-server.key
dh   ${EASYRSA_PKI}/dh.pem
tls-auth /etc/openvpn/server/ta.key 0
server ${NET_ADDR} ${NETMASK}
ifconfig-pool-persist /etc/openvpn/server/ipp.txt
keepalive 10 120
cipher AES-256-GCM
persist-key
persist-tun
status /var/log/openvpn-status.log
log-append /var/log/openvpn.log
verb 3
OVPNCFG

# ---- 6. Generate distributable .ovpn client profile ---------------------
log "Generating client .ovpn profile..."
mkdir -p /etc/openvpn/client
cat > /etc/openvpn/client/client-connect.ovpn <<CLIENTCFG
client
dev tun
proto udp
remote ${PUBLIC_ZONE_GATEWAY_IP} 1194
resolv-retry infinite
nobind
persist-key
persist-tun
cipher AES-256-GCM
key-direction 1
verb 3
<ca>
$(cat "${EASYRSA_PKI}/ca.crt")
</ca>
<cert>
$(cat "${EASYRSA_PKI}/issued/vpn-client.crt")
</cert>
<key>
$(cat "${EASYRSA_PKI}/private/vpn-client.key")
</key>
<tls-auth>
$(cat /etc/openvpn/server/ta.key)
</tls-auth>
CLIENTCFG

# ---- 7. Configure SSH ---------------------------------------------------
log "Configuring SSH server..."
sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
echo "AllowUsers field_tech" >> /etc/ssh/sshd_config

# ---- 8. CEF logging on flag file access ----------------------------------
# Use inotifywait if available, else a lightweight watcher
log "Setting up CEF audit logging..."
mkdir -p /var/log/ctf
(
    while true; do
        inotifywait -q -e access /etc/openvpn/server/field_accounts.conf 2>/dev/null && \
        echo "CEF:0|PrabalUrja|RangeMonitor|1.0|FILE_ACCESS|field_accounts.conf accessed|5|src=field_tech dst=/etc/openvpn/server/field_accounts.conf dvchost=vpn-gateway rt=$(date '+%b %d %H:%M:%S %Y')" \
            >> /var/log/ctf/range_events.cef
        sleep 1
    done
) &

# ---- 8b. Start local flag oracle service ----------------------------------
log "Writing local flag oracle..."
mkdir -p /app
cat > /app/flag_oracle.py << 'EOF'
import socket
import hmac
import hashlib

def main():
    try:
        with open("/etc/openvpn/server/field_accounts.conf", "r") as f:
            actual_artifact = f.read().strip()
    except Exception:
        actual_artifact = ""

    try:
        with open("/run/secrets/ctf_seed", "r") as f:
            seed = f.read().strip()
    except Exception:
        seed = ""

    if not actual_artifact or not seed:
        return

    flag_msg = f"STAGE1:{actual_artifact}"
    flag_hex = hmac.new(bytes.fromhex(seed), flag_msg.encode(), hashlib.sha256).hexdigest()[:16]
    flag = f"FLAG{{S1-{flag_hex}}}"

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 9001))
    server.listen(5)

    while True:
        try:
            conn, _ = server.accept()
            conn.sendall(b"Enter Stage 1 Artifact (content of field_accounts.conf): ")
            data = b""
            while b"\n" not in data and len(data) < 1024:
                chunk = conn.recv(1)
                if not chunk:
                    break
                data += chunk
            user_input = data.decode().strip()
            if user_input == actual_artifact:
                conn.sendall(f"ACCESS GRANTED. Flag: {flag}\n".encode())
            else:
                conn.sendall(b"ACCESS DENIED. Incorrect artifact.\n")
            conn.close()
        except Exception:
            pass

if __name__ == "__main__":
    main()
EOF
python3 /app/flag_oracle.py &

# ---- 9. Start services ---------------------------------------------------
log "Starting OpenVPN server..."
openvpn --config /etc/openvpn/server/server.conf --daemon

log "Starting SSH server (foreground)..."
exec /usr/sbin/sshd -D -e
