#!/usr/bin/env bash
set -euo pipefail

echo "[bay-controller] Starting up..."

# Ensure required env vars
for v in GOOSE_CONF_REV GOOSE_APPID SCIL_EXPECTED_IOA INSTANCE_SEED; do
    if [[ -z "${!v:-}" ]]; then
        echo "FATAL: ${v} not set" >&2
        exit 1
    fi
done

# Initialize breaker state file
echo "CLOSED" > /tmp/breaker_state
chmod 666 /tmp/breaker_state

# Clear/init tripwires
echo -n "" > /tmp/tripwire_mms_conn
echo -n "" > /tmp/tripwire_mismatch
echo -n "" > /tmp/tripwire_legacy_fail
chmod 666 /tmp/tripwire_mms_conn /tmp/tripwire_mismatch /tmp/tripwire_legacy_fail

# Start automation + legacy scripting services (Process 1)
python3 -u /app/automation_service.py &

# Start L2 responder service (Process 2)
python3 -u /app/l2_responder.py &


# Wait for all background processes
wait
