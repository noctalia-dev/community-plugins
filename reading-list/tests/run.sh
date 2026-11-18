#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_dir="$(cd "$test_dir/.." && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

# The production source is Luau. The plugin only uses compound assignment
# beyond Lua 5.4 syntax, so normalize that syntax for the local test harness.
sed -E \
  -e 's/([[:alnum:]_.]+)[[:space:]]*\+=/\1 = \1 +/g' \
  -e 's/([[:alnum:]_.]+)[[:space:]]*\-=/\1 = \1 -/g' \
  "$plugin_dir/service.luau" > "$temp_dir/service.lua"
sed -E \
  -e 's/([[:alnum:]_.]+)[[:space:]]*\+=/\1 = \1 +/g' \
  -e 's/([[:alnum:]_.]+)[[:space:]]*\-=/\1 = \1 -/g' \
  "$plugin_dir/panel.luau" > "$temp_dir/panel.lua"

lua "$test_dir/service_test.lua" "$temp_dir/service.lua"
lua "$test_dir/panel_smoke_test.lua" "$temp_dir/panel.lua"
