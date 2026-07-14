# Stage 2 — Red Team Writeup (Instructor-Facing)

## Challenge: Engineering Workstation Pivot & OPC UA Information Disclosure

### Overview

The `ews-node` container simulates an Engineering Workstation (EWS) within Prabal Urja Pvt Ltd's environment. In a typical industrial control system (ICS) environment, engineering workstations are highly privileged systems used by control engineers to program PLCs, configure RTUs, and monitor processes.

In this lab, the workstation is configured with a dual-homed network architecture:
1. **Public Zone interface** — Accessible from the remote access gateway, exposing an OpenSSH server (22/TCP) to allow technicians command-line access.
2. **Station/OT Zone interface** — Connected directly to the control network, running an `asyncua`-based OPC UA server (4840/TCP).

The objective of Stage 2 is to pivot from the remote access gateway to the engineering workstation using the credentials obtained in Stage 1, discover the local OPC UA service listening on the OT-zone interface, query the server status `BuildInfo` node, extract the workstation identifier (`ProductUri`), and compute the stage flag.

---

### Why This Works — Design Rationale & Vulnerability Breakdown

1. **Dual-Homed Network Architecture (T0886 - Lateral Tool Transfer):**
   In segmented industrial environments, workstations are frequently dual-homed to bridge the management/remote access zone and the process/control zone. While this configuration facilitates maintenance, it introduces a major security hazard. If the workstation is compromised via its management interface (SSH), an adversary can use it as a pivot point to bypass boundary controls and interact directly with control-zone services (OPC UA, Modbus, DNP3) that are not otherwise accessible.

2. **Credential Reuse (T0859 - Valid Accounts):**
   The workstation uses the same low-privilege `field_tech` account and shadow hash as the gateway. This simulates real-world environments where organization-wide account credentials or local administrative accounts are reused across multiple endpoints and servers, allowing compromised credentials from a boundary gateway to unlock internal engineering assets.

3. **Anonymous OPC UA Browse & Read Access (T0888 - Cloud Service Discovery):**
   The OPC UA server allows anonymous clients to connect, browse the node tree, and read variables. While modern specifications recommend enforcing certificate-based or username/password authentication for OPC UA endpoints, industrial environments often disable authentication to simplify vendor integrations or legacy client compatibility.

4. **Information Disclosure via Server BuildInfo (T0846 - Resource Development):**
   The OPC UA specification defines a standard `ServerStatus` structure under Namespace 0 containing a `BuildInfo` node. In this lab, the server populates the `ProductUri` field with the workstation's unique asset identifier (`ENGSTATION_ID`). Accessing standard server status nodes allows an attacker to fingerprint the workstation identity, software versions, and internal asset namespaces without triggering specialized application-layer alarms.

---

### Intended Solve Path (Step-by-Step)

#### Step 1: Internal Routing & Host Discovery
The player begins on the compromised `vpn-gateway` from Stage 1. They inspect the local routing tables and interface settings to discover adjacent subnets.

**Command:**
```bash
ip route
```

**Expected Output:**
```text
default via 10.100.0.1 dev eth0 
10.100.0.0/24 dev eth0 proto kernel scope link src 10.100.0.2 
```
The gateway shows connectivity to the `10.100.0.0/24` subnet. Since the player is targeting internal operations, they perform a sweep of the subnet to locate active hosts.

**Command:**
```bash
for ip in $(seq 1 254); do ping -c 1 -W 1 10.100.0.$ip >/dev/null && echo "10.100.0.$ip is UP"; done
```

**Expected Output:**
```text
10.100.0.1 is UP
10.100.0.2 is UP
10.100.0.3 is UP
```
The IP `10.100.0.3` corresponds to the workstation's public-facing interface.

---

#### Step 2: Pivoting via SSH
Using the credentials harvested from Stage 1 (`field_tech` / `FieldTech2024!`), the player logs into the workstation from the gateway:

**Command:**
```bash
ssh field_tech@10.100.0.3
```

**Interaction Flow:**
```text
field_tech@10.100.0.2's password: FieldTech2024!
Welcome to Alpine Linux 3.20!
ews-node:~$ 
```

---

#### Step 3: Local Port Scan and Interface Audit
Once logged in, the player audits the workstation's interfaces and listening ports to find what services it runs and what networks it communicates with.

**Command:**
```bash
ip addr
```

**Expected Output:**
```text
...
2: eth0@if12: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...
    inet 10.100.0.3/24 brd 10.100.0.255 scope global eth0
3: eth1@if13: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...
    inet 10.100.2.2/24 brd 10.100.2.255 scope global eth1
```
The workstation is indeed dual-homed: `eth0` is on the public subnet (`10.100.0.3`), while `eth1` is on the Station/OT zone network (`10.100.2.2`).

**Command:**
```bash
ss -ltun
```

**Expected Output:**
```text
Netid  State   Recv-Q  Send-Q     Local Address:Port      Peer Address:Port  Process
tcp    LISTEN  0       128              0.0.0.0:22             0.0.0.0:*
tcp    LISTEN  0       128           10.100.2.2:4840           0.0.0.0:*
```
SSH is listening on all interfaces, but port `4840` (OPC UA) is bound exclusively to the OT-zone IP (`10.100.2.2`). It cannot be queried directly from the gateway or the VPN client.

---

#### Step 4: Interacting with OPC UA
Since the player has established a VPN connection to the network (from Stage 1) and identified that the Engineering Workstation is listening on port `4840` at `10.100.2.2`, they can connect to the OPC UA server directly from their host/VPN client machine using an OPC UA client such as `opcua-client`.

