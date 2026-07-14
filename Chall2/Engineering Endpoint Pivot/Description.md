# Stage 2 — Engineering Endpoint Pivot

## Scenario

Having successfully compromised the remote access gateway at Prabal Urja Pvt Ltd, you find yourself on a boundary host between the DMZ and the internal networks. To advance, the red teamer must pivot from this initial foothold into the private workstation segment. The target is a dual-homed Linux engineering workstation that bridges the operator workstation subnet and the local OT process network. Identifying and compromising this workstation is essential to bridging the network gap and accessing internal controller telemetry.

## Objective

- Scan and locate the engineering workstation on the internal zone network.
- Pivot through the gateway using Stage 1's obtained credentials to access the workstation.
- Interact with the exposed OPC UA service on the engineering workstation.
- Extract the identifying field (`ProductUri`) from the server status `BuildInfo` node.
- Retrieve the stage flag (stored at /run/ctf/stage2_flag inside the workstation, or retrieved via the local oracle)

## Connection Information

| Service | Address |
|---------|---------|
| SSH     | `<PARTICIPANT_EWS_PUBLIC_IP>` (reachable from the gateway/public zone) |
| OPC UA  | `<PARTICIPANT_EWS_OT_IP>:4840` (only bound to the internal network interface) |

> Note: Connection details are dynamic. You must find the workstation's IP addresses by inspecting the network interface configurations and route tables on the gateway, or by performing internal network scanning.

## Flag Format

```
FLAG{S2-<16 hex characters>}
```

## Points

| Objective | Points |
|-----------|--------|
| Pivot to OT-zone and fingerprint EWS OPC UA service | 150 |

## Rules of Engagement

- This is an **authorized** simulation — stay within the defined scope.
- Do not attempt to pivot beyond the engineering workstation until instructed.
- Ensure all actions are logged for the after-action review.
