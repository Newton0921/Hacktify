# Stage 1 — VPN Gateway (Operator Guide)

## Overview

This challenge deploys a **vpn-gateway** container representing the externally
reachable remote access appliance for Prabal Urja Pvt Ltd's power distribution
network. It is the entry point for the 5-stage red-team range.

## Prerequisites

- **Podman** ≥ 4.0 with rootless or rootful access
- **/dev/net/tun** available on the host
- **Python 3** with `openpyxl` (for Assessment.xlsx generation)
- **openssl** CLI
- **sshpass** (optional, for automated validation)

## Quick Start

### 1. First-Time Provisioning

```bash
# Supply a CIDR block large enough for 4 zone subnets (minimum /22 for 4× /24)
chmod +x setup.sh chall_reset.sh red_attack_script.sh
sudo ./setup.sh 10.100.0.0/22
```

This performs **master provisioning**:

1. Subdivides `RANGE_BASE_CIDR` into 4 zone subnets:
   - `PUBLIC_ZONE_SUBNET` → vpn-gateway
   - `OT_ZONE_SUBNET` → historian, RTU (Stages 3-4)
   - `STATION_ZONE_SUBNET` → engineering workstation (Stage 2)
   - `PROCESS_ZONE_SUBNET` → bay controller (Stage 5, macvlan)
2. Generates `INSTANCE_SEED` and creates Podman secret `ctf_seed`
3. Derives all per-instance artifacts (field_tech hash, engineering
   station ID, namespace prefix, RTU config, GOOSE params)
4. Writes `../shared/range.env` and per-container env files
5. Builds and starts the vpn-gateway container

### 2. Subsequent Runs

```bash
# Uses existing range.env — no CIDR argument needed
sudo ./setup.sh
```

### 3. Reset (Preserve Seed)

```bash
sudo ./chall_reset.sh
```

### 4. Full Re-Provision (Rotate Seed)

```bash
# WARNING: Requires re-running ALL 5 challenges' setup.sh afterwards
sudo ./chall_reset.sh --rotate-seed 10.100.0.0/22
```

## How Zone Subnets Propagate to Stages 2–5

The `range.env` file in `../shared/` is the **single source of truth** for all
network addressing. Every stage's `setup.sh` reads from this file:

| Stage | Container(s) | Zone Subnet Env Var | Container IP Env Var |
|-------|-------------|---------------------|---------------------|
| 1 | vpn-gateway | `PUBLIC_ZONE_SUBNET` | `PUBLIC_ZONE_GATEWAY_IP` |
| 2 | ews-node | `STATION_ZONE_SUBNET` | `EWS_IP` |
| 3 | historian-srv | `OT_ZONE_SUBNET` | `HISTORIAN_IP` |
| 4 | rtu-server, bay-controller | `OT_ZONE_SUBNET`, `PROCESS_ZONE_SUBNET` | `RTU_IP`, `BAY_CONTROLLER_IP` |
| 5 | bay-controller | `PROCESS_ZONE_SUBNET` | `BAY_CONTROLLER_IP` |

**No stage container generates its own subnet or random artifacts at runtime.**
All values are pre-computed by Stage 1's provisioner.

## File Inventory

| File | Purpose |
|------|---------|
| `setup.sh` | Master provisioner + Stage 1 deployment |
| `chall_reset.sh` | Tear down and redeploy vpn-gateway |
| `Description.md` | Player-facing challenge description |
| `briefing.md` | Player-facing mission brief (verbatim) |
| `Red-Writeup.md` | Instructor solve walkthrough |
| `red_attack_script.sh` | Automated validation/scoring script |
| `service_availability_ttp.yaml` | Health check definitions |
| `setup_ttp.yaml` | Deployment metadata for platform |
| `Assessment.xlsx` | Scoring spreadsheet |
| `generate_assessment.py` | Script to regenerate Assessment.xlsx |
| `vpn-gateway/Dockerfile` | Container image definition |
| `vpn-gateway/entrypoint.sh` | Container startup logic |
| `vpn-gateway/podman-compose.fragment.yml` | Compose service definition |
| `podman-compose.yml` | Top-level compose (all stages) |

## Validation

```bash
sudo ./red_attack_script.sh
```

This connects to the gateway, extracts the artifact, independently computes
the flag, and verifies it matches the stored value.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `range.env not found` | Run `setup.sh` with a CIDR argument first |
| Container won't start | Check `podman logs vpn-gateway` |
| SSH refused on 2222 | Container may still be initializing (PKI gen takes ~10s) |
| Flag mismatch | Verify seed hasn't been rotated without redeploying |
| Network conflict | Choose a different RANGE_BASE_CIDR |
