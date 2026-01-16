#!/usr/bin/env bash
set -euo pipefail

export HOME="/config/renault"
export XDG_CONFIG_HOME="/config/renault"
export XDG_DATA_HOME="/config/renault"

# Activate venv (safe)
if [ -f "/config/renault/.venv/bin/activate" ]; then
    . "/config/renault/.venv/bin/activate" 2>/dev/null || true
fi

# Use venv Python directly (more robust than the renault-api wrapper script)
REN_PY="/config/renault/.venv/bin/python"

KAM_ACCOUNT_ID="<your-account-number>"
VIN="<your-vin-number>"

RAW_OUT="/config/renault/debug_ev_settings_raw.txt"
CACHE_JSON="/config/renault/ev_settings_cache.json"

# Serialize all renault-api usage (prevents creds JSON being read mid-write)
LOCK="/config/renault/.renault_api.lock"
exec 9>"$LOCK"

# BusyBox flock has no -w; implement our own wait loop (max 30s)
locked=0
for i in $(seq 1 30); do
    if flock -n 9; then
        locked=1
        break
    fi
    sleep 1
done

# If we couldn't lock, continue anyway (don't kill command_line JSON output)
if [ "$locked" -ne 1 ]; then
    echo "WARN: lock not acquired" >> "$RAW_OUT" 2>&1 || true
fi

URL="/commerce/v1/accounts/${KAM_ACCOUNT_ID}/kamereon/kcm/v1/vehicles/${VIN}/ev/settings"

RC=0
timeout 60s env HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_DATA_HOME="$XDG_DATA_HOME" \
    "${REN_PY}" -m renault_api.cli --account "${KAM_ACCOUNT_ID}" http get "${URL}" \
    > "${RAW_OUT}" 2>&1 </dev/null || RC=$?
export R5_REN_RC="$RC"

python3 - <<'PY'
import ast
import json
import os
import re
import sys
from pathlib import Path
from datetime import datetime, timezone

RAW_OUT = Path("/config/renault/debug_ev_settings_raw.txt")
CACHE_JSON = Path("/config/renault/ev_settings_cache.json")
VIN = "<your-vin-number>"

def iso_now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()

def wrap(attrs, ok, err, source, note=None):
    return {
        "data": {
            "type": "Car",
            "id": VIN,
            "attributes": attrs if isinstance(attrs, dict) else {},
            "ok": bool(ok),
            "error": err,
            "source": source,
            "fetched_at": iso_now(),
            "note": note,
        }
    }

def load_cache(err, note):
    if CACHE_JSON.exists():
        try:
            cached = json.loads(CACHE_JSON.read_text(encoding="utf-8"))
            old_attrs = cached.get("data", {}).get("attributes", {})
            print(json.dumps(wrap(old_attrs, False, err, "cache", note)))
            return True
        except Exception:
            pass
    return False

raw = RAW_OUT.read_text(encoding="utf-8", errors="ignore").strip()
raw_low = raw.lower()
rc = int(os.environ.get("R5_REN_RC", "0") or "0")

prompt_markers = [
    "please select",
    "select vehicle",
    "interactive_input_required",
    "interactive input",
    "cli_requested_interactive_input",
    "cli_requested_interactive",
    "user: aborted",
    "aborted",
    "password:",
    "user:",
    "locale",
]
if any(x in raw_low for x in prompt_markers):
    if not load_cache("cli_prompted", "cli_requested_interactive_input"):
        print(json.dumps(wrap({}, False, "cli_prompted", "none", "cli_requested_interactive_input")))
    raise SystemExit(0)

if rc == 124 or any(x in raw_low for x in ["terminated", "killed", "timed out", "timeout"]):
    note = f"cli_timeout (rc={rc})"
    if not load_cache("timeout", note):
        print(json.dumps(wrap({}, False, "timeout", "none", note)))
    raise SystemExit(0)

auth_markers = ["unauthorized", "forbidden", "invalid token"]
if any(x in raw_low for x in auth_markers):
    if not load_cache("unauthorized", "auth_failed"):
        print(json.dumps(wrap({}, False, "unauthorized", "none", "auth_failed")))
    raise SystemExit(0)

blocks = re.findall(r"\{.*\}", raw, flags=re.S)
if not blocks:
    if not load_cache("no_payload", "no_json_found"):
        print(json.dumps(wrap({}, False, "no_payload", "none", "no_json_found")))
    raise SystemExit(0)

blob = blocks[-1]
try:
    obj = json.loads(blob)
except Exception:
    safe = blob.replace("null", "None").replace("true", "True").replace("false", "False")
    obj = ast.literal_eval(safe)

if isinstance(obj, dict) and "data" in obj and isinstance(obj["data"], dict):
    inner = obj["data"]
    attrs = inner.get("attributes", inner)
elif isinstance(obj, dict) and "attributes" in obj:
    attrs = obj["attributes"]
else:
    attrs = obj

if not isinstance(attrs, dict) or not attrs:
    if not load_cache("empty_attributes", "endpoint_returned_empty_attributes"):
        print(json.dumps(wrap({}, False, "empty_attributes", "live", "endpoint_returned_empty_attributes")))
    raise SystemExit(0)

out = wrap(attrs, True, None, "live")
CACHE_JSON.write_text(json.dumps(out), encoding="utf-8")
print(json.dumps(out))
PY
