# Stage 3 — Historian Data Extraction

## Scenario

After successfully pivoting through the Linux engineering workstation, you have gained access to the private OT network segment of Prabal Urja Pvt Ltd. From this vantage point, the red teamer identifies a central data historian archiving process measurements and configuration variables across the plant floor. Enumerating this data historian is a critical step to locating privileged configuration values and device descriptors that dictate how telemetry is exchanged with field controllers in the process zone.

## Objective

- Connect to the OPC UA historian service from the pivoted position
- Navigate the full namespace hierarchy (multiple levels deep)
- Identify the node that describes a specific remote equipment address
- Extract the evidence artifact and retrieve the stage flag (stored inside the historian container at /run/ctf/stage3_flag, or retrieved via the local oracle on the pivoted workstation)

## Connection Information

| Service  | Address |
|----------|---------|
| OPC UA   | `opc.tcp://<HISTORIAN_IP>:4840/prabalurja/historian` (provided per-instance) |

> Connection details are unique per participant instance. The historian
> service is reachable from the private OT zone after establishing the VPN tunnel
> and pivoting through prior stages.

## Flag Format

```
FLAG{S3-<16 hex characters>}
```

## Points

| Objective | Points |
|-----------|--------|
| Historian namespace harvest + privileged tag identification | 200 |

## Rules of Engagement

- This is an **authorized** simulation — stay within the defined scope
- Only the historian service on port 4840 is in scope for this stage
- Do not modify or write to any OPC UA nodes
- Document all actions taken for after-action review
