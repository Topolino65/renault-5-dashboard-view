#!/usr/bin/env bash
set -euo pipefail

BASE="/config/renault"

export HOME="$BASE"
export XDG_CONFIG_HOME="$BASE"
export XDG_DATA_HOME="$BASE"

LOG="$BASE/renault_api_login.log"
CREDS="$BASE/.credentials/renault-api.json"
REN_CLI="$BASE/.venv/bin/renault-api"

cd "$BASE"

if [ -f "$BASE/.venv/bin/activate" ]; then
  . "$BASE/.venv/bin/activate"
fi

# Serialize all renault-api usage (prevents creds JSON being read/written concurrently)
LOCK="$BASE/.renault_api.lock"
exec 9>"$LOCK"

locked=0
for i in $(seq 1 90); do
  if flock -n 9; then
    locked=1
    break
  fi
  sleep 1
done

if [ "$locked" -ne 1 ]; then
  echo "[$(date -Iseconds)] WARNING: lock not acquired; proceeding anyway" >>"$LOG"
fi

{
  echo "[$(date -Iseconds)] Starting renault-api login"
  echo "HOME=$HOME XDG_CONFIG_HOME=$XDG_CONFIG_HOME XDG_DATA_HOME=$XDG_DATA_HOME"
  echo "REN_CLI=$REN_CLI"
  "$REN_CLI" --version || true

  # Self-heal corrupt creds JSON
  if [ -f "$CREDS" ]; then
    python3 -m json.tool "$CREDS" >/dev/null 2>&1 || {
      echo "[$(date -Iseconds)] WARNING: creds JSON corrupt; backing up + removing: $CREDS"
      cp -a "$CREDS" "${CREDS}.bak.$(date +%Y%m%d-%H%M%S)" || true
      rm -f "$CREDS"
    }
  fi

  RC=0
  timeout 60s env HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_DATA_HOME="$XDG_DATA_HOME" \
    "$REN_CLI" login --user "<your-username>" --password "<your-password>" </dev/null || RC=$?

  echo "[$(date -Iseconds)] Finished renault-api login (rc=$RC)"
} >>"$LOG" 2>&1
