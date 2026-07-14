# Artifact Contract — Prabal Urja Pvt Ltd Range

| Artifact | Generation | Delivered to | Env var |
|---|---|---|---|
| INSTANCE_SEED | `openssl rand -hex 32` | all containers | Podman secret `ctf_seed` |
| Zone subnets + container IPs | derived from `RANGE_BASE_CIDR` | all containers | `PUBLIC_ZONE_SUBNET`, `OT_ZONE_SUBNET`, `STATION_ZONE_SUBNET`, `PROCESS_ZONE_SUBNET` + per-container `*_IP` vars |
| field_tech account hash | salt derived from INSTANCE_SEED | vpn-gateway | `FIELD_ACCT_HASH` |
| Engineering endpoint identifier | random per instance | ews-node | `ENGSTATION_ID` |
| Facility namespace prefix | random plausible fictional label | historian-srv | `TAG_NAMESPACE_PREFIX` |
| RTU config string | random offset within safe range | historian-srv + rtu-server | `ASDU_ADDR_DESC`, `TARGET_IOA`, `IOA_END` |
| SCIL expected IOA | same as TARGET_IOA | bay-controller | `SCIL_EXPECTED_IOA` |
| GOOSE confRev / APPID | random per instance | bay-controller | `GOOSE_CONF_REV`, `GOOSE_APPID` |

## Flag Precomputability

| Flag | Stage | Precomputable at Provision | Description |
|---|---|---|---|
| S1 | 1 | Yes | Gateway credential file access |
| S2 | 2 | Yes | Engineering workstation pivot |
| S3 | 3 | Yes | Historian data extraction |
| S4 | 4 | Yes | RTU protocol manipulation |
| S4b | 4 | No (lazy) | Bay controller lateral move |
| S5A | 5 | No (lazy) | Process zone initial access |
| S5B | 5 | No (lazy) | Process zone objective |
