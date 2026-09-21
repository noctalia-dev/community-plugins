#!/usr/bin/env bash
#
# DNF Updater - Privileged Update Helper
#
# Restricts privileged execution strictly to system package upgrades
# with validated exclusions. Prevents arbitrary command execution or
# malicious package installations.
#

set -euo pipefail

# Ensure standard, safe environment
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset IFS
unset LD_PRELOAD LD_LIBRARY_PATH PYTHONPATH PYTHONHOME DNF5_PLUGINS

# Require root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Error: dnf-updater-helper must be run as root." >&2
    exit 1
fi

ACTION="${1:-}"
if [[ "$ACTION" != "upgrade" ]]; then
    echo "Error: unsupported action '${ACTION}'. Only 'upgrade' is allowed." >&2
    exit 1
fi
shift

# Validate any remaining arguments.
VALID_ARGS=()
for arg in "$@"; do
    if [[ "$arg" =~ ^--exclude=[a-zA-Z0-9._+*-][a-zA-Z0-9._+*,-]*$ ]]; then
        VALID_ARGS+=("$arg")
    else
        echo "Error: invalid argument rejected: '$arg'" >&2
        exit 1
    fi
done

# Resolve DNF binary
DNF_BIN=""
for bin in "/usr/bin/dnf5" "/usr/bin/dnf"; do
    if [[ -x "$bin" ]]; then
        DNF_BIN="$bin"
        break
    fi
done

if [[ -z "$DNF_BIN" ]]; then
    echo "Error: neither /usr/bin/dnf5 nor /usr/bin/dnf was found." >&2
    exit 1
fi

# Execute upgrade w/o interaction
exec "$DNF_BIN" upgrade -y "${VALID_ARGS[@]}"
