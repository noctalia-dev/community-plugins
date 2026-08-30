#!/bin/sh
# The plugin's whole test suite:
#
#   sh tests/run-tests.sh
#
# Two halves, because the plugin has two halves. The daemon's correction
# logic is Python and is tested against the real keymap compiled from
# libxkbcommon (tests/test-layout-fix.py). The service is Luau and runs here
# against a fake Noctalia host: no compositor, no shell, no daemon.
#
# Each service case gets its own luau process — the service keeps its state
# in locals that nothing can reset, so a fresh process is the only way to
# start a case from a genuinely fresh plugin.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$here")

total_passed=0
total_failed=0
failed_cases=""

if command -v luau >/dev/null 2>&1; then
    bundle=$(mktemp -t layout-fix-tests-XXXXXX.luau)
    trap 'rm -f "$bundle"' EXIT

    for case_file in "$here"/cases/*.luau; do
        name=$(basename "$case_file" .luau)
        echo "$name"
        # The service goes inside a do...end block so that its top-level
        # locals stay its own: a helper named like one of them would
        # otherwise assign to the plugin's local instead of a global.
        {
            cat "$here/prelude.luau"
            echo "do"
            cat "$root/service.luau"
            echo "end"
            cat "$here/lib.luau" "$case_file"
        } >"$bundle"

        if output=$(luau "$bundle" 2>&1); then
            :
        else
            failed_cases="$failed_cases $name"
        fi
        echo "$output" | sed 's/^/  /'

        counts=$(echo "$output" | grep -E '^[0-9]+ passed, [0-9]+ failed$' | tail -1)
        if [ -n "$counts" ]; then
            total_passed=$((total_passed + $(echo "$counts" | cut -d' ' -f1)))
            total_failed=$((total_failed + $(echo "$counts" | cut -d' ' -f3)))
        else
            failed_cases="$failed_cases $name(crashed)"
        fi
    done
else
    echo "luau is not installed (Arch: pacman -S luau) — skipping the service cases" >&2
fi

echo
echo "correction logic"
if python3 "$here/test-layout-fix.py" "$@"; then
    :
else
    failed_cases="$failed_cases test-layout-fix.py"
fi

echo
echo "service cases: $total_passed passed, $total_failed failed"
if [ -n "$failed_cases" ] || [ "$total_failed" -gt 0 ]; then
    echo "failing:$failed_cases"
    exit 1
fi
