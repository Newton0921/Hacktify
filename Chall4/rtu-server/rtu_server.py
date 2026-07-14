#!/usr/bin/env python3
"""
rtu_server.py — IEC-104 Remote Terminal Unit Simulator.

Architecture:
  - c104 Server:  127.0.0.1:24040  (internal, managed by c104 library)
  - TCP Proxy:    0.0.0.0:2404     (public-facing, this code)

The proxy:
  - Accepts public client connections.
  - Immediately opens a fresh connection to 127.0.0.1:24040 per client.
  - Forwards ALL U-frames (STARTDT/STOPDT/TESTFR) and S-frames unchanged.
  - For I-frames: only inspects Type ID 45 / 46 (C_SC_NA_1 / C_DC_NA_1)
    and applies IOA range filtering + type checking.
  - Logs every significant event with a timestamp.
"""
import c104
import os
import sys
import select
import socket
import struct
import threading
import time
import datetime
import hmac
import hashlib
import json
from http.server import HTTPServer, BaseHTTPRequestHandler

# ---------------------------------------------------------------------------
# Configuration from environment (with defaults)
# ---------------------------------------------------------------------------
TARGET_IOA     = int(os.environ.get("TARGET_IOA", 2947))
IOA_END        = int(os.environ.get("IOA_END",    3146))
RTU_IP         = os.environ.get("RTU_IP",          "0.0.0.0")
INSTANCE_SEED  = os.environ.get("INSTANCE_SEED",
                                "87d3b0becdb17de6394cad3d787f7b15b2fed6d3faf35b812649c4338a7e2df7")
LOG_FILE       = os.environ.get("LOG_FILE",        "/var/log/rtu-server.log")

INTERNAL_HOST  = "127.0.0.1"
INTERNAL_PORT  = 24040
PUBLIC_PORT    = 2404

# IEC-104 command Type IDs subject to IOA range filtering
FILTERED_TYPES = {45, 46}   # C_SC_NA_1, C_DC_NA_1

# ---------------------------------------------------------------------------
# HMI HTML Panel Design & Server
# ---------------------------------------------------------------------------
HMI_STATE = {
    "device_name": "Feeder Breaker (Masked)",
    "ioa": "••••",
    "state": "CLOSED",
    "power_flow": "ON",
    "indicator": "GREEN",
    "last_operation": "None",
    "last_op_timestamp": "None",
    "last_op_type": "None"
}

