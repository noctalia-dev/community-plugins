#!/usr/bin/env bash
# Launch Cider bridge for the Noctalia plugin service.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${1:-http://127.0.0.1:10767}"
STATE_DIR="${2:-$HOME/.cache/noctalia-cider}"
mkdir -p "$STATE_DIR/art"
TOKEN=""
if [[ -f "$STATE_DIR/apptoken" ]]; then
  TOKEN="$(cat "$STATE_DIR/apptoken")"
fi
pkill -f "$SCRIPT_DIR/cider_bridge.py" >/dev/null 2>&1 || true
sleep 0.2
# Token via env, not argv — `ps` must not show the Cider apptoken.
export CIDER_APPTOKEN="$TOKEN"
exec python3 "$SCRIPT_DIR/cider_bridge.py" \
  --base-url "$BASE_URL" \
  --poll 0.5 \
  --state-dir "$STATE_DIR"
