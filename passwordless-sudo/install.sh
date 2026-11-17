#!/bin/bash -p
# Installs the root-owned helper used by the Passwordless Sudo plugin.
#
#   sudo ./install.sh                 install or update the helper
#   pkexec /bin/bash install.sh --enable 15
#                                     install, then enable in the same prompt
#   sudo ./install.sh --uninstall     revoke grants and remove everything
#
# The helper must live outside the (user-writable) plugin directory: the root
# expiry timer runs it without authentication.

set -euo pipefail
umask 022
export PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin

readonly SRC="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/bin/noctalia-sudo-passwordless"
readonly DEST=/usr/local/bin/noctalia-sudo-passwordless
readonly TMPFILES_CONF=/etc/tmpfiles.d/noctalia-nopasswd-sudo.conf

((EUID == 0)) || exec sudo -- /bin/bash "${BASH_SOURCE[0]}" "$@"

case "${1:-}" in
  --uninstall)
    rm -f -- /etc/sudoers.d/99-noctalia-nopasswd-* /etc/sudoers.d/99-noctalia-permanent-nopasswd-*
    rm -f -- "$DEST" "$TMPFILES_CONF"
    echo "Removed the helper and all passwordless sudo grants it created."
    exit 0
    ;;
esac

[[ -f $SRC ]] || { echo "Missing $SRC" >&2; exit 1; }
bash -n "$SRC"
install -D -o root -g root -m 0755 -- "$SRC" "$DEST"
install -D -o root -g root -m 0644 /dev/stdin "$TMPFILES_CONF" <<'EOF'
# Created by noctalia-sudo-passwordless. Timed passwordless sudo grants use
# transient expiry timers that do not survive a reboot, so early boot removes
# every remaining timed grant. sudo also enforces each grant's NOTAFTER deadline.
r! /etc/sudoers.d/99-noctalia-nopasswd-*
EOF
echo "Installed $DEST"

if [[ ${1:-} == --enable ]]; then
  (($# == 2)) || { echo "Usage: install.sh --enable MINUTES|permanent" >&2; exit 1; }
  exec "$DEST" __enable "$2"
fi
