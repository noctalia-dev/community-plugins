#!/bin/sh
# setup.sh - install the system side of the Typing Stats plugin.
#
#   sudo ./setup.sh [--user NAME]
#
# Installs one udev rule that tags keyboard event nodes with uaccess, so the
# active local session can read them. The plugin counts keys, nothing else.
set -eu

PLUGIN_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RULE=/etc/udev/rules.d/72-typing-stats-input.rules
SOURCE="$PLUGIN_DIR/assets/72-typing-stats-input.rules"

die() { echo "setup.sh: $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
usage: sudo ./setup.sh [--user NAME]

  --user NAME  session user to check afterwards (default: $SUDO_USER)
USAGE
}

target_user=${SUDO_USER:-}
while [ $# -gt 0 ]; do
    case $1 in
        --user) [ $# -ge 2 ] || die "--user needs a value"; target_user=$2; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) die "unknown argument '$1' (try --help)" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "root required: sudo $0"
[ -f "$SOURCE" ] || die "missing $SOURCE"
for tool in udevadm install python3; do command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"; done

install -m 0644 -o root -g root "$SOURCE" "$RULE"
echo "==> $RULE"

udevadm control --reload-rules
udevadm trigger --subsystem-match=input --action=change
udevadm settle --timeout=5 2>/dev/null || sleep 1

echo
echo "==> keyboard event nodes:"
if [ -n "$target_user" ] && [ "$target_user" != root ] && command -v runuser >/dev/null 2>&1; then
    if runuser -u "$target_user" -- python3 "$PLUGIN_DIR/scripts/typelisten.py" --test-devices; then
        echo
        echo "done. reload the plugin (or Noctalia) if it was already running:"
        echo "  noctalia msg plugin goldesquemoon/typing-stats:counter all reload"
        exit 0
    fi
else
    python3 "$PLUGIN_DIR/scripts/typelisten.py" --test-devices || true
fi

cat <<MSG

The ACL was not applied. Log in through a display manager (logind seat), or add
the user to the input group once and log back in:

    sudo usermod -aG input ${target_user:-$USER}
MSG
exit 1
