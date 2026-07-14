import socket
import struct
import os
import threading
import time
import subprocess

# --- Part 1: IEC 61850 Automation Service (Port 102) ---

def handle_mms_client(conn, addr):
    client_ip = addr[0]
    conn.settimeout(5.0)
    print(f"[*] MMS client connected from {client_ip}")
    
    # Track connection attempt for tripwires
    with open("/tmp/tripwire_mms_conn", "a") as f:
        f.write(f"Connection from {client_ip} at {int(time.time())}\n")
        
    try:
        while True:
            data = conn.recv(1024)
            if not data:
                break
                
            is_tpkt = False
            payload = data
            if len(data) >= 7 and data[0] == 0x03 and data[1] == 0x00:
                # TPKT/COTP header present
                is_tpkt = True
                tpkt_len = struct.unpack('!H', data[2:4])[0]
                # data[4:7] is COTP (e.g. \x02\xf0\x80)
                payload = data[7:tpkt_len]
                
            cmd = payload.decode('utf-8', errors='ignore').strip()
            if not cmd:
                continue
                
            response_str = ""
            parts = cmd.split()
            base_cmd = parts[0].upper() if parts else ""
            
            # Read current breaker state from shared file
            breaker_state = "CLOSED"
            if os.path.exists("/tmp/breaker_state"):
                try:
                    with open("/tmp/breaker_state", "r") as f:
                        breaker_state = f.read().strip()
                except Exception:
                    pass
                    
            conf_rev = os.environ.get("GOOSE_CONF_REV", "7366")
            
            if base_cmd == "LIST" or base_cmd == "DIR":
                response_str = (
                    "Logical Device: BayControllerLD\n"
                    f"  LLN0$CF$ConfRev: {conf_rev}\n"
                    f"  XCBR1$ST$Pos$stVal: {breaker_state}\n"
                    "  XCBR1$CO$Pos$Oper: [Writable]\n"
                )
            elif base_cmd == "READ":
                if len(parts) < 2:
                    response_str = "ERROR: Missing variable name\n"
                else:
                    var = parts[1]
                    if var == "LLN0$CF$ConfRev":
                        response_str = f"{conf_rev}\n"
                    elif var == "XCBR1$ST$Pos$stVal":
                        response_str = f"{breaker_state}\n"
                    else:
                        response_str = f"ERROR: Variable {var} not found\n"
            elif base_cmd == "WRITE":
                if len(parts) < 3:
                    response_str = "ERROR: Missing variable or value\n"
                else:
                    var = parts[1]
                    val = parts[2]
                    if var == "XCBR1$CO$Pos$Oper":
                        response_str = "ERROR: Write blocked — Local physical control override active. Use GOOSE multicast on process interface.\n"
                    else:
                        response_str = f"ERROR: Variable {var} is not writable or not found\n"
            else:
                response_str = f"ERROR: Unknown command {base_cmd}\n"
                
            response_bytes = response_str.encode()
            if is_tpkt:
                # Wrap response in TPKT/COTP
                tpkt_len = len(response_bytes) + 7
                header = struct.pack('!BBH', 3, 0, tpkt_len) + b'\x02\xf0\x80'
                conn.sendall(header + response_bytes)
            else:
                conn.sendall(response_bytes)
                
    except Exception as e:
        print(f"Error handling MMS client: {e}")
    finally:
        conn.close()

def run_mms_service():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", 102))
    server.listen(5)
    print("[*] MMS Service (Port 102) listening...")
    while True:
        try:
            conn, addr = server.accept()
            t = threading.Thread(target=handle_mms_client, args=(conn, addr))
            t.daemon = True
            t.start()
        except Exception as e:
            print(f"Error in MMS server accept: {e}")

# --- Part 2: Legacy Scripting Interface (Port 9022) ---

def handle_legacy_client(conn, addr):
    client_ip = addr[0]
    conn.settimeout(5.0)
    print(f"[*] Legacy client connected from {client_ip}")
    try:
        # Read script data (up to 64KB)
        data = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
            if len(data) > 65536:
                break
                
        script_path = f"/tmp/uploaded_script_{int(time.time())}.scil"
        with open(script_path, "wb") as f:
            f.write(data)
            
        # Run validator
        res = subprocess.run(
            ["python3", "/app/scil_validator.py", script_path, client_ip],
            capture_output=True,
            text=True
        )
        
        # Clean up temp file
        if os.path.exists(script_path):
            os.remove(script_path)
            
        if res.returncode == 0:
            conn.sendall(res.stdout.encode())
        else:
            conn.sendall(f"ERROR: Script validation failed (exit code {res.returncode})\n{res.stderr}".encode())
            with open("/tmp/tripwire_legacy_fail", "a") as f:
                f.write(f"Failed parse from {client_ip}: {res.stderr.strip()}\n")
                
    except Exception as e:
        print(f"Error handling legacy client: {e}")
    finally:
        conn.close()

def run_legacy_service():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", 9022))
    server.listen(5)
    print("[*] Legacy SCIL Service (Port 9022) listening...")
    while True:
        try:
            conn, addr = server.accept()
            t = threading.Thread(target=handle_legacy_client, args=(conn, addr))
            t.daemon = True
            t.start()
        except Exception as e:
            print(f"Error in Legacy server accept: {e}")

if __name__ == "__main__":
    # Start both threads
    t1 = threading.Thread(target=run_mms_service)
    t1.daemon = True
    t1.start()
    
    t2 = threading.Thread(target=run_legacy_service)
    t2.daemon = True
    t2.start()
    
    # Keep main thread alive
    while True:
        time.sleep(1)
