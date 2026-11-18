#!/usr/bin/env bash
# Run the plugin test suite. The system luau binary has no loadfile, so each
# case is built by concatenating stubs + entry + assertions into a temp file.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_case() {
  cat "$root/tests/stubs.lua" "$root/$1" "$root/tests/$2" > "$tmp/case.lua"
  luau "$tmp/case.lua"
}

run_case service.luau test_service.lua
# Widget needs a published snapshot: seed it with a service run first.
cat "$root/tests/stubs.lua" "$root/service.luau" "$root/widget.luau" "$root/tests/test_widget.lua" > "$tmp/widget.lua"
luau "$tmp/widget.lua"
# Panel reads the service snapshot: service + its tests act as the seed.
cat "$root/tests/stubs.lua" "$root/service.luau" "$root/tests/test_service.lua" \
  "$root/panel.luau" "$root/tests/test_panel.lua" > "$tmp/panel.lua"
luau "$tmp/panel.lua"
# Q30 headphone profile: preset must precede stubs (ACTIVE_PROFILE default).
{ echo 'ACTIVE_PROFILE = "q30"'; cat "$root/tests/stubs.lua" "$root/service.luau" "$root/tests/test_q30.lua"; } > "$tmp/q30svc.lua"
luau "$tmp/q30svc.lua"
{ echo 'ACTIVE_PROFILE = "q30"'; cat "$root/tests/stubs.lua" "$root/service.luau" "$root/tests/test_q30.lua" "$root/panel.luau" "$root/tests/test_q30panel.lua"; } > "$tmp/q30panel.lua"
luau "$tmp/q30panel.lua"
echo "ALL TESTS PASSED"