HMI_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Substation HMI - Bay Breaker Control Panel</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;600;800&family=Orbitron:wght@400;700;900&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg-color: #0b0f19;
            --panel-bg: rgba(17, 25, 40, 0.75);
            --panel-border: rgba(255, 255, 255, 0.08);
            --text-primary: #f8fafc;
            --text-secondary: #94a3b8;
            --color-closed: #10b981;
            --color-closed-glow: rgba(16, 185, 129, 0.4);
            --color-tripped: #ef4444;
            --color-tripped-glow: rgba(239, 68, 68, 0.4);
            --color-line: #334155;
            --color-line-glow: rgba(51, 65, 85, 0);
        }

        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }

        body {
            background-color: var(--bg-color);
            background-image: 
                radial-gradient(at 50% 0%, rgba(20, 30, 55, 0.5) 0px, transparent 50%),
                linear-gradient(rgba(255, 255, 255, 0.01) 1px, transparent 1px),
                linear-gradient(90deg, rgba(255, 255, 255, 0.01) 1px, transparent 1px);
            background-size: 100% 100%, 40px 40px, 40px 40px;
            color: var(--text-primary);
            font-family: 'Inter', sans-serif;
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            justify-content: center;
            align-items: center;
            overflow-x: hidden;
            padding: 20px;
        }

        .hmi-container {
            width: 100%;
            max-width: 900px;
            background: var(--panel-bg);
            backdrop-filter: blur(12px);
            border: 1px solid var(--panel-border);
            border-radius: 16px;
            padding: 40px;
            box-shadow: 0 20px 50px rgba(0, 0, 0, 0.5);
            display: grid;
            grid-template-columns: 1.2fr 1fr;
            gap: 40px;
            position: relative;
            overflow: hidden;
        }

        .hmi-container::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            height: 4px;
            background: linear-gradient(90deg, #3b82f6, #1d4ed8);
        }

        .hmi-left {
            display: flex;
            flex-direction: column;
            justify-content: space-between;
        }

        .hmi-header {
            margin-bottom: 30px;
        }

        .hmi-header h1 {
            font-family: 'Orbitron', sans-serif;
            font-size: 1.8rem;
            font-weight: 900;
            letter-spacing: 2px;
            background: linear-gradient(135deg, #3b82f6, #60a5fa);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            text-transform: uppercase;
        }

        .hmi-header p {
            color: var(--text-secondary);
            font-size: 0.9rem;
            margin-top: 5px;
            letter-spacing: 1px;
            text-transform: uppercase;
        }

        .status-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
            margin-bottom: 30px;
        }

        .status-card {
            background: rgba(255, 255, 255, 0.02);
            border: 1px solid rgba(255, 255, 255, 0.05);
            border-radius: 8px;
            padding: 15px;
            display: flex;
            flex-direction: column;
        }

        .status-card .label {
            color: var(--text-secondary);
            font-size: 0.75rem;
            text-transform: uppercase;
            letter-spacing: 1px;
            margin-bottom: 5px;
        }

        .status-card .val {
            font-family: 'Orbitron', sans-serif;
            font-size: 1.3rem;
            font-weight: 700;
        }

        .status-card.state-card {
            grid-column: span 2;
            flex-direction: row;
            justify-content: space-between;
            align-items: center;
            background: rgba(255, 255, 255, 0.03);
            border: 1px solid rgba(255, 255, 255, 0.08);
        }

        .status-card.state-card .state-indicator {
            display: flex;
            align-items: center;
            gap: 10px;
        }

        .led-dot {
            width: 14px;
            height: 14px;
            border-radius: 50%;
            background-color: var(--text-secondary);
            transition: all 0.5s ease;
        }

        .led-dot.GREEN {
            background-color: var(--color-closed);
            box-shadow: 0 0 15px var(--color-closed), 0 0 30px var(--color-closed);
        }

        .led-dot.RED {
            background-color: var(--color-tripped);
            box-shadow: 0 0 15px var(--color-tripped), 0 0 30px var(--color-tripped);
        }

        .op-log-panel {
            background: rgba(0, 0, 0, 0.2);
            border: 1px solid rgba(255, 255, 255, 0.05);
            border-radius: 8px;
            padding: 20px;
            margin-top: auto;
        }

        .op-log-panel h3 {
            font-size: 0.8rem;
            text-transform: uppercase;
            letter-spacing: 1px;
            color: var(--text-secondary);
            margin-bottom: 10px;
            border-bottom: 1px solid rgba(255, 255, 255, 0.05);
            padding-bottom: 5px;
        }

        .op-log-item {
            font-size: 0.85rem;
            line-height: 1.5;
        }

        .op-log-item .op-title {
            font-weight: 600;
            color: #3b82f6;
        }

        .op-log-item .op-meta {
            font-size: 0.75rem;
            color: var(--text-secondary);
            margin-top: 5px;
        }

        /* HMI Right side: Breaker Diagram */
        .hmi-right {
            display: flex;
            flex-direction: column;
            justify-content: center;
            align-items: center;
            border-left: 1px solid rgba(255, 255, 255, 0.05);
            padding-left: 40px;
        }

        .diagram-container {
            width: 100%;
            height: 320px;
            position: relative;
            display: flex;
            flex-direction: column;
            justify-content: center;
            align-items: center;
        }

        /* Single line diagram styles */
        .bus-line {
            width: 4px;
            height: 100px;
            background-color: var(--color-line);
            transition: all 0.5s ease;
            position: relative;
        }

        .bus-line.ON {
            background-color: var(--color-closed);
            box-shadow: 0 0 10px var(--color-closed);
        }

        .bus-line::after {
            content: '';
            position: absolute;
            width: 20px;
            height: 4px;
            background-color: inherit;
            left: -8px;
        }
        
        .bus-line.top-line::after {
            top: 0;
        }
        
        .bus-line.bottom-line::after {
            bottom: 0;
        }

        .breaker-symbol {
            width: 60px;
            height: 80px;
            border: 2px solid var(--text-secondary);
            border-radius: 4px;
            margin: 10px 0;
            position: relative;
            background: rgba(11, 15, 25, 0.8);
            transition: all 0.5s ease;
            display: flex;
            justify-content: center;
            align-items: center;
        }

        .breaker-symbol.CLOSED {
            border-color: var(--color-closed);
            box-shadow: inset 0 0 10px rgba(16, 185, 129, 0.1), 0 0 15px rgba(16, 185, 129, 0.1);
        }

        .breaker-symbol.TRIPPED {
            border-color: var(--color-tripped);
            box-shadow: inset 0 0 10px rgba(239, 68, 68, 0.1), 0 0 15px rgba(239, 68, 68, 0.1);
        }

        .breaker-blade {
            width: 4px;
            height: 50px;
            background-color: var(--text-secondary);
            position: absolute;
            left: 26px;
            top: 13px;
            transform-origin: top center;
            transition: all 0.5s cubic-bezier(0.4, 0, 0.2, 1);
        }

        .breaker-symbol.CLOSED .breaker-blade {
            background-color: var(--color-closed);
            transform: rotate(0deg);
        }

        .breaker-symbol.TRIPPED .breaker-blade {
            background-color: var(--color-tripped);
            transform: rotate(45deg);
        }

        .flow-glow-effect {
            position: absolute;
            width: 100%;
            height: 100%;
            pointer-events: none;
            opacity: 0;
            transition: opacity 0.5s ease;
        }

        .flow-glow-effect.active {
            opacity: 1;
        }

        .flow-particles {
            position: absolute;
            width: 4px;
            height: 10px;
            background: var(--color-closed);
            border-radius: 2px;
            box-shadow: 0 0 8px var(--color-closed);
            animation: flowDown 1.5s infinite linear;
        }

        @keyframes flowDown {
            0% {
                top: 10%;
                opacity: 0;
            }
            10% {
                opacity: 1;
            }
            90% {
                opacity: 1;
            }
            100% {
                top: 90%;
                opacity: 0;
            }
        }

        .diagram-label {
            margin-top: 15px;
            font-family: 'Orbitron', sans-serif;
            font-size: 0.75rem;
            color: var(--text-secondary);
            text-transform: uppercase;
            letter-spacing: 1px;
        }

        @media (max-width: 768px) {
            .hmi-container {
                grid-template-columns: 1fr;
                padding: 25px;
            }
            .hmi-right {
                border-left: none;
                border-top: 1px solid rgba(255, 255, 255, 0.05);
                padding-left: 0;
                padding-top: 40px;
            }
        }
    </style>
