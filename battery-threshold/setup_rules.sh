#!/usr/bin/env bash

# ------------------------------
# Battery Threshold Udev Setup
# ------------------------------
# This script sets up udev rules to allow a non-root user to write to
# /sys/class/power_supply/BAT*/charge_control_end_threshold.
# It creates a group 'battery_ctl' and adds the target user to this group.
#
# Usage:
#  $ ./setup_rules.sh [username] [--non-interactive|-y]
# ------------------------------
set -e

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

TARGET_USER=""
SKIP_PROMPT=false

for arg in "$@"; do
  case "$arg" in
  -y | --non-interactive)
    SKIP_PROMPT=true
    ;;
  -*)
    ;;
  *)
    if [ -z "$TARGET_USER" ]; then
      TARGET_USER="$arg"
    fi
    ;;
  esac
done

TARGET_USER="${TARGET_USER:-${SUDO_USER:-$USER}}"

if [ "$SKIP_PROMPT" = false ]; then
  echo "===================================================="
  echo " Battery Threshold Udev Setup"
  echo "===================================================="
  echo "Script location: $SCRIPT_PATH"
  echo "Target user:     $TARGET_USER"
  echo ""
  echo "Please examine the script location and contents above before proceeding."
  echo ""

  read -rp "Do you want to proceed with setup? (y/N): " CONFIRM
  case "$CONFIRM" in
  [yY][eE][sS] | [yY])
    ;;
  *)
    echo "Setup cancelled by user."
    read -rp "Press Enter to exit..."
    exit 1
    ;;
  esac
fi

# Escalate privileges via sudo only after user confirmation
if [ "$EUID" -ne 0 ]; then
  echo ""
  echo "Escalating privileges via sudo..."
  exec sudo bash "$SCRIPT_PATH" "$TARGET_USER" --non-interactive
fi

if [ -z "$TARGET_USER" ]; then
  echo "Error: No target user specified." >&2
  read -rp "Press Enter to exit..."
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

echo "Applying permissions to existing batteries..."
for threshold_file in /sys/class/power_supply/BAT*/charge_control_end_threshold; do
  if [ -f "$threshold_file" ]; then
    chgrp battery_ctl "$threshold_file" 2>/dev/null || true
    chmod g+w "$threshold_file" 2>/dev/null || true
  fi
done

echo "Reloading rules..."

udevadm control --reload-rules && udevadm trigger

echo ""
echo "Permissions applied! You may need to log out and log back in for new group membership to take full effect in active desktop sessions."
echo "Done!"
echo ""
read -rp "Press Enter to exit..."
