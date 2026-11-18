#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/bluetooth_helper.c"
BIN="$SCRIPT_DIR/bluetooth_helper"

# If binary already exists and is newer than source, exit early
if [ -f "$BIN" ] && [ -x "$BIN" ] && [ "$BIN" -nt "$SRC" ]; then
    exit 0
fi

# Detect C compiler
CC="${CC:-}"
if [ -z "$CC" ]; then
    if command -v gcc >/dev/null 2>&1; then
        CC="gcc"
    elif command -v clang >/dev/null 2>&1; then
        CC="clang"
    elif command -v cc >/dev/null 2>&1; then
        CC="cc"
    else
        echo "Error: No C compiler found (gcc, clang, or cc required)." >&2
        exit 1
    fi
fi

# Determine dbus compilation flags
DBUS_CFLAGS=""
DBUS_LIBS=""

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists dbus-1 2>/dev/null; then
    DBUS_CFLAGS="$(pkg-config --cflags dbus-1)"
    DBUS_LIBS="$(pkg-config --libs dbus-1)"
else
    # Fallback paths for common Linux distributions
    for p in /usr/include/dbus-1.0 /usr/lib/dbus-1.0/include /usr/lib64/dbus-1.0/include \
             /usr/lib/x86_64-linux-gnu/dbus-1.0/include /usr/lib/aarch64-linux-gnu/dbus-1.0/include \
             /usr/lib/arm-linux-gnueabihf/dbus-1.0/include; do
        if [ -d "$p" ]; then
            DBUS_CFLAGS="$DBUS_CFLAGS -I$p"
        fi
    done
    DBUS_LIBS="-ldbus-1"
fi

"$CC" -O2 $DBUS_CFLAGS "$SRC" $DBUS_LIBS -o "$BIN"
chmod +x "$BIN"
