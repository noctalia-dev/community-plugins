#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_dir="$(cd "$test_dir/.." && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

# Normalize the compound assignments used by Luau for the Lua 5.4 harness.
for entry in service panel; do
  sed -E \
    -e 's/([[:alnum:]_.]+)[[:space:]]*\+=/\1 = \1 +/g' \
    -e 's/([[:alnum:]_.]+)[[:space:]]*\-=/\1 = \1 -/g' \
    "$plugin_dir/$entry.luau" > "$temp_dir/$entry.lua"
done

lua5.4 "$test_dir/new_note_test.lua" "$temp_dir/service.lua" "$temp_dir/panel.lua"
