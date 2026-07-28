#!/usr/bin/env bash

# ------------------------------
# Battery Threshold Udev Setup
# ------------------------------
# This script sets up udev rules to allow a non-root user to write to
# /sys/class/power_supply/BAT0/charge_control_end_threshold.
# It creates a group 'battery_ctl' and adds the target user to this group.
#
# Usage:
#  $ sudo ./setup_rules.sh        # uses SUDO_USER (with sudo)
#  $ ./setup_rules.sh username    # use provided username (if ran as root)
# ------------------------------
set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)"
  exit 1
fi

# Determine target user
TARGET_USER=${SUDO_USER:-$1}

if [ -z "$TARGET_USER" ]; then
  echo "Error: No target user specified." >&2
  exit 1
fi

if ! getent group battery_ctl >/dev/null; then
  echo "Creating battery_ctl group..."
  groupadd battery_ctl
fi

echo "Adding $TARGET_USER to battery_ctl group..."
usermod -aG battery_ctl "$TARGET_USER"

echo "Writing udev rule to /etc/udev/rules.d/99-battery-threshold.rules..."

cat <<'EOF' >/etc/udev/rules.d/99-battery-threshold.rules
# Battery Threshold Control - udev rule
# Grants write access to charge_control_end_threshold for users in the
# 'battery_ctl' group.
SUBSYSTEM=="power_supply", KERNEL=="BAT*", \
    RUN+="/bin/chgrp battery_ctl /sys$devpath/charge_control_end_threshold", \
    RUN+="/bin/chmod g+w /sys$devpath/charge_control_end_threshold"
EOF

echo "Reloading rules..."

udevadm control --reload-rules && udevadm trigger

echo "You may need a reboot for the plugin's write access to take effect"
echo "Done!"
