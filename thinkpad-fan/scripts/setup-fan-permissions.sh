#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ThinkPad fan-control permissions setup.
#
# Lets the plugin write /proc/acpi/ibm/fan at runtime WITHOUT root:
#   1. enables thinkpad_acpi fan_control=1 (needed for manual control),
#   2. installs a udev rule that chmods the file world-writable on every boot.
#
# Usage:  sudo ./setup-fan-permissions.sh
# A reboot (or module reload) may be needed if fan_control was just enabled.
# ---------------------------------------------------------------------------
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "Error: run as root, e.g. sudo $0" >&2
  exit 1
fi

MODPROBE_FILE="/etc/modprobe.d/thinkpad_acpi.conf"
RULE_FILE="/etc/udev/rules.d/99-thinkpad-fan.rules"

# 1. Enable manual fan control in the kernel module.
if [ -f /sys/module/thinkpad_acpi/parameters/fan_control ] \
   && [ "$(cat /sys/module/thinkpad_acpi/parameters/fan_control)" = "N" ]; then
  echo "Enabling thinkpad_acpi fan_control=1..."
  echo "options thinkpad_acpi fan_control=1" >"${MODPROBE_FILE}"
  echo "  -> reboot (or reload thinkpad_acpi) required to apply."
fi

# 2. Persistent udev rule so the file is writable on every boot.
echo "Writing ${RULE_FILE}..."
echo 'SUBSYSTEM=="platform", DRIVERS=="thinkpad_acpi", RUN+="/bin/chmod 0666 /proc/acpi/ibm/fan"' >"${RULE_FILE}"

echo "Reloading udev rules..."
udevadm control --reload-rules
udevadm trigger

# 3. Apply immediately for the current session.
if [ -f /proc/acpi/ibm/fan ]; then
  chmod 0666 /proc/acpi/ibm/fan || true
  echo "Done. If manual control still fails, reboot to apply fan_control=1."
else
  echo "Note: /proc/acpi/ibm/fan not found — is the thinkpad_acpi module loaded?"
fi
