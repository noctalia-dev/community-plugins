#!/bin/sh
# internal-keyboard - switch one keyboard off for the graphical session while
# leaving the TTY consoles fully usable.
#
#   internal-keyboard status        report the current state (no root needed)
#   internal-keyboard devices       list the keyboards that can be switched
#   internal-keyboard on            hand the keyboard back to the compositor
#   internal-keyboard off           make libinput ignore the keyboard
#   internal-keyboard toggle        flip the current state
#   internal-keyboard select NAME   switch this keyboard from now on (root)
#
# "off" creates /run/internal-keyboard/disabled and re-announces the keyboard to
# udev. On the add pass /etc/udev/rules.d/90-internal-keyboard.rules runs and
# sets LIBINPUT_IGNORE_DEVICE=1, so libinput's evdev_device_create() discards
# the device and the compositor stops receiving its key events.
#
# remove+add rather than a plain "change" event is deliberate: libinput reads
# that property only when a device appears, so a change event does nothing.
#
# /run is tmpfs, so the flag never survives a reboot. The kernel side
# (i8042/atkbd) is untouched, which is why the TTY consoles keep working and the
# keyboard can always be re-enabled there.
set -eu

CONFIG_DIR=/etc/internal-keyboard
CONFIG=$CONFIG_DIR/device-name
RULE=/etc/udev/rules.d/90-internal-keyboard.rules
FLAG=/run/internal-keyboard/disabled

die() {
    echo "internal-keyboard: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
usage: internal-keyboard [status|devices|on|off|toggle|select NAME]

  status         state=on|off, device=<name>, installed=0|1, available=0|1, nodes=...
  devices        keyboards that can be switched, * marks the current one
  on             enable the selected keyboard in the graphical session
  off            disable it there (TTY consoles keep working)
  toggle         flip the current state
  select NAME    switch NAME from now on; re-renders the udev rule (root)
EOF
}

# Names of input devices that declare a keyboard handler, one per line,
# deduplicated (one physical keyboard can expose several event nodes).
keyboard_names() {
    name=
    seen=
    while IFS= read -r line; do
        case $line in
            'N: Name="'*)
                name=${line#N: Name=\"}
                name=${name%\"}
                ;;
            'H: Handlers='*)
                case $line in
                    *kbd*)
                        case $seen in
                            *"|$name|"*) ;;
                            *)
                                seen="$seen|$name|"
                                printf '%s\n' "$name"
                                ;;
                        esac
                        ;;
                esac
                name=
                ;;
            '') name= ;;
        esac
    done </proc/bus/input/devices
}

# A keyboard declares a wide key bitmap. Power buttons, video buses and the PC
# speaker also claim a keyboard handler but only carry a handful of keys, which
# makes the device list unreadable, so `devices` filters them out. Selection is
# not filtered: any device with a keyboard handler can be chosen.
looks_like_keyboard() { # $1 = device name
    for node in $(event_nodes_for "$1"); do
        [ -r "/sys/class/input/$node/device/capabilities/key" ] || continue
        keys=
        IFS= read -r keys <"/sys/class/input/$node/device/capabilities/key" || true
        if [ "${#keys}" -ge 32 ]; then
            return 0
        fi
    done
    return 1
}

# The selected keyboard, or nothing when setup.sh has not run yet.
configured_name() {
    [ -r "$CONFIG" ] || return 0
    name=
    IFS= read -r name <"$CONFIG" || true
    printf '%s\n' "$name"
}

device_name() {
    name=$(configured_name)
    [ -n "$name" ] || die "$CONFIG is missing; run setup.sh from the plugin directory"
    printf '%s\n' "$name"
}

# Event node names ("event3") that belong to $1.
event_nodes_for() {
    for sysfs in /sys/class/input/event*; do
        [ -r "$sysfs/device/name" ] || continue
        entry=
        IFS= read -r entry <"$sysfs/device/name" || true
        if [ "$entry" = "$1" ]; then
            printf '%s\n' "${sysfs##*/}"
        fi
    done
    return 0
}

# Value of LIBINPUT_IGNORE_DEVICE as recorded in the udev database.
ignore_flag() {
    udevadm info --query=property --name="/dev/input/$1" \
        --property=LIBINPUT_IGNORE_DEVICE --value 2>/dev/null || true
}

# Synthetic unplug and re-appearance of one event node: libinput forgets the
# device, then re-reads the property while the rules run again.
announce() {
    udevadm trigger --action=remove --sysname-match="$1" >/dev/null 2>&1 || true
    udevadm settle --timeout=5 >/dev/null 2>&1 || true
    udevadm trigger --action=add --sysname-match="$1" >/dev/null 2>&1 || true
    udevadm settle --timeout=5 >/dev/null 2>&1 || true
}

