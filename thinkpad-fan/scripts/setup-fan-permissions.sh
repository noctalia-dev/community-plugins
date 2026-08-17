#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ThinkPad fan-control permissions setup.
#
# Lets the plugin write /proc/acpi/ibm/fan at runtime WITHOUT root, and without
# handing that capability to every process on the machine:
#   1. enables thinkpad_acpi fan_control=1 (needed for manual control) through a
#      plugin-specific file in /etc/modprobe.d,
#   2. creates the `fan_ctl` group and adds you to it,
#   3. installs a udev rule that gives *that group* write access to
#      /proc/acpi/ibm/fan on every boot (mode 0664, not world-writable).
#
# Usage:  sudo ./setup-fan-permissions.sh
# Idempotent -- safe to re-run.
#
# Afterwards: log out and back in so the group membership applies. A reboot (or
# module reload) is additionally needed if fan_control was just enabled.
# ---------------------------------------------------------------------------
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "Error: run as root, e.g. sudo $0" >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-${1:-}}"
if [ -z "${TARGET_USER}" ]; then
  echo "Error: could not determine the target user (run via sudo, not as raw root)." >&2
  exit 1
fi

GROUP_NAME=fan_ctl
FAN_PATH=/proc/acpi/ibm/fan
MODPROBE_FILE=/etc/modprobe.d/99-noctalia-thinkpad-fan.conf
RULE_FILE=/etc/udev/rules.d/99-noctalia-thinkpad-fan.rules

# The Noctalia v4 version of this plugin installed a rule that made
# /proc/acpi/ibm/fan world-writable. Leaving it in place would silently undo the
# group-scoped access set up below on the next boot, so it is removed -- but only
# when its contents still match that exact line, so a file of the same name
# belonging to the user or to another tool is never touched.
LEGACY_RULE_FILE=/etc/udev/rules.d/99-thinkpad-fan.rules
LEGACY_RULE_CONTENT='SUBSYSTEM=="platform", DRIVERS=="thinkpad_acpi", RUN+="/bin/chmod 0666 /proc/acpi/ibm/fan"'

if [ ! -w "$(dirname "${RULE_FILE}")" ]; then
  echo "Cannot write to $(dirname "${RULE_FILE}") -- this looks like an immutable" >&2
  echo "/etc (e.g. NixOS, where udev rules are generated from system config)." >&2
  echo "See this plugin's README.md for the declarative NixOS setup instead." >&2
  exit 1
fi

CHGRP_BIN="$(command -v chgrp)"
CHMOD_BIN="$(command -v chmod)"

# 1. Enable manual fan control in the kernel module.
#    Written unconditionally: if thinkpad_acpi is not loaded yet, the runtime
#    parameter cannot be inspected, and skipping the file would leave the user
#    without the option that manual control requires.
#    Setting the same option twice from two files is harmless, so any
#    pre-existing thinkpad_acpi config is left untouched.
echo "Writing ${MODPROBE_FILE}..."
echo "options thinkpad_acpi fan_control=1" >"${MODPROBE_FILE}"

# 2. A dedicated group, so write access is scoped to members instead of everyone.
echo "Creating group '${GROUP_NAME}' (if missing) and adding ${TARGET_USER}..."
getent group "${GROUP_NAME}" >/dev/null || groupadd "${GROUP_NAME}"
usermod -aG "${GROUP_NAME}" "${TARGET_USER}"

# 3. Persistent udev rule so the group keeps its access on every boot.
#    /proc/acpi/ibm/fan is recreated (root:root 0644) whenever thinkpad_acpi is
#    loaded, so the ownership/mode have to be reapplied on each bind.
echo "Writing ${RULE_FILE}..."
cat >"${RULE_FILE}" <<EOF
ACTION=="add|bind", SUBSYSTEM=="platform", DRIVER=="thinkpad_acpi", RUN+="${CHGRP_BIN} ${GROUP_NAME} ${FAN_PATH}", RUN+="${CHMOD_BIN} 0664 ${FAN_PATH}"
EOF

if [ -f "${LEGACY_RULE_FILE}" ] \
   && [ "$(cat "${LEGACY_RULE_FILE}")" = "${LEGACY_RULE_CONTENT}" ]; then
  echo "Removing ${LEGACY_RULE_FILE}: it is the v4 plugin's rule, and it would"
  echo "  make ${FAN_PATH} world-writable again on the next boot."
  rm -f "${LEGACY_RULE_FILE}"
fi

echo "Reloading udev rules..."
udevadm control --reload-rules
udevadm trigger --action=bind --subsystem-match=platform

# 4. Apply to the running session too, so no reboot is needed for the permissions.
if [ -f "${FAN_PATH}" ]; then
  chgrp "${GROUP_NAME}" "${FAN_PATH}"
  chmod 0664 "${FAN_PATH}"
  echo
  echo "Done. Log out and back in so your new '${GROUP_NAME}' membership applies."
else
  echo
  echo "Done, but ${FAN_PATH} does not exist -- is the thinkpad_acpi module loaded?"
  echo "It will be set up on the next boot."
fi

if [ ! -f /sys/module/thinkpad_acpi/parameters/fan_control ] \
   || [ "$(cat /sys/module/thinkpad_acpi/parameters/fan_control)" != "Y" ]; then
  echo "Reboot (or reload thinkpad_acpi) to apply fan_control=1; until then,"
  echo "changing the fan level will fail."
fi
