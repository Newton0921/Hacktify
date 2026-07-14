import sys
import os
import time
import hashlib
import hmac

def main():
    if len(sys.argv) < 3:
        print("Usage: scil_validator.py <script_path> <client_addr>", file=sys.stderr)
        sys.exit(2)
        
    script_path = sys.argv[1]
    client_addr = sys.argv[2]
    
    if not os.path.exists(script_path):
        print(f"Error: file {script_path} not found", file=sys.stderr)
        sys.exit(3)
        
    with open(script_path, "r") as f:
        content = f.read()
        
    expected_ioa = int(os.environ.get("SCIL_EXPECTED_IOA", "2947"))
    seed = os.environ.get("INSTANCE_SEED", "")
    
    # Parse lines
    lines = content.splitlines()
    has_target_ioa = False
    
    for i, line in enumerate(lines):
        line = line.strip()
        if not line or line.startswith(";"):
            continue
        if line.startswith("#SET "):
            # Parse assignment
            parts = line[5:].split("=")
            if len(parts) == 2:
                key = parts[0].strip()
                val = parts[1].strip()
                # Check if it targets the expected IOA
                if "Pioa" in key and val == str(expected_ioa):
                    has_target_ioa = True
                elif key.upper() == "IOA" and val == str(expected_ioa):
                    has_target_ioa = True
                continue
        # Invalid syntax
        print(f"Syntax Error on line {i+1}: {line}", file=sys.stderr)
        sys.exit(1)
        
    if not has_target_ioa:
        print(f"Error: Script does not target expected IOA {expected_ioa}", file=sys.stderr)
        sys.exit(1)
        
    # Valid syntax and targets expected IOA
    ts = int(time.time())
    script_hash = hashlib.sha256(content.encode()).hexdigest()
    token = f"TOKEN_OK:{ts}:{client_addr}:{script_hash}"
    print(token)
    
    # Write flag
    if seed:
        flag_msg = f"STAGE5b:{token}"
        flag_hex = hmac.new(bytes.fromhex(seed), flag_msg.encode(), hashlib.sha256).hexdigest()[:16]
        flag = f"FLAG{{S5b-{flag_hex}}}"
        
        os.makedirs("/run/ctf", exist_ok=True)
        with open("/run/ctf/stage5b_flag", "w") as f:
            f.write(flag)
        os.chmod("/run/ctf/stage5b_flag", 0o600)
        
    sys.exit(0)

if __name__ == "__main__":
    main()