**Steps to extract the Workstation ID:**
1. Start the OPC UA client tool on your machine:
   ```bash
   opcua-client
   ```
2. In the connection URI field, enter the server endpoint:
   `opc.tcp://10.100.2.2:4840/freeopcua/server/` and click **Connect**.
3. Once connected, browse the address space on the left pane:
   - Navigate to `Root` -> `Objects` -> `Server` -> `ServerStatus` -> `BuildInfo`.
4. Click on the node `ProductUri` (NodeId `i=2262`).
5. On the attributes panel on the right, read the **Value** attribute (e.g. `EWS-3875768C-034`).

The workstation ID (e.g. `EWS-3875768C-034`) is the **evidence artifact** for Stage 2.

---

#### Step 5: Final Flag Retrieval Walkthrough

Because the player-facing environment runs on the target, the final computed flag is retrieved by connecting to the local flag oracle service on port 9002 and providing the correct Stage 2 workstation identifier.

**Retrieval (from EWS shell)**
Once you have pivoted and obtained a shell on the engineering workstation, connect to the local oracle:
Command:
```bash
nc 127.0.0.1 9002
```

When prompted, enter the ProductUri extracted in Step 4.

Expected output:
```text
Enter Stage 2 Workstation ProductUri: EWS-B7FA-142
ACCESS GRANTED. Flag: FLAG{S2-8c10fa2e3bc01b44}
```

---

### Instructor Verification & Grading

Instructors can run the automated validation script on the host to check the environment's health:

```bash
./red_attack_script.sh
```

**What the grading script does:**
1. Verifies SSH port 22 is open on EWS's public IP (`10.100.0.3`).
2. SSHs into the EWS node (or uses `podman exec` fallback if `sshpass` is missing).
3. Writes the python solver script to EWS and executes it locally.
4. Reads the local `INSTANCE_SEED` from `/home/newton/Hacktify/OT/SET 2/Hacktify/shared/range.env`.
5. Recomputes the HMAC-SHA256 flag.
6. Reads `/run/ctf/stage2_flag` inside `ews-node` and diffs the computed vs. stored flag.

---

### Troubleshooting Common Lab Issues

| Problem | Potential Cause | Resolution |
|---|---|---|
| **EWS IP not reachable from Gateway** | `public_zone_net` bridge network or container routing table broken. | Verify the container status: `podman ps -a`. Inspect networks: `podman network inspect public_zone_net`. Redeploy: `./chall_reset.sh`. |
| **OPC UA connection fails** | OPC UA server script crashed or failed to bind to `EWS_IP`. | Inspect container logs: `podman logs ews-node`. Verify that the `ews-node` container is connected to `station_zone_net` and holds the correct IP. |
| **Python asyncua module missing** | PIP installation failed during build time. | Ensure the build host has outbound internet access during container build, or check local python dependencies. Run `podman exec -it ews-node pip list` to check. |























































1. Confirm Challenge 2 is running

On your Parrot host terminal:

sudo podman ps --filter name=ews-node

You should see ews-node in the Up state.

2. Confirm the Engineering Workstation IP

For your current setup:

EWS public IP: 10.100.0.3
EWS OT IP:     10.100.2.2

Test SSH:

nc -vz 10.100.0.3 22

Expected:

10.100.0.3 22 open
3. SSH into the Engineering Workstation
ssh field_tech@10.100.0.3

Password:

FieldTech2024!

If you get a host-key warning after the reset:

ssh-keygen -f "$HOME/.ssh/known_hosts" -R '10.100.0.3'

Then reconnect.

Expected prompt:

ews-node:~$
4. Verify the OT interface and OPC UA service

Inside ews-node:

ip addr show

You should see:

eth0: 10.100.0.3/24
eth1: 10.100.2.2/24

Check OPC UA:

nc -vz 10.100.2.2 4840

Expected:

10.100.2.2:4840 open

Then exit back to Parrot:

exit
Connect using FreeOpcUa Client
5. Add the OT address temporarily to Parrot loopback

On Parrot:

sudo ip addr add 10.100.2.2/32 dev lo

If it says the address already exists, continue.

Verify:

ip addr show dev lo | grep 10.100.2.2
6. Create the SSH tunnel

Run:

ssh -N \
  -o ExitOnForwardFailure=yes \
  -L 10.100.2.2:4840:10.100.2.2:4840 \
  field_tech@10.100.0.3

Password:

FieldTech2024!

The terminal will appear blank. That means the tunnel is running correctly.

Keep this terminal open.

7. Verify the tunnel

Open a second Parrot terminal:

nc -vz 10.100.2.2 4840

Expected:

Connection to 10.100.2.2 4840 port succeeded

Check the listener:

sudo ss -lntp | grep '10.100.2.2:4840'

You should see an ssh process.

8. Open FreeOpcUa Client

In the second terminal:

opcua-client

Ignore the graph warning about pyqtgraph or numpy.

In the address field, enter:

opc.tcp://10.100.2.2:4840/freeopcua/server/

Click Connect options and use:

Security Policy: None
Security Mode: None
Authentication: Anonymous

Then click Connect.

9. Browse to ProductUri

Expand:

Objects
└── Server
    └── ServerStatus
        └── BuildInfo
            └── ProductUri

Click ProductUri.

In the right-side Attributes panel, find:

Value

The correct value should now look like:

EWS-XXXXXXXX-XXX

For example:

EWS-3875768C-034