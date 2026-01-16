#!/usr/bin/env bash
set -euo pipefail

export HOME="/config/renault"
export XDG_CONFIG_HOME="/config/renault"
export XDG_DATA_HOME="/config/renault"

if [ -f "/config/renault/.venv/bin/activate" ]; then
    . "/config/renault/.venv/bin/activate" 2>/dev/null || true
fi

REN_PY="/config/renault/.venv/bin/python"

KAM_ACCOUNT_ID="<your-account-number>"
VIN="<your-vin-number>"

RAW_OUT="/config/renault/debug_location_raw.txt"
CACHE_JSON="/config/renault/location_cache.json"

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

URL="/commerce/v1/accounts/${KAM_ACCOUNT_ID}/kamereon/kca/car-adapter/v1/cars/${VIN}/location?country=GB&brand=RENAULT"

# bounded call; do not hang; do not prompt
RC=0
timeout 60s env HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_DATA_HOME="$XDG_DATA_HOME" \
    "$REN_PY" -m renault_api.cli --account "${KAM_ACCOUNT_ID}" http get "${URL}" \
    > "${RAW_OUT}" 2>&1 </dev/null || RC=$?
export R5_REN_RC="$RC"

"$REN_PY" - <<'PY'
import ast
import json
import os
import re
from pathlib import Path
from datetime import datetime, timezone

RAW_OUT = Path("/config/renault/debug_location_raw.txt")
CACHE_JSON = Path("/config/renault/location_cache.json")
VIN = "<your-vin-number>"

def iso_now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()

def wrap_attributes(attrs: dict, ok: bool, err: str | None, source: str, note: str | None = None):
    if not isinstance(attrs, dict):
        attrs = {}
    out = {
        "data": {
            "type": "Car",
            "id": VIN,
            "attributes": attrs,
            "ok": bool(ok),
            "error": err,
            "source": source,
            "fetched_at": iso_now(),
        }
    }
    if note is not None:
        out["data"]["note"] = note
    return out

def load_cache(err: str, note: str):
    if CACHE_JSON.exists():
        try:
            cached = json.loads(CACHE_JSON.read_text(encoding="utf-8"))
        except Exception:
            cached = wrap_attributes({}, False, err, "cache", note)
        cached_attrs = cached.get("data", {}).get("attributes", {})
        print(json.dumps(wrap_attributes(cached_attrs, False, err, "cache", note)))
        return True
    return False

raw = RAW_OUT.read_text(encoding="utf-8", errors="ignore").strip()
raw_low = raw.lower()
rc = int(os.environ.get("R5_REN_RC", "0") or "0")

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
    if not load_cache("cli_prompted", "cli_requested_interactive_input"):
        print(json.dumps(wrap_attributes({}, False, "cli_prompted", "none", "cli_requested_interactive_input")))
    raise SystemExit(0)

if rc == 124 or any(x in raw_low for x in ["terminated", "killed", "timed out", "timeout"]):
    if not load_cache("timeout", f"http_get_timed_out_or_killed (rc={rc})"):
        print(json.dumps(wrap_attributes({}, False, "timeout", "none", f"http_get_timed_out_or_killed (rc={rc})")))
    raise SystemExit(0)

auth_markers = ["unauthorized", "forbidden", "invalid token"]
if any(x in raw_low for x in auth_markers):
    if not load_cache("unauthorized", "auth_failed"):
        print(json.dumps(wrap_attributes({}, False, "unauthorized", "none", "auth_failed")))
    raise SystemExit(0)

blocks = re.findall(r"\{.*\}", raw, flags=re.S)
if not blocks:
    if not load_cache("no_payload", "no_json_in_output"):
        print(json.dumps(wrap_attributes({}, False, "no_payload", "none", "no_json_in_output")))
    raise SystemExit(0)

blob = blocks[-1]

# Prefer strict JSON first; fall back to literal_eval
try:
    obj = json.loads(blob)
except Exception:
    try:
        safe = blob.replace("true", "True").replace("false", "False").replace("null", "None")
        obj = ast.literal_eval(safe)
    except Exception:
        if not load_cache("parse_failure", "parse_error"):
            print(json.dumps(wrap_attributes({}, False, "parse_failure", "none", "parse_error")))
        raise SystemExit(0)

attrs = None
if isinstance(obj, dict) and "data" in obj and isinstance(obj.get("data"), dict):
    d = obj["data"]
    if isinstance(d.get("attributes"), dict):
        attrs = d["attributes"]
elif isinstance(obj, dict):
    attrs = obj

if not isinstance(attrs, dict):
    if not load_cache("no_attributes", "no_attributes_found"):
        print(json.dumps(wrap_attributes({}, False, "no_attributes", "none", "no_attributes_found")))
    raise SystemExit(0)

if not attrs:
    if not load_cache("empty_attributes", "endpoint_returned_empty_attributes"):
        print(json.dumps(wrap_attributes({}, False, "empty_attributes", "live", "endpoint_returned_empty_attributes")))
    raise SystemExit(0)

out = wrap_attributes(attrs, True, None, "live")
CACHE_JSON.write_text(json.dumps(out), encoding="utf-8")
print(json.dumps(out))
PY
