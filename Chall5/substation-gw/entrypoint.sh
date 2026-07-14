#!/usr/bin/env bash
set -euo pipefail

# Print startup log
echo "[substation-gw] Starting up..."

# Ensure required env vars are present
for v in FIELD_ACCT_HASH INSTANCE_SEED; do
    if [[ -z "${!v:-}" ]]; then
        echo "FATAL: ${v} not set" >&2
        exit 1
    fi
done

# Create field_tech user
if ! id field_tech &>/dev/null; then
    adduser -D -s /bin/bash -h /home/field_tech field_tech
fi
echo "field_tech:${FIELD_ACCT_HASH}" | chpasswd -e
chmod 755 /home/field_tech

# Configure passwordless sudo for field_tech for python3 and tcpdump
echo "field_tech ALL=(ALL) NOPASSWD: /usr/bin/python3, /usr/sbin/tcpdump" >> /etc/sudoers

# Configure SSH server
sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
echo "AllowUsers field_tech" >> /etc/ssh/sshd_config

# Generate host keys
ssh-keygen -A

# Wait for interfaces to stabilize, then calculate stage 4b flag
(
    # Find the process-zone interface (the one connected to 10.100.3.0/24 subnet)
    IFACE=""
    echo "[substation-gw] Waiting for process-zone interface to attach..."
    for _ in {1..30}; do
        for i in $(ls /sys/class/net/); do
            if [[ "$i" != "lo" && "$i" != "eth0" ]]; then
                IFACE="$i"
                break
            fi
        done
        [[ -n "$IFACE" ]] && break
        sleep 1
    done
    
    if [[ -z "$IFACE" ]]; then
        IFACE="eth1"
    fi
    
    MAC_ADDR=$(cat "/sys/class/net/${IFACE}/address" | tr -d '\n' | tr 'A-Z' 'a-z')
    echo "[substation-gw] Process zone interface ${IFACE} has MAC ${MAC_ADDR}"
    
    FLAG_MSG="STAGE4b:${MAC_ADDR}"
    FLAG_HEX=$(echo -n "$FLAG_MSG" | \
        openssl dgst -sha256 -mac HMAC -macopt "hexkey:${INSTANCE_SEED}" | \
        awk '{print $NF}' | head -c 16)
    STAGE4B_FLAG="FLAG{S4b-${FLAG_HEX}}"
    
    mkdir -p /run/ctf
    echo -n "$STAGE4B_FLAG" > /run/ctf/stage4b_flag
    chmod 600 /run/ctf/stage4b_flag
    echo "[substation-gw] Stage 4b flag stored securely at /run/ctf/stage4b_flag"
) &

# Run SSH server in foreground
exec /usr/sbin/sshd -D -e
