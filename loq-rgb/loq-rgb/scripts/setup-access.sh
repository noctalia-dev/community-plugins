#!/bin/sh
# setup-access.sh VID PID [IFACE]
#
# One-time setup run in a terminal by the LOQ RGB plugin: lets your *logged-in user session*
# (and nobody else) talk to your keyboard's lighting interface. It installs one udev rule, shows
# you exactly what it writes, and asks before doing anything. It never touches the network.
set -u

lower() { printf '%s' "$1" | tr 'A-F' 'a-f'; }
VID=$(lower "${1:-}")
PID=$(lower "${2:-}")
IFACE=$(lower "${3:-}")

valid4() { case "$1" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;; esac; return 1; }
valid2() { case "$1" in [0-9a-f][0-9a-f]) return 0 ;; esac; return 1; }

pause() { printf '\nPress Enter to close this window... '; read -r _ || true; }

if ! valid4 "$VID" || ! valid4 "$PID"; then
  echo "Invalid or missing USB ids (got VID='$VID' PID='$PID'). Nothing was changed."
  pause; exit 1
fi

MATCH=""
if [ -n "$IFACE" ] && valid2 "$IFACE"; then
  MATCH=", ATTRS{bInterfaceNumber}==\"$IFACE\""   # only the lighting interface, not the typing one
fi

FILE="/etc/udev/rules.d/70-noctalia-loq-rgb-$VID-$PID.rules"
RULE="SUBSYSTEM==\"hidraw\", ATTRS{idVendor}==\"$VID\", ATTRS{idProduct}==\"$PID\"$MATCH, TAG+=\"uaccess\""

cat <<MSG
LOQ RGB - one-time access setup

The plugin found a keyboard (USB $VID:$PID) whose lighting your user cannot control yet.
This will create:

  $FILE

containing:

  $RULE

"uaccess" gives access to the user currently logged in at this computer, and only to that
keyboard's lighting interface. Remove the file to undo it at any time.

MSG

printf 'Install it now? [Y/n] '
read -r ANSWER || ANSWER=n
case "$ANSWER" in [nN]*) echo "Cancelled. Nothing was changed."; pause; exit 0 ;; esac

as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo "$@"
  elif command -v pkexec >/dev/null 2>&1; then pkexec "$@"
  else echo "Neither sudo nor pkexec is available."; return 1
  fi
}

if ! {
  printf '# Installed by the Noctalia "LOQ RGB" plugin\n%s\n' "$RULE" | as_root tee "$FILE" >/dev/null &&
    as_root udevadm control --reload &&
    as_root udevadm trigger --subsystem-match=hidraw --action=change
}; then
  echo
  echo "Setup did not complete (see the messages above). Nothing else was changed."
  pause; exit 1
fi

echo
echo "Done. The plugin will notice within a few seconds."
echo "If it does not, log out and back in (the rule relies on your login session)."
pause
