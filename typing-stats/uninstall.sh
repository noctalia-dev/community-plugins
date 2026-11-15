#!/bin/sh
# uninstall.sh - remove the system side of the Typing Stats plugin.
#
#   sudo ./uninstall.sh
set -eu

RULE=/etc/udev/rules.d/72-typing-stats-input.rules

[ "$(id -u)" -eq 0 ] || { echo "uninstall.sh: root required: sudo $0" >&2; exit 1; }

rm -f "$RULE"
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=input --action=change
    udevadm settle --timeout=5 2>/dev/null || true
fi

cat <<'MSG'
removed the udev rule. the plugin no longer has access to keyboard event nodes
(a running listener keeps its already-open handles until it exits or Noctalia
reloads).

to remove the plugin itself:
  noctalia msg plugins disable goldesquemoon/typing-stats
MSG