state_of() { # $1 = device name
    nodes=$(event_nodes_for "$1")
    if [ -n "$nodes" ]; then
        for node in $nodes; do
            if [ "$(ignore_flag "$node")" = 1 ]; then
                printf 'off\n'
                return 0
            fi
        done
        printf 'on\n'
    elif [ -e "$FLAG" ]; then
        # No event node right now (docked, hot-unplugged): trust the saved intent.
        printf 'off\n'
    else
        printf 'on\n'
    fi
}

status() {
    name=$(device_name)
    nodes=$(event_nodes_for "$name")
    list=
    available=0
    for node in $nodes; do
        list="${list:+$list }$node"
        available=1
    done
    # `installed` is about the system side (rule + selected device), not about the
    # keyboard being plugged in: the tile uses it to offer the setup step instead of
    # pretending the backend is ready when the udev rule went missing.
    installed=0
    if [ -r "$RULE" ] && [ -r "$CONFIG" ]; then
        installed=1
    fi
    printf 'state=%s\n' "$(state_of "$name")"
    printf 'device=%s\n' "$name"
    printf 'installed=%s\n' "$installed"
    printf 'available=%s\n' "$available"
    printf 'nodes=%s\n' "$list"
}

devices() {
    current=$(configured_name)
    keyboard_names | while IFS= read -r name; do
        looks_like_keyboard "$name" || continue
        if [ "$name" = "$current" ]; then
            printf '* %s\n' "$name"
        else
            printf '  %s\n' "$name"
        fi
    done
}

# Both rules match one device name, so this plugin never touches the ignore
# policy of any other input device. Selecting another keyboard re-announces the
# old and the new event node, which is enough to drop a property that no rule
# sets any more.
write_rule() { # $1 = device name
    cat >"$RULE" <<EOF
# Keyboard switch for goldesquemoon/internal-keyboard. Do not edit.
#
# Only the selected keyboard is matched: ignore policies that other rules set
# for unrelated devices are left untouched. libinput reads the property only when
# a device appears, which is why the backend re-announces the event node instead
# of sending a plain udev "change" event.
ACTION!="remove", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="$1", TEST=="/run/internal-keyboard/disabled", ENV{LIBINPUT_IGNORE_DEVICE}="1"
ACTION!="remove", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="$1", TEST!="/run/internal-keyboard/disabled", ENV{LIBINPUT_IGNORE_DEVICE}="0"
EOF
    chmod 0644 "$RULE"
}

select_device() { # $1 = device name
    target=${1:-}
    [ -n "$target" ] || die "select needs a device name; see 'internal-keyboard devices'"
    case $target in
        *'"'* | *\\*)
            die "device name contains characters that cannot go into a udev rule"
            ;;
    esac

    # Device names contain spaces, so compare line by line.
    known=0
    names=$(keyboard_names)
    old_ifs=$IFS
    IFS='
'
    for candidate in $names; do
        if [ "$candidate" = "$target" ]; then
            known=1
        fi
    done
    IFS=$old_ifs
    [ "$known" -eq 1 ] || die "no keyboard named '$target'; run 'internal-keyboard devices'"

    previous=$(configured_name)
    if ! { mkdir -p "$CONFIG_DIR" &&
        printf '%s\n' "$target" >"$CONFIG" &&
        chmod 0644 "$CONFIG" &&
        write_rule "$target"; } 2>/dev/null; then
        die "root required: sudo internal-keyboard select \"$target\""
    fi

    udevadm control --reload-rules >/dev/null 2>&1 || true
    for name in "$previous" "$target"; do
        [ -n "$name" ] || continue
        for node in $(event_nodes_for "$name"); do
            announce "$node"
        done
    done
}

apply() { # $1 = on | off
    if [ "$1" = off ]; then
        { mkdir -p "${FLAG%/*}" && : >"$FLAG"; } 2>/dev/null ||
            die "root required: sudo internal-keyboard off"
    else
        rm -f "$FLAG" 2>/dev/null ||
            die "root required: sudo internal-keyboard on"
    fi

    name=$(device_name)
    nodes=$(event_nodes_for "$name")
    if [ -z "$nodes" ]; then
        echo "internal-keyboard: no event node found for '$name'; the state applies on the next hotplug" >&2
    fi
    for node in $nodes; do
        announce "$node"
    done

    expected=0
    if [ "$1" = off ]; then
        expected=1
    fi
    for node in $nodes; do
        actual=$(ignore_flag "$node")
        actual=${actual:-0}
        if [ "$actual" != "$expected" ]; then
            echo "internal-keyboard: warning: $node has LIBINPUT_IGNORE_DEVICE=$actual, expected $expected" >&2
            echo "internal-keyboard: check $RULE, then run 'udevadm control --reload-rules'" >&2
        fi
    done
}

case ${1:-status} in
    status)
        status
        ;;
    devices)
        devices
        ;;
    select)
        select_device "${2:-}"
        status
        ;;
    on | off)
        apply "$1"
        status
        ;;
    toggle)
        if [ "$(state_of "$(device_name)")" = off ]; then
            apply on
        else
            apply off
        fi
        status
        ;;
    -h | --help | help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