</head>
<body>

    <div class="hmi-container">
        <div class="hmi-left">
            <div class="hmi-header">
                <h1 id="device-title">FEEDER BREAKER (MASKED)</h1>
                <p>Grid Operation Bay-1 HMI</p>
            </div>

            <div class="status-grid">
                <div class="status-card">
                    <span class="label">Telemetry IOA</span>
                    <span class="val" id="val-ioa">••••</span>
                </div>
                <div class="status-card">
                    <span class="label">Power Flow</span>
                    <span class="val" id="val-flow" style="transition: color 0.5s ease;">ON</span>
                </div>
                <div class="status-card state-card">
                    <div style="display: flex; flex-direction: column;">
                        <span class="label">Breaker State</span>
                        <span class="val" id="val-state" style="transition: color 0.5s ease;">CLOSED</span>
                    </div>
                    <div class="state-indicator">
                        <div class="led-dot GREEN" id="val-led"></div>
                    </div>
                </div>
            </div>

            <div class="op-log-panel">
                <h3>Last Grid Operation</h3>
                <div class="op-log-item">
                    <div class="op-title" id="op-title">None</div>
                    <div class="op-meta" id="op-meta">-</div>
                </div>
            </div>
        </div>

        <div class="hmi-right">
            <div class="diagram-container">
                <div class="bus-line top-line ON" id="bus-top"></div>
                
                <div class="breaker-symbol CLOSED" id="breaker-box">
                    <div class="breaker-blade"></div>
                </div>
                
                <div class="bus-line bottom-line ON" id="bus-bottom">
                    <!-- Flow animation particles -->
                    <div class="flow-glow-effect active" id="particles">
                        <div class="flow-particles" style="animation-delay: 0s;"></div>
                        <div class="flow-particles" style="animation-delay: 0.5s;"></div>
                        <div class="flow-particles" style="animation-delay: 1s;"></div>
                    </div>
                </div>
                
                <div class="diagram-label">Bay Control Mimic</div>
            </div>
        </div>
    </div>

    <script>
        const deviceTitle = document.getElementById('device-title');
        const valIoa = document.getElementById('val-ioa');
        const valFlow = document.getElementById('val-flow');
        const valState = document.getElementById('val-state');
        const valLed = document.getElementById('val-led');
        const opTitle = document.getElementById('op-title');
        const opMeta = document.getElementById('op-meta');
        
        const busTop = document.getElementById('bus-top');
        const busBottom = document.getElementById('bus-bottom');
        const breakerBox = document.getElementById('breaker-box');
        const particles = document.getElementById('particles');

        async function updateStatus() {
            try {
                const response = await fetch('/api/status');
                if (!response.ok) return;
                const data = await response.json();

                // Update text elements
                deviceTitle.textContent = data.device_name;
                valIoa.textContent = data.ioa;
                valFlow.textContent = data.power_flow;
                valState.textContent = data.state;
                
                if (data.last_operation !== "None") {
                    opTitle.textContent = data.last_operation;
                    opTitle.style.color = '#ef4444';
                    opMeta.textContent = `${data.last_op_timestamp} | CMD TYPE: ${data.last_op_type}`;
                } else {
                    opTitle.textContent = "System Idle";
                    opTitle.style.color = '#94a3b8';
                    opMeta.textContent = "Monitoring active | Grid stable";
                }

                // Update visual styling
                if (data.state === "CLOSED") {
                    valFlow.style.color = '#10b981';
                    valState.style.color = '#10b981';
                    
                    valLed.className = 'led-dot GREEN';
                    
                    breakerBox.className = 'breaker-symbol CLOSED';
                    busTop.className = 'bus-line top-line ON';
                    busBottom.className = 'bus-line bottom-line ON';
                    particles.classList.add('active');
                } else {
                    valFlow.style.color = '#ef4444';
                    valState.style.color = '#ef4444';
                    
                    valLed.className = 'led-dot RED';
                    
                    breakerBox.className = 'breaker-symbol TRIPPED';
                    busTop.className = 'bus-line top-line';
                    busBottom.className = 'bus-line bottom-line';
                    particles.classList.remove('active');
                }
            } catch (err) {
                console.error("Failed to fetch status:", err);
            }
        }

        // Poll every 1 second
        setInterval(updateStatus, 1000);
        // Initial fetch
        updateStatus();
    </script>
