#!/bin/sh
# One-time setup for the charge-mode plugin. Runs as root (pkexec or sudo) and
# is idempotent: it installs a udev rule that chowns the battery charge_types
# attribute to the invoking user, so later writes need no privilege.
set -eu

uid="${PKEXEC_UID:-${SUDO_UID:-}}"
if [ -z "$uid" ]; then
  echo "charge-mode: cannot determine the invoking user (PKEXEC_UID/SUDO_UID unset)." >&2
  exit 1
fi

rules=/etc/udev/rules.d
if [ ! -d "$rules" ] || [ ! -w "$rules" ]; then
  cat >&2 <<'EOF'
charge-mode: /etc/udev/rules.d is not writable (NixOS or another immutable-/etc
setup). Add the rule declaratively instead, see the plugin README:

  ACTION=="add|change", SUBSYSTEM=="power_supply", ATTR{type}=="Battery", \
    TEST=="charge_types", RUN+="/bin/chown <you> /sys%p/charge_types"
EOF
  exit 1
fi

printf 'ACTION=="add|change", SUBSYSTEM=="power_supply", ATTR{type}=="Battery", TEST=="charge_types", RUN+="/bin/chown %s /sys%%p/charge_types"\n' \
  "$uid" >"$rules/99-charge-mode.rules"

# Apply right away instead of waiting for the next boot or replug.
for attr in /sys/class/power_supply/*/charge_types; do
  if [ -e "$attr" ]; then
    chown "$uid" "$attr"
  fi
done

udevadm control --reload-rules
udevadm trigger --action=change --subsystem-match=power_supply

echo "charge-mode: installed $rules/99-charge-mode.rules for uid $uid"
