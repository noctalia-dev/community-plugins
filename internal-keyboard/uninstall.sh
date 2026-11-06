#!/bin/sh
# uninstall.sh - remove the system side of the Internal Keyboard plugin.
#
#   sudo ./uninstall.sh
set -eu

BIN=/usr/local/bin/internal-keyboard
CONFIG_DIR=/etc/internal-keyboard
RULE=/etc/udev/rules.d/90-internal-keyboard.rules
SUDOERS=/etc/sudoers.d/internal-keyboard
RUN_DIR=/run/internal-keyboard

[ "$(id -u)" -eq 0 ] || {
    echo "uninstall.sh: root required: sudo $0" >&2
    exit 1
}

# Enable first, so an interrupted uninstall can never leave the keyboard
# ignored by the compositor.
if [ -x "$BIN" ]; then
    "$BIN" on >/dev/null 2>&1 || true
fi

rm -f "$SUDOERS"
rm -f "$RULE"
rm -f "$BIN"
rm -rf "$CONFIG_DIR"
rm -rf "$RUN_DIR"

udevadm control --reload-rules

echo "removed. the built-in keyboard is enabled again."