</body>
</html>"""

class HMIRequestHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Suppress default logging of request logs to stdout to keep simulator output clean,
        # but feel free to write it to our log file under a HMI tag.
        log("HMI", format % args)

    def do_GET(self):
        if self.path == "/api/status":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(json.dumps(HMI_STATE).encode("utf-8"))
        elif self.path in ("/", "/index.html"):
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(HMI_HTML.encode("utf-8"))
        else:
            self.send_response(404)
            self.end_headers()

def hmi_server_runner():
    server_address = ("0.0.0.0", 8080)
    httpd = HTTPServer(server_address, HMIRequestHandler)
    log("SYSTEM", "HMI HTTP Server listening on 0.0.0.0:8080")
    try:
        httpd.serve_forever()
    except Exception as exc:
        log("ERROR", f"HMI Server error: {exc}")


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
def log(level: str, msg: str):
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    line = f"[{ts}] [{level:8s}] {msg}\n"
    print(line, end="", flush=True)
    try:
        with open(LOG_FILE, "a") as fh:
            fh.write(line)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Flag generation
# ---------------------------------------------------------------------------
def capture_artifact_and_flag(ioa: int, type_str: str):
    flag_file = os.environ.get("FLAG_FILE", "/run/ctf/stage4_flag")
    if os.path.exists(flag_file):
        return
    try:
        os.makedirs(os.path.dirname(flag_file), exist_ok=True)
    except Exception:
        flag_file = "/tmp/stage4_flag"
        os.makedirs("/tmp", exist_ok=True)

    if os.path.exists(flag_file):
        return

    artifact  = f"IOA:{ioa}:TYPE:{type_str}:ACK"
    flag_msg  = f"STAGE4:{artifact}"
    h         = hmac.new(bytes.fromhex(INSTANCE_SEED), flag_msg.encode(), hashlib.sha256)
    flag_hex  = h.hexdigest()[:16]
    flag      = f"FLAG{{S4-{flag_hex}}}"

    try:
        with open(flag_file, "w") as fh:
            fh.write(flag)
        os.chmod(flag_file, 0o644)
    except Exception as e:
        log("ERROR", f"Failed to write flag file: {e}")
    log("SYSTEM", f"Flag generated and stored: {flag}  (Artifact: {artifact})")


# ---------------------------------------------------------------------------
# c104 server callbacks
# ---------------------------------------------------------------------------
def on_connect(server: c104.Server, ip: str) -> bool:
    log("INFO", f"[c104] Internal server accepted connection from {ip}")
    return True


def on_unexpected(server: c104.Server, message: c104.IncomingMessage, cause: c104.Umc) -> None:
    if cause == c104.Umc.MISMATCHED_TYPE_ID:
        log("TRIPWIRE", f"malformed type-for-IOA  IOA={message.io_address}  type={message.type.name}")
    else:
        log("REJECT",   f"Unexpected message  IOA={message.io_address}  cause={cause.name}")


# ---------------------------------------------------------------------------
# IEC-104 frame classification helpers
# ---------------------------------------------------------------------------
def is_u_frame(apdu: bytes) -> bool:
    """U-frame: bits 0-1 of ctrl byte 1 are both 1  (xx xx xx 11)."""
    return len(apdu) >= 3 and (apdu[2] & 0x03) == 0x03

def is_s_frame(apdu: bytes) -> bool:
    """S-frame: bit 0 of ctrl byte 1 == 1, bit 1 == 0  (xx xx xx 01)."""
    return len(apdu) >= 3 and (apdu[2] & 0x03) == 0x01

def is_i_frame(apdu: bytes) -> bool:
    """I-frame: bit 0 of ctrl byte 1 == 0  (xx xx xx x0)."""
    return len(apdu) >= 3 and (apdu[2] & 0x01) == 0x00

def u_frame_name(apdu: bytes) -> str:
    """Return a human-readable name for the U-frame type."""
    if len(apdu) < 3:
        return "U-UNKNOWN"
    c1 = apdu[2]
    if   c1 == 0x07: return "STARTDT ACT"
    elif c1 == 0x0B: return "STARTDT CON"
    elif c1 == 0x13: return "STOPDT ACT"
    elif c1 == 0x23: return "STOPDT CON"
    elif c1 == 0x43: return "TESTFR ACT"
    elif c1 == 0x83: return "TESTFR CON"
    return f"U-FRAME(0x{c1:02X})"

def hex_dump(data: bytes) -> str:
    return " ".join(f"{b:02X}" for b in data)


# ---------------------------------------------------------------------------
# Shared socket teardown helper
# ---------------------------------------------------------------------------
def _shutdown_sock(sock: socket.socket, label: str):
    """Best-effort SHUT_RDWR then close, silencing all errors."""
    try:
        sock.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    try:
        sock.close()
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Per-client proxy handler
# ---------------------------------------------------------------------------
def handle_client(client_sock: socket.socket, client_addr):
    peer = f"{client_addr[0]}:{client_addr[1]}"
    log("PROXY", f"Public client accepted: {peer}")

    # --- Connect to internal c104 server ---
    server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_sock.settimeout(5)
    try:
        server_sock.connect((INTERNAL_HOST, INTERNAL_PORT))
        server_sock.settimeout(None)
        log("PROXY", f"Internal c104 server connected ({INTERNAL_HOST}:{INTERNAL_PORT}) for client {peer}")
    except Exception as exc:
        log("ERROR", f"Failed to connect to internal server for {peer}: {exc}")
        _shutdown_sock(client_sock, "client")
        return

    # Shared stop event — whichever direction ends first signals the other.
    stop = threading.Event()

    # Per-connection protocol state
    state = {
        "session_active": False,
        "selected_ioas":  set(),
    }

    # Launch bidirectional forwarding threads
    c2s = threading.Thread(
        target=forward_c2s,
        args=(client_sock, server_sock, peer, state, stop),
        daemon=True,
        name=f"c2s-{peer}",
    )
    s2c = threading.Thread(
        target=forward_s2c,
        args=(server_sock, client_sock, peer, stop),
        daemon=True,
        name=f"s2c-{peer}",
    )
    c2s.start()
    s2c.start()

    # Block until the first direction signals done.
    stop.wait()

    # Unblock both sockets so the sleeping thread exits its recv() immediately.
    log("PROXY", f"[{peer}] Stop event set — shutting down both sockets")
    _shutdown_sock(client_sock, f"{peer} client")
    _shutdown_sock(server_sock, f"{peer} server")

    # Join both threads before returning (gives them a moment to flush logs).
    c2s.join(timeout=5)
    s2c.join(timeout=5)
    log("PROXY", f"[{peer}] Connection fully closed")


# ---------------------------------------------------------------------------
# Expected errno values during normal teardown — not logged as errors
# ---------------------------------------------------------------------------
_TEARDOWN_ERRNOS = {
    9,   # EBADF  — fd closed by parent during coordinated shutdown
    104, # ECONNRESET
    32,  # EPIPE
}

def _is_teardown_exc(exc: Exception) -> bool:
    """Return True when the exception is expected during socket shutdown."""
    if isinstance(exc, (BrokenPipeError, ConnectionResetError)):
        return True
    if isinstance(exc, OSError) and exc.errno in _TEARDOWN_ERRNOS:
        return True
    return False


# ---------------------------------------------------------------------------
# Client → Internal server forwarding  (with IEC-104 frame inspection)
# ---------------------------------------------------------------------------
def forward_c2s(client_sock: socket.socket,
                server_sock: socket.socket,
                peer: str,
                state: dict,
                stop: threading.Event):
    buf = b""
    close_reason = "client closed connection"
    try:
        while not stop.is_set():
            try:
                chunk = client_sock.recv(4096)
            except (BrokenPipeError, ConnectionResetError) as exc:
                close_reason = f"client connection reset: {exc}"
                break
            except OSError as exc:
                if _is_teardown_exc(exc):
                    close_reason = "socket closed during shutdown"
                else:
                    close_reason = f"recv error from client: {exc}"
                break
            except Exception as exc:
                close_reason = f"recv error from client: {exc}"
                break

            if not chunk:
                close_reason = "client sent EOF"
                break

            log("PROXY", f"[{peer}] Received {len(chunk)} bytes from client: {hex_dump(chunk[:32])}{'...' if len(chunk)>32 else ''}")
            buf += chunk

            # Process all complete APDUs in the buffer
            while True:
                # Need at least 2 bytes to know total length
                if len(buf) < 2:
                    break

                # Sync on 0x68 start byte
                if buf[0] != 0x68:
                    log("WARN", f"[{peer}] Bad sync byte 0x{buf[0]:02X}, skipping")
                    buf = buf[1:]
                    continue

                apdu_len   = buf[1]          # length field (bytes after the 2-byte header)
                total_len  = apdu_len + 2    # total APDU byte count incl. 0x68 + length
                if len(buf) < total_len:
                    break                    # wait for more data

                apdu = buf[:total_len]
                buf  = buf[total_len:]

                # --- Classify frame ---
                if is_u_frame(apdu):
                    name = u_frame_name(apdu)
                    log("FRAME", f"[{peer}] U-frame detected: {name}  [{hex_dump(apdu)}]")

                    # Track session-open for our own state machine
                    if apdu[2] == 0x07:   # STARTDT ACT
                        state["session_active"] = True
                        log("INFO",  f"[{peer}] STARTDT ACT → session marked active")

                    # Forward ALL U-frames unchanged
                    try:
                        server_sock.sendall(apdu)
                        log("PROXY", f"[{peer}] U-frame forwarded to internal server: {name}")
                    except (BrokenPipeError, ConnectionResetError, OSError) as exc:
                        close_reason = f"send to internal server failed (U-frame): {exc}"
                        raise ConnectionAbortedError(close_reason)

                elif is_s_frame(apdu):
                    log("FRAME", f"[{peer}] S-frame detected  [{hex_dump(apdu)}]")
                    try:
                        server_sock.sendall(apdu)
                    except (BrokenPipeError, ConnectionResetError, OSError) as exc:
                        close_reason = f"send to internal server failed (S-frame): {exc}"
                        raise ConnectionAbortedError(close_reason)

                elif is_i_frame(apdu):
                    log("FRAME", f"[{peer}] I-frame detected  [{hex_dump(apdu[:20])}{'...' if len(apdu)>20 else ''}]")

                    # Enforce session start before any I-frame
                    if not state["session_active"]:
                        log("TRIPWIRE", f"[{peer}] commands sent without session-start — disconnecting")
                        close_reason = "tripwire: no session-start"
                        break

                    # Parse ASDU fields if frame is long enough
                    if len(apdu) >= 13:
                        type_id = apdu[6]
                        # IOA is 3 bytes little-endian at offset 12
                        ioa = apdu[12] + (apdu[13] << 8) + (apdu[14] << 16) if len(apdu) >= 15 else 0

                        log("FRAME", f"[{peer}] I-frame  type_id={type_id}  ioa={ioa}")

                        # Only filter C_SC_NA_1 (45) and C_DC_NA_1 (46)
                        if type_id in FILTERED_TYPES and ioa > 0:
                            # Range check
                            if ioa < TARGET_IOA or ioa > IOA_END:
                                log("REJECT", f"[{peer}] Out-of-range IOA {ioa} — disconnecting silently")
                                close_reason = f"out-of-range IOA {ioa}"
                                break

                            # Type-for-IOA check
                            expected_type = 45 if (ioa % 2 != 0) else 46
                            if type_id != expected_type:
                                log("TRIPWIRE", f"[{peer}] malformed type-for-IOA  IOA={ioa}  got={type_id}  expected={expected_type}")
                                # Still forward; let c104 server fire the MISMATCHED_TYPE_ID callback
                            else:
                                # Track SELECT / EXECUTE state
                                if len(apdu) >= 16:
                                    is_select = bool(apdu[15] & 0x80)
                                    if is_select:
                                        state["selected_ioas"].add(ioa)
                                        log("CYCLE", f"[{peer}] SELECT  IOA={ioa}  type={type_id} — approved")
                                    else:
                                        if ioa not in state["selected_ioas"]:
                                            log("TRIPWIRE", f"[{peer}] execute without prior select  IOA={ioa}")
                                        else:
                                            state["selected_ioas"].discard(ioa)
                                            log("CYCLE", f"[{peer}] EXECUTE IOA={ioa}  type={type_id} — forwarding")

                    # Forward I-frame to internal server
                    try:
                        server_sock.sendall(apdu)
                        log("PROXY", f"[{peer}] I-frame forwarded to internal server")
                    except (BrokenPipeError, ConnectionResetError, OSError) as exc:
                        close_reason = f"send to internal server failed (I-frame): {exc}"
                        raise ConnectionAbortedError(close_reason)

                else:
                    log("WARN",  f"[{peer}] Unknown frame format, forwarding raw: {hex_dump(apdu)}")
                    try:
                        server_sock.sendall(apdu)
                    except (BrokenPipeError, ConnectionResetError, OSError) as exc:
                        close_reason = f"send to internal server failed (unknown frame): {exc}"
                        raise ConnectionAbortedError(close_reason)

    except ConnectionAbortedError as exc:
        close_reason = str(exc)
    except Exception as exc:
        close_reason = f"unhandled exception in c2s: {exc}"

    log("PROXY", f"[{peer}] c2s thread done — {close_reason}")
    # Signal the parent; it will close the sockets.
    stop.set()


# ---------------------------------------------------------------------------
# Internal server → Client forwarding  (pass-through with logging)
# ---------------------------------------------------------------------------
def forward_s2c(server_sock: socket.socket,
                client_sock: socket.socket,
                peer: str,
                stop: threading.Event):
    close_reason = "internal server closed connection"
    try:
        while not stop.is_set():
            try:
                data = server_sock.recv(4096)
            except (BrokenPipeError, ConnectionResetError) as exc:
                close_reason = f"server connection reset: {exc}"
                break
            except OSError as exc:
                if _is_teardown_exc(exc):
                    close_reason = "socket closed during shutdown"
                else:
                    close_reason = f"recv error from internal server: {exc}"
                break
            except Exception as exc:
                close_reason = f"recv error from internal server: {exc}"
                break

            if not data:
                close_reason = "internal server sent EOF"
                break

            log("PROXY", f"[{peer}] {len(data)} bytes from internal server: {hex_dump(data[:32])}{'...' if len(data)>32 else ''}")

            # Log notable U-frame responses from the server side
            if len(data) >= 6 and data[0] == 0x68:
                if data[2] == 0x0B:
                    log("INFO",  f"[{peer}] STARTDT CON received from internal server — forwarding to client")
                elif data[2] == 0x23:
                    log("INFO",  f"[{peer}] STOPDT CON received from internal server — forwarding to client")
                elif data[2] == 0x83:
                    log("INFO",  f"[{peer}] TESTFR CON received from internal server — forwarding to client")

            try:
                client_sock.sendall(data)
                log("PROXY", f"[{peer}] Forwarded {len(data)} bytes to client")
            except (BrokenPipeError, ConnectionResetError) as exc:
                close_reason = f"send to client failed (broken pipe): {exc}"
                break
            except OSError as exc:
                if _is_teardown_exc(exc):
                    close_reason = "socket closed during shutdown"
                else:
                    close_reason = f"send to client failed: {exc}"
                break
            except Exception as exc:
                close_reason = f"send to client failed: {exc}"
                break

    except Exception as exc:
        close_reason = f"unhandled exception in s2c: {exc}"

    log("PROXY", f"[{peer}] s2c thread done — {close_reason}")
    # Signal the parent; it will close the sockets.
    stop.set()


# ---------------------------------------------------------------------------
# TCP Proxy listener
# ---------------------------------------------------------------------------
def tcp_proxy_listener():
    proxy_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    proxy_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    proxy_sock.bind(("0.0.0.0", PUBLIC_PORT))
    proxy_sock.listen(128)
    log("SYSTEM", f"TCP Proxy listening on 0.0.0.0:{PUBLIC_PORT}")

    while True:
        try:
            client_sock, client_addr = proxy_sock.accept()
            threading.Thread(
                target=handle_client,
                args=(client_sock, client_addr),
                daemon=True,
                name=f"client-{client_addr[0]}:{client_addr[1]}",
            ).start()
        except Exception as exc:
            log("ERROR", f"Proxy accept error: {exc}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    # Ensure log directory exists
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    except Exception:
        pass

    log("SYSTEM", "Starting IEC-104 Remote Terminal Unit Simulator...")
    log("SYSTEM", f"IOA range: {TARGET_IOA} – {IOA_END}")

    # --- c104 server (internal) ---
    server = c104.Server(ip=INTERNAL_HOST, port=INTERNAL_PORT)
    server.on_connect(on_connect)
    server.on_unexpected_message(on_unexpected)

    station = server.add_station(common_address=1)

    for ioa in range(TARGET_IOA, IOA_END + 1):
        expected_type = c104.Type.C_SC_NA_1 if ioa % 2 != 0 else c104.Type.C_DC_NA_1
        point = station.add_point(
            io_address=ioa,
            type=expected_type,
            command_mode=c104.CommandMode.SELECT_AND_EXECUTE,
        )
        point.value = False if expected_type == c104.Type.C_SC_NA_1 else c104.Double.OFF

        # Status monitoring point at status_ioa (offset by 1000 to keep IOAs unique)
        status_ioa = ioa + 1000
        status_type = c104.Type.M_SP_NA_1 if expected_type == c104.Type.C_SC_NA_1 else c104.Type.M_DP_NA_1
        status_point = station.add_point(
            io_address=status_ioa,
            type=status_type,
        )
        status_point.value = False if status_type == c104.Type.M_SP_NA_1 else c104.Double.OFF

        def make_on_recv(ioa_num, t, sp):
            def on_recv(point: c104.Point,
                        previous_info: c104.Information,
                        message: c104.IncomingMessage) -> c104.ResponseState:
                log("CYCLE", f"EXECUTE confirmed  IOA={ioa_num}  type={t.name}")
                capture_artifact_and_flag(ioa_num, t.name)
                
                # Best-effort attempt to toggle control point value (fails/logs warning in c104)
                try:
                    if t == c104.Type.C_SC_NA_1:
                        point.value = not point.value
                    else:
                        point.value = c104.Double.OFF if point.value == c104.Double.ON else c104.Double.ON
                except Exception as exc:
                    log("WARN", f"Could not toggle control point IOA {ioa_num}: {exc}")
                
                # Successfully update the status monitoring point
                try:
                    sp.value = point.value
                except Exception as exc:
                    log("WARN", f"Could not update status point IOA {sp.io_address}: {exc}")

                # Update HMI state if it's the target IOA
                if ioa_num == TARGET_IOA:
                    try:
                        is_trip = False
                        if t == c104.Type.C_SC_NA_1 and message.info.value is True:
                            is_trip = True
                        elif t == c104.Type.C_DC_NA_1 and message.info.value == c104.Double.ON:
                            is_trip = True

                        HMI_STATE["device_name"] = f"Feeder Breaker {TARGET_IOA}"
                        HMI_STATE["ioa"] = TARGET_IOA
                        HMI_STATE["last_operation"] = "Remote IEC-104 Command Accepted"
                        HMI_STATE["last_op_timestamp"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                        HMI_STATE["last_op_type"] = t.name

                        if is_trip:
                            HMI_STATE["state"] = "TRIPPED"
                            HMI_STATE["power_flow"] = "OFF"
                            HMI_STATE["indicator"] = "RED"
                        else:
                            HMI_STATE["state"] = "CLOSED"
                            HMI_STATE["power_flow"] = "ON"
                            HMI_STATE["indicator"] = "GREEN"
                    except Exception as exc:
                        log("WARN", f"Could not update HMI state: {exc}")
                
                return c104.ResponseState.SUCCESS
            return on_recv

        point.on_receive(make_on_recv(ioa, expected_type, status_point))

    # --- HMI HTTP Server ---
    hmi_thread = threading.Thread(target=hmi_server_runner, daemon=True)
    hmi_thread.start()

    server.start()
    log("SYSTEM", f"c104 server running on {INTERNAL_HOST}:{INTERNAL_PORT}")

    # --- Public proxy ---
    proxy_thread = threading.Thread(target=tcp_proxy_listener, daemon=True)
    proxy_thread.start()

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        server.stop()
        log("SYSTEM", "IEC-104 server stopped")


if __name__ == "__main__":
    main()
