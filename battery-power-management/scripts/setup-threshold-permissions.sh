#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Battery charge-threshold udev setup.
#
# Lets the plugin write /sys/class/power_supply/<BAT>/charge_control_end_threshold
# at runtime WITHOUT root: it creates a `battery_ctl` group, adds you to it, and
# grants that group write access to the attribute via a udev rule.
#
# Usage:  sudo ./setup-threshold-permissions.sh [BATTERY_DEVICE]
#         BATTERY_DEVICE defaults to BAT*, which covers every battery on the
#         machine. Pass a name (e.g. BAT1) to scope the rule to one of them.
#
# The rule is installed under a plugin-specific filename so it cannot collide
# with the one shipped by the separate `battery-threshold` plugin, which uses
# the same `battery_ctl` group. Idempotent -- safe to re-run.
#
# Run once, then log out and back in for the group change to take effect.
# ---------------------------------------------------------------------------
set -euo pipefail

BAT="${1:-BAT*}"
GROUP_NAME=battery_ctl
RULE_FILE=/etc/udev/rules.d/99-noctalia-battery-power-management.rules

if [ "${EUID}" -ne 0 ]; then
  echo "Error: run as root, e.g. sudo $0 ${BAT}" >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-}"
if [ -z "${TARGET_USER}" ]; then
  echo "Error: could not determine the target user (run via sudo, not as raw root)." >&2
  exit 1
fi

if [ ! -w "$(dirname "${RULE_FILE}")" ]; then
  echo "Cannot write to $(dirname "${RULE_FILE}") -- this looks like an immutable" >&2
  echo "/etc (e.g. NixOS, where udev rules are generated from system config)." >&2
  echo "See this plugin's README.md for the declarative NixOS setup instead." >&2
  exit 1
fi

CHGRP_BIN="$(command -v chgrp)"
CHMOD_BIN="$(command -v chmod)"

echo "Creating group '${GROUP_NAME}' (if missing) and adding ${TARGET_USER}..."
getent group "${GROUP_NAME}" >/dev/null || groupadd "${GROUP_NAME}"
usermod -aG "${GROUP_NAME}" "${TARGET_USER}"

# /sys$devpath resolves per matched device, so a single rule covers every
# battery when BAT is left at its BAT* default.
echo "Writing ${RULE_FILE} for ${BAT}..."
cat >"${RULE_FILE}" <<EOF
ACTION=="add|change", SUBSYSTEM=="power_supply", KERNEL=="${BAT}", RUN+="${CHGRP_BIN} ${GROUP_NAME} /sys\$devpath/charge_control_end_threshold", RUN+="${CHMOD_BIN} 0664 /sys\$devpath/charge_control_end_threshold"
EOF

echo "Reloading udev rules..."
udevadm control --reload-rules
udevadm trigger --subsystem-match=power_supply

echo
echo "Done. Log out and back in so your new group membership applies."
