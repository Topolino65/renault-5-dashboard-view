#!/usr/bin/env bash
set -euo pipefail

export HOME="/config/renault"
export XDG_CONFIG_HOME="/config/renault"
export XDG_DATA_HOME="/config/renault"

if [ -f "/config/renault/.venv/bin/activate" ]; then
    . "/config/renault/.venv/bin/activate" 2>/dev/null || true
fi

# Use venv Python directly (more robust than the renault-api wrapper script)
REN_PY="/config/renault/.venv/bin/python"

KAM_ACCOUNT_ID="<your-account-number>"
VIN="<your-vin-number>"

RAW_OUT="/config/renault/debug_charges_raw.txt"
CACHE_JSON="/config/renault/charges_cache.json"

# Compute window in UTC using python (BusyBox/Alpine-safe)
read -r START_DATE END_DATE < <(python3 - <<'PY'
from datetime import datetime, timedelta, timezone
now = datetime.now(timezone.utc)
start = (now - timedelta(days=7)).date().isoformat()
# end = tomorrow (so we include all of today, avoids inclusive/exclusive ambiguity)
end = (now + timedelta(days=1)).date().isoformat()
print(start, end)
PY
)

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

URL="/commerce/v1/accounts/${KAM_ACCOUNT_ID}/kamereon/kca/car-adapter/v1/cars/${VIN}/charges?country=GB&brand=RENAULT&start=${START_DATE}&end=${END_DATE}"

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
from pathlib import Path
from datetime import datetime, timezone

RAW_OUT = Path("/config/renault/debug_charges_raw.txt")
CACHE_JSON = Path("/config/renault/charges_cache.json")
VIN = "<your-vin-number>"

def iso_now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()

def ensure_contract(obj, ok: bool, err: str | None, source: str, note: str | None = None):
    out = obj if isinstance(obj, dict) else {}
    if "data" not in out or not isinstance(out.get("data"), dict):
        out = {"data": {"type": "Car", "id": VIN, "attributes": {}}}

    data = out["data"]
    data.setdefault("type", "Car")
    data.setdefault("id", VIN)
    if not isinstance(data.get("attributes"), dict):
        data["attributes"] = {}

    data["ok"] = bool(ok)
    data["error"] = err
    data["source"] = source
    data["fetched_at"] = iso_now()
    if note is not None:
        data["note"] = note
    return out

def load_cache(err_code: str, note: str):
    if CACHE_JSON.exists():
        try:
            cached = json.loads(CACHE_JSON.read_text(encoding="utf-8"))
        except Exception:
            cached = {"data": {"type": "Car", "id": VIN, "attributes": {"charges": []}}}
        print(json.dumps(ensure_contract(cached, ok=False, err=err_code, source="cache", note=note)))
        return True
    return False

raw = RAW_OUT.read_text(encoding="utf-8", errors="ignore").strip()
raw_low = raw.lower()
rc = int(os.environ.get("R5_REN_RC", "0") or "0")

# Detect prompts/timeouts/aborts/auth
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
        print(json.dumps(ensure_contract({"data":{"type":"Car","id":VIN,"attributes":{"charges":[]}}}, ok=False, err="cli_prompted", source="none", note="cli_requested_interactive_input")))
    raise SystemExit(0)

# timeout(1) commonly uses rc=124 for timeouts
if rc == 124 or any(x in raw_low for x in ["terminated", "killed", "timed out", "timeout"]):
    if not load_cache("timeout", f"http_get_timed_out_or_killed (rc={rc})"):
        print(json.dumps(ensure_contract({"data":{"type":"Car","id":VIN,"attributes":{"charges":[]}}}, ok=False, err="timeout", source="none", note=f"http_get_timed_out_or_killed (rc={rc})")))
    raise SystemExit(0)

auth_markers = ["unauthorized", "forbidden", "invalid token"]
if any(x in raw_low for x in auth_markers):
    if not load_cache("unauthorized", "auth_failed"):
        print(json.dumps(ensure_contract({"data":{"type":"Car","id":VIN,"attributes":{"charges":[]}}}, ok=False, err="unauthorized", source="none", note="auth_failed")))
    raise SystemExit(0)

# Extract JSON-ish dict blob from renault-api output
blocks = re.findall(r"\{.*\}", raw, flags=re.S)
if not blocks:
    if not load_cache("no_payload", "no_json_in_output"):
        print(json.dumps(ensure_contract({"data":{"type":"Car","id":VIN,"attributes":{"charges":[]}}}, ok=False, err="no_payload", source="none", note="no_json_in_output")))
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
            print(json.dumps(ensure_contract({"data":{"type":"Car","id":VIN,"attributes":{"charges":[]}}}, ok=False, err="parse_failure", source="none", note="parse_error")))
        raise SystemExit(0)

out = ensure_contract(obj, ok=True, err=None, source="live")

# Normalize charges list existence
attrs = out["data"].get("attributes") or {}
if not isinstance(attrs, dict):
    attrs = {}
out["data"]["attributes"] = attrs
charges = attrs.get("charges", [])
if not isinstance(charges, list):
    charges = []
out["data"]["attributes"]["charges"] = charges

# Cache even if empty (but note it)
if not charges:
    out = ensure_contract(out, ok=True, err=None, source="live", note="no_charge_history_in_window")

CACHE_JSON.write_text(json.dumps(out), encoding="utf-8")
print(json.dumps(out))
PY
