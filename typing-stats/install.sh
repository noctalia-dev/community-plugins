#!/bin/sh
# install.sh - register, enable and set up the Typing Stats plugin.
#
#   ./install.sh              # user side + one sudo prompt for the udev rule
#   ./install.sh --no-setup   # only register/enable; run setup.sh later
set -eu

PLUGIN_ID="goldesquemoon/typing-stats"
REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PLUGIN_DIR="$REPO_DIR/typing-stats"
SETUP=1

for arg in "$@"; do
    case "$arg" in
        --no-setup) SETUP=0 ;;
        -h | --help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'install: unknown option %s\n' "$arg" >&2; exit 2 ;;
    esac
done

die() { printf 'install: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

have noctalia || die "noctalia CLI not found in PATH"
have python3 || die "python3 not found - the key listener needs it"
have udevadm || die "udevadm not found - install systemd"

chmod +x "$PLUGIN_DIR/setup.sh" "$PLUGIN_DIR/uninstall.sh" "$PLUGIN_DIR/scripts/typelisten.py" 2>/dev/null || true

needs_setup=0
if ! python3 "$PLUGIN_DIR/scripts/typelisten.py" --test-devices >/dev/null 2>&1; then
    needs_setup=1
fi

if [ "$needs_setup" -eq 1 ] && [ "$SETUP" -eq 1 ]; then
    if [ -t 0 ] && [ -t 1 ]; then
        printf '\nKeyboard event nodes are not readable yet. Installing the udev rule (sudo).\n'
        sudo "$PLUGIN_DIR/setup.sh" || die "setup.sh failed"
    else
        needs_setup=2
    fi
fi

source_name=$(
    noctalia msg plugins source list 2>/dev/null |
        awk -v path="$REPO_DIR" '$2 == "path" && $3 == path { print $1; exit }'
)
if [ -n "$source_name" ]; then
    printf 'source "%s" already registered -> %s\n' "$source_name" "$REPO_DIR"
else
    source_name="${SOURCE_NAME:-typing-stats}"
    noctalia msg plugins source add "$source_name" path "$REPO_DIR" >/dev/null
    printf 'registered source "%s" -> %s\n' "$source_name" "$REPO_DIR"
fi

noctalia msg plugins enable "$PLUGIN_ID" >/dev/null
printf 'enabled %s\n' "$PLUGIN_ID"
noctalia msg config-reload >/dev/null 2>&1 || true

cat <<MSG

Next steps
  1. Add the capsule to the bar: Settings -> Bar -> add widget "Typing Stats".
     It will appear as a capsule with a progress bar and the block count.

  2. Optional tiles: Settings -> Control Center -> Shortcuts ->
     "Reset typing stats" (clears the counts) and "Typing heatmap" (opens the panel).

  3. Test without typing:
     noctalia msg plugin ${PLUGIN_ID}:counter all add 100
     noctalia msg plugin ${PLUGIN_ID}:counter all reset

Verify
  noctalia msg plugins list | grep typing-stats
  python3 ${PLUGIN_DIR}/scripts/typelisten.py --test-devices
MSG

if [ "$needs_setup" -eq 2 ]; then
    printf '\nThis shell is not interactive, so the udev rule was not installed.\nRun once:\n\n  sudo %s/setup.sh\n\n' "$PLUGIN_DIR"
fi
