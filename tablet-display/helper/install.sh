#!/bin/bash
#
# Installs (or removes) the Tablet Display port helper.
#
#   sudo ./install.sh            install or update
#   sudo ./install.sh --remove   remove
#
# Only needed on compositors without virtual outputs (niri). It installs two
# files: the helper, and a polkit policy that lets your logged-in session run
# it without a password.

set -euo pipefail

HERE=$(dirname "$(realpath "$0")")
HELPER_DST=/usr/local/libexec/noctalia-tablet-display/port-helper
POLICY_DST=/usr/share/polkit-1/actions/io.github.iwasironman.tablet-display.policy

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0 ${*:-}" >&2; exit 1; }

if [[ ${1:-} == --remove ]]; then
  if [[ -x $HELPER_DST ]]; then
    for c in $("$HELPER_DST" list); do "$HELPER_DST" off "$c" || true; done
  fi
  rm -f "$HELPER_DST" "$POLICY_DST"
  rmdir --ignore-fail-on-non-empty "$(dirname "$HELPER_DST")" 2>/dev/null || true
  echo "Removed the Tablet Display port helper."
  exit 0
fi

command -v pkexec >/dev/null || { echo "pkexec (polkit) is required but not installed." >&2; exit 1; }

install -Dm755 -o root -g root "$HERE/port-helper" "$HELPER_DST"
install -Dm644 -o root -g root "$HERE/io.github.iwasironman.tablet-display.policy" "$POLICY_DST"
echo "Installed:"
echo "  $HELPER_DST (version $("$HELPER_DST" version))"
echo "  $POLICY_DST"
echo "Lockdown: $(cat /sys/kernel/security/lockdown 2>/dev/null || echo unknown)"
