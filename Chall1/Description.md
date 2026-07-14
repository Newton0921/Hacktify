# Stage 1 — Remote Access Gateway

## Scenario

Prabal Urja Pvt Ltd has engaged your team for an authorized adversary simulation of their power distribution network. The external perimeter features a Linux-based remote access gateway deployed in the DMZ network, serving field technicians and external vendors. Since direct external access to internal environments is restricted, the red teamer's first priority is to establish an initial foothold on this gateway. Resolving this foothold is critical to discovering the authentication mechanisms and network pivots that allow legitimate operators to transition deeper into the facility's internal segments.

## Objective

- Gain authenticated access to the remote access gateway
- Locate credential material that reveals how trusted parties authenticate
- Extract the evidence artifact and retrieve the stage flag (stored at /run/ctf/stage1_flag inside the gateway, or retrieved via the local oracle)

## Connection Information

| Service | Address |
|---------|---------|
| SSH     | `<PARTICIPANT_SSH_ENDPOINT>` (provided per-instance) |
| OpenVPN | Client profile delivered out-of-band |

> Connection details are unique per participant instance. Your instructor
> will provide the specific endpoint address and any required client
> configuration files.

## Flag Format

```
flag{S1-<16 hex characters>}
```

## Points

| Objective | Points |
|-----------|--------|
| Gateway foothold via credential reuse | 100 |

## Rules of Engagement

- This is an **authorized** simulation — stay within the defined scope
- Only the remote access gateway is in scope for this stage
- Do not attempt to pivot beyond this stage's target until instructed
- Document all actions taken for after-action review
