import socket
import struct
import os
import hmac
import hashlib
import time
import subprocess
import sys

def main():
    seed = os.environ.get("INSTANCE_SEED", "")
    goose_conf_rev = int(os.environ.get("GOOSE_CONF_REV", "7366"))
    goose_appid = int(os.environ.get("GOOSE_APPID", "0x8A04"), 16)
    
    # 1. Find the interface dynamically for IP 10.100.3.2 (with retry loop)
    interface = ""
    print("[*] GOOSE L2 Responder waiting for process-zone interface to attach...")
    for _ in range(30):
        try:
            output = subprocess.check_output(["ip", "-o", "addr", "show"]).decode()
            for line in output.splitlines():
                if "10.100.3.2" in line:
                    parts = line.split()
                    if len(parts) > 1:
                        interface = parts[1]
                        break
            if interface:
                break
        except Exception:
            pass
        time.sleep(1)
        
    if not interface:
        print("FATAL: Timeout waiting for interface with IP 10.100.3.2 to appear", file=sys.stderr)
        sys.exit(1)
        
    print(f"[*] GOOSE L2 Responder listening on interface: {interface}")
    
    # 2. Create raw socket for 0x88B8 (GOOSE)
    try:
        s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x88B8))
        s.bind((interface, 0))
    except Exception as e:
        print(f"FATAL: Failed to create or bind raw socket: {e}", file=sys.stderr)
        sys.exit(1)

    # Best-effort: enable promiscuous mode to ensure multicast reception
    try:
        ifindex = socket.if_nametoindex(interface)
        # struct packet_mreq: ifindex(I), type(H)=PACKET_MR_PROMISC(1), alen(H)=0, address(8s)
        mreq = struct.pack('IHH8s', ifindex, 1, 0, b"\x00" * 8)
        s.setsockopt(263, 16, mreq)  # SOL_PACKET=263, PACKET_ADD_MEMBERSHIP=16
        print(f"[*] Promiscuous mode enabled on {interface}")
    except Exception as e:
        print(f"[!] Could not enable promiscuous mode (non-fatal): {e}")

        
    last_sq_num = 0
    
    while True:
        try:
            packet, addr = s.recvfrom(2048)
            if len(packet) < 14 + 17:
                continue
                
            eth_header = packet[:14]
            payload = packet[14:]
            
            eth_type = struct.unpack('!H', eth_header[12:14])[0]
            if eth_type != 0x88B8:
                continue
                
            appid, length, conf_rev, sq_num, st_num, trip = struct.unpack('!HHIIIB', payload[:17])
            
            if appid != goose_appid:
                continue
                
            # Validate config revision
            if conf_rev != goose_conf_rev:
                print(f"[!] Mismatched confRev: expected {goose_conf_rev}, got {conf_rev}")
                with open("/tmp/tripwire_mismatch", "a") as f:
                    f.write(f"confRev mismatch: expected {goose_conf_rev}, got {conf_rev}\n")
                continue
                
            # Validate sequence number is strictly increasing
            if sq_num <= last_sq_num:
                print(f"[!] Sequence regression: last {last_sq_num}, got {sq_num}")
                with open("/tmp/tripwire_mismatch", "a") as f:
                    f.write(f"sqNum regression: last {last_sq_num}, got {sq_num}\n")
                continue
                
            # Accept valid packet
            last_sq_num = sq_num
            print(f"[+] GOOSE Packet Accepted: sqNum={sq_num}, stNum={st_num}, trip={trip}")
            
            if trip == 1:
                print("[+] Trip signal received! Transitioning breaker state to TRIPPED...")
                # Update shared breaker state
                with open("/tmp/breaker_state", "w") as f:
                    f.write("TRIPPED")
                    
                # Compute Stage 5a flag from raw bytes of the first accepted packet
                packet_hash = hashlib.sha256(packet).hexdigest()
                flag_msg = f"STAGE5a:{packet_hash}"
                flag_hex = hmac.new(bytes.fromhex(seed), flag_msg.encode(), hashlib.sha256).hexdigest()[:16]
                flag = f"FLAG{{S5a-{flag_hex}}}"
                
                os.makedirs("/run/ctf", exist_ok=True)
                with open("/run/ctf/stage5a_flag", "w") as f:
                    f.write(flag)
                os.chmod("/run/ctf/stage5a_flag", 0o600)
                print(f"[+] Stage 5a flag written to /run/ctf/stage5a_flag: {flag}")
                
        except Exception as e:
            print(f"Error in L2 responder loop: {e}")

if __name__ == "__main__":
    main()
