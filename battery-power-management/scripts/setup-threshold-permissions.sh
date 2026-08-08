#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Battery charge-threshold udev setup.
#
# Lets the plugin write /sys/class/power_supply/<BAT>/charge_control_end_threshold
# at runtime WITHOUT root: it creates a `battery_ctl` group, adds you to it, and
# grants that group write access to the attribute via a udev rule.
#
# Usage:  sudo ./setup-threshold-permissions.sh [BATTERY_DEVICE]
#         BATTERY_DEVICE defaults to BAT0 (match the plugin's "Battery device" setting).
#
# Run once, then log out and back in for the group change to take effect.
# ---------------------------------------------------------------------------
set -euo pipefail

BAT="${1:-BAT0}"
RULE_FILE="/etc/udev/rules.d/99-battery-threshold.rules"

if [ "${EUID}" -ne 0 ]; then
  echo "Error: run as root, e.g. sudo $0 ${BAT}" >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-}"
if [ -z "${TARGET_USER}" ]; then
  echo "Error: could not determine the target user (run via sudo, not as raw root)." >&2
  exit 1
fi

if ! getent group battery_ctl >/dev/null; then
  echo "Creating group battery_ctl..."
  groupadd battery_ctl
fi

echo "Adding ${TARGET_USER} to battery_ctl..."
usermod -aG battery_ctl "${TARGET_USER}"

echo "Writing ${RULE_FILE} for ${BAT}..."
cat >"${RULE_FILE}" <<EOF
ACTION=="add|change", SUBSYSTEM=="power_supply", KERNEL=="${BAT}", RUN+="/bin/chgrp battery_ctl /sys/class/power_supply/${BAT}/charge_control_end_threshold", RUN+="/bin/chmod 0664 /sys/class/power_supply/${BAT}/charge_control_end_threshold"
EOF

echo "Reloading udev rules..."
udevadm control --reload-rules
udevadm trigger --subsystem-match=power_supply

echo
echo "Done. Log out and back in so your new group membership applies."
