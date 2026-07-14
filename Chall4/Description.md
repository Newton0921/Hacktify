# Stage 4 — Remote Terminal Unit Simulator (SBO)

## Background
The adversary has successfully pivoted into the internal operational technology (OT) network. In this sector, the field devices communicate using the standard power utility telecontrol protocol: **IEC 60870-5-104 (IEC 104)**.

Your next objective is to interact with a Remote Terminal Unit (RTU) simulator executing at the IP address specified in your environment configuration (`RTU_IP=10.100.1.3`). This RTU monitors and controls critical grid functions. The substation operator has configured the command points with strict access controls to prevent accidental commands.

---

## Challenge Specifications
- **Target Endpoints:** TCP Port `2404` at `RTU_IP`.
- **Common Address (CA):** Fixed at `1`.
- **Point Range:** Spans `TARGET_IOA` to `IOA_END` (refer to `range.env` for your instance-specific range).
- **Point Configuration:**
  - Odd IOAs expect **Single Command** (`C_SC_NA_1` / ASDU 45).
  - Even IOAs expect **Double Command** (`C_DC_NA_1` / ASDU 46).
  - The points use **Select-Before-Operate (SBO)** (Select-and-Execute) mode.
  
---

## Rules of Engagement & Tripwires
The simulator implements realistic protocol checks and operator tripwires. Triggering these will alert operators and result in penalty warnings during assessment:
1. **Session Control:** You MUST activate the transmission session using **STARTDT** before sending any commands. Sending commands out-of-session triggers a tripwire alarm and disconnects the socket.
2. **Select-Before-Operate (SBO):** You cannot execute a command directly on these points. A command must be **Selected** first, and then **Executed** within the timeout period. Directly executing or executing a point without active selection triggers an alarm.
3. **Mismatched Command Types:** Sending a Single Command to an Even IOA, or a Double Command to an Odd IOA, triggers a `malformed type-for-IOA` alarm.
4. **Out-of-Range Scanning:** Addresses outside the target range (`TARGET_IOA..IOA_END`) do not exist. Any attempt to connect or send commands to these addresses is dropped silently by the RTU's firewall (TCP proxy), leading to a connection timeout. Naive port/IP scanning will be slow and loud.

---

## Objective
Establish a session, find the correct active IOA, and perform a successful **Select-then-Execute** sequence. The first successful execution toggles the point state, generates the CTF flag, and stores it on the server at `/run/ctf/stage4_flag`.

Good luck.
