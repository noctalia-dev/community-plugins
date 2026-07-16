#!/usr/bin/env bash
# One-time setup: lets the "lenovoctl" group toggle Lenovo IdeaPad/Legion ACPI
# features (currently battery conservation_mode) without root.
#
# Run via sudo (the plugin invokes this itself, in a terminal, the first time
# a write fails). Idempotent -- safe to re-run.
#
# NOTE: udev's GROUP=/MODE= rule keys only apply to the /dev device node they
# create, NOT to arbitrary sysfs ATTR files (see udev(7)) -- a rule matching
# ATTR{conservation_mode} with GROUP=/MODE= is a silent no-op here. We use
# RUN+= to chmod/chgrp the resolved sysfs path directly instead.
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Run this with sudo." >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-${1:-}}"
if [ -z "$TARGET_USER" ]; then
  echo "No target user specified (expected \$SUDO_USER or \$1)." >&2
  exit 1
fi

GROUP_NAME=lenovoctl
RULE_FILE=/etc/udev/rules.d/99-ideapad-conservation-mode.rules

if [ ! -w "$(dirname "$RULE_FILE")" ]; then
  echo "Cannot write to $(dirname "$RULE_FILE") -- this looks like an immutable" >&2
  echo "/etc (e.g. NixOS, where udev rules are generated from system config)." >&2
  echo "See this plugin's README.md for the declarative NixOS setup instead." >&2
  exit 1
fi

CHGRP_BIN="$(command -v chgrp)"
CHMOD_BIN="$(command -v chmod)"

echo "Creating group '$GROUP_NAME' (if missing) and adding $TARGET_USER..."
getent group "$GROUP_NAME" >/dev/null || groupadd "$GROUP_NAME"
usermod -aG "$GROUP_NAME" "$TARGET_USER"

echo "Writing $RULE_FILE..."
cat >"$RULE_FILE" <<EOF
ACTION=="add|change", SUBSYSTEM=="platform", DRIVER=="ideapad_acpi", RUN+="$CHGRP_BIN $GROUP_NAME /sys%p/conservation_mode", RUN+="$CHMOD_BIN 664 /sys%p/conservation_mode"
EOF

echo "Reloading udev rules..."
udevadm control --reload-rules
udevadm trigger --subsystem-match=platform

echo "Done."
