#!/usr/bin/env bash
set -euo pipefail

export HOME="/config/renault"
export XDG_CONFIG_HOME="/config/renault"
export XDG_DATA_HOME="/config/renault"

# Activate venv (safe)
if [ -f "/config/renault/.venv/bin/activate" ]; then
    . "/config/renault/.venv/bin/activate"
fi

# Use venv Python directly (more robust than the renault-api wrapper script)
REN_PY="/config/renault/.venv/bin/python"

KAM_ACCOUNT_ID="<your-account-number>"
VIN="<your-vin-number>"

RAW_OUT="/config/renault/debug_battery_raw.txt"
CACHE_JSON="/config/renault/battery_cache.json"

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

# IMPORTANT: use KCA v2 (v1 can be stale)
URL="/commerce/v1/accounts/${KAM_ACCOUNT_ID}/kamereon/kca/car-adapter/v2/cars/${VIN}/battery-status?country=GB&brand=RENAULT"

# bounded call; do not hang; do not prompt
RC=0
timeout 45s env HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_DATA_HOME="$XDG_DATA_HOME" \
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

RAW_OUT = Path("/config/renault/debug_battery_raw.txt")
CACHE_JSON = Path("/config/renault/battery_cache.json")
VIN = "<your-vin-number>"

def iso_now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()

def wrap(attrs: dict, ok: bool, err: str | None, source: str, note: str | None = None):
    return {
        "data": {
            "type": "Car",
            "id": VIN,
            "attributes": attrs if isinstance(attrs, dict) else {},
            "ok": bool(ok),
            "error": err,
            "source": source,
            "fetched_at": iso_now(),
            "note": note
        }
    }

def load_cache(err: str, note: str):
    if CACHE_JSON.exists():
        try:
            cached = json.loads(CACHE_JSON.read_text(encoding="utf-8"))
            old_attrs = cached.get("data", {}).get("attributes", {})
            print(json.dumps(wrap(old_attrs, False, err, "cache", note)))
            return True
        except Exception:
            pass
    return False

try:
    raw = RAW_OUT.read_text(encoding="utf-8", errors="ignore").strip()
    raw_low = raw.lower()
    rc = int(os.environ.get("R5_REN_RC", "0") or "0")

    # 1) Detect prompts/timeouts/auth
    prompt_markers = [
        "please select",
        "interactive_input_required",
        "interactive input",
        "cli_requested_interactive_input",
        "user: aborted",
        "aborted",
        "password:",
        "user:",
    ]
    if any(x in raw_low for x in prompt_markers):
        if not load_cache("cli_prompted", "interactive_input_required"):
            print(json.dumps(wrap({}, False, "cli_prompted", "none", "interactive_input_required")))
        sys.exit(0)

    # timeout(1) commonly uses rc=124 for timeouts
    if rc == 124 or any(x in raw_low for x in ["terminated", "killed", "timed out", "timeout"]):
        if not load_cache("timeout", f"cli_timeout (rc={rc})"):
            print(json.dumps(wrap({}, False, "timeout", "none", f"cli_timeout (rc={rc})")))
        sys.exit(0)

    auth_markers = ["unauthorized", "forbidden", "invalid token"]
    if any(x in raw_low for x in auth_markers):
        if not load_cache("unauthorized", "auth_failed"):
            print(json.dumps(wrap({}, False, "unauthorized", "none", "auth_failed")))
        sys.exit(0)

    # 2) Extract JSON-ish dict blob from renault-api output
    blocks = re.findall(r"\{.*\}", raw, flags=re.S)
    if not blocks:
        raise ValueError("no_json_found")

    blob = blocks[-1]

    # Try strict JSON first (more robust)
    try:
        data = json.loads(blob)
    except Exception:
        safe = blob.replace("null", "None").replace("true", "True").replace("false", "False")
        data = ast.literal_eval(safe)

    # 3) Handle nested structure (KCA v2 often nests: data -> attributes)
    if isinstance(data, dict) and "data" in data and isinstance(data["data"], dict):
        inner = data["data"]
        final_attrs = inner.get("attributes", inner)
    elif isinstance(data, dict) and "attributes" in data:
        final_attrs = data["attributes"]
    else:
        final_attrs = data

    if not final_attrs or not isinstance(final_attrs, dict):
        raise ValueError("empty_payload")

    # 4) Success
    out = wrap(final_attrs, True, None, "live")
    CACHE_JSON.write_text(json.dumps(out), encoding="utf-8")
    print(json.dumps(out))

except Exception as e:
    err_str = str(e)
    if not load_cache("parse_error", err_str):
        print(json.dumps(wrap({}, False, "parse_error", "none", err_str)))
PY
