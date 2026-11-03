#!/bin/sh
# setup.sh - install the system side of the Internal Keyboard plugin.
#
#   sudo ./setup.sh [--device NAME] [--user NAME]
#
# Installs /usr/local/bin/internal-keyboard and /etc/sudoers.d/internal-keyboard,
# then hands the rest to `internal-keyboard select`, which writes
# /etc/internal-keyboard/device-name and the udev rule for the chosen keyboard.
# Re-run it to change the keyboard or to repair a lost rule; ./uninstall.sh
# removes everything again.
set -eu

PLUGIN_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=/usr/local/bin/internal-keyboard
SUDOERS=/etc/sudoers.d/internal-keyboard

die() {
    echo "setup.sh: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
usage: sudo ./setup.sh [--device NAME] [--user NAME]

  --device NAME  keyboard to switch; defaults to the built-in PS/2 keyboard on
                 i8042/serio0 (see: internal-keyboard devices)
  --user NAME    user allowed to switch it without a password (default: $SUDO_USER)
EOF
}

target_user=${SUDO_USER:-}
device=

while [ $# -gt 0 ]; do
    case $1 in
        --device)
            [ $# -ge 2 ] || die "--device needs a value"
            device=$2
            shift 2
            ;;
        --user)
            [ $# -ge 2 ] || die "--user needs a value"
            target_user=$2
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument '$1' (try --help)"
            ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "root required: sudo $0"

for tool in udevadm visudo install; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done

if [ -z "$target_user" ] || [ "$target_user" = root ]; then
    die "cannot tell which user to authorize; run 'sudo ./setup.sh' (or pass --user NAME)"
fi
id "$target_user" >/dev/null 2>&1 || die "unknown user '$target_user'"

install -m 0755 -o root -g root "$PLUGIN_DIR/internal-keyboard.sh" "$BIN"
echo "==> $BIN"

# Passwordless, but only for this one root-owned script and only for the
# subcommands that change state; `status` and `devices` need no privileges.
cat >"$SUDOERS" <<EOF
# Installed by the Noctalia plugin goldesquemoon/internal-keyboard.
$target_user ALL=(root) NOPASSWD: $BIN on, $BIN off, $BIN toggle, $BIN select *
EOF
chmod 0440 "$SUDOERS"
if ! visudo -c -f "$SUDOERS" >/dev/null; then
    rm -f "$SUDOERS"
    die "sudoers entry rejected by visudo"
fi
echo "==> $SUDOERS"

echo "==> keyboards:"
"$BIN" devices

if [ -z "$device" ]; then
    # The built-in PS/2 keyboard sits on i8042/serio0 on virtually every laptop.
    # Matching the sysfs path keeps detection independent of the localized name.
    device=$(
        for sysfs in /sys/class/input/event*; do
            case $(readlink -f "$sysfs/device" 2>/dev/null) in
                */i8042/serio0/*) ;;
                *) continue ;;
            esac
            [ -r "$sysfs/device/name" ] || continue
            head -n1 "$sysfs/device/name"
            break
        done
    )
    [ -n "$device" ] || die "no built-in keyboard found on i8042/serio0; pass --device NAME"
fi

"$BIN" select "$device"
"$BIN" on

echo
echo "done. enable the plugin, then add the tile and (optionally) a keybind:"
echo "  noctalia msg plugins enable goldesquemoon/internal-keyboard"
echo "  noctalia msg config-reload"
echo '  Settings -> Control center -> Shortcuts -> "Internal Keyboard"'
echo '  Keybind: Settings -> Plugins -> Internal Keyboard shows the command to bind.'
