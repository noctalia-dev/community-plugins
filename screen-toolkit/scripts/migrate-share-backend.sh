#!/usr/bin/env bash
# migrate-share-backend.sh — upgrade migration
# If share-backend is not set, infer a concrete backend from the old auto rule
# (x02 when an x02 API key exists, otherwise uguu) and write it to settings.toml.
#
# Usage: bash migrate-share-backend.sh
# Idempotent: exits immediately when share-backend is already set.

set -euo pipefail

SETTINGS="${XDG_STATE_HOME:-$HOME/.local/state}/noctalia/settings.toml"
SECTION='[plugin_settings."alexander/screen-toolkit"]'

if [ ! -f "$SETTINGS" ]; then
  echo "settings.toml not found, skipping" >&2
  exit 0
fi

if grep -qE '^share-backend = ' "$SETTINGS"; then
  echo "share-backend already set, skipping"
  exit 0
fi

# Only fill x02 when an x02 key exists; otherwise keep the default backend (uguu).
if ! grep -qE '^x02-api-key = "[^"]+"' "$SETTINGS"; then
  echo "no x02 key, keeping default backend, skipping"
  exit 0
fi
BACKEND="x02"
echo "migrating: x02 key found, writing share-backend = x02"

awk -v section="$SECTION" -v backend="$BACKEND" '
  $0 == section && !done {
    print
    print "share-backend = \"" backend "\""
    done = 1
    next
  }
  { print }
  END {
    if (!done) {
      print ""
      print section
      print "share-backend = \"" backend "\""
    }
  }
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

echo "wrote share-backend = \"$BACKEND\""
