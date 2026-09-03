#!/bin/bash

# Remove a web-app launcher created by webapp-install.sh: its .desktop entry
# and the icon it installed. Only launchers whose Exec runs webapp-launch are
# touched, so a name clash with a regular application cannot delete it.

set -e

name=${1:?usage: webapp-remove <name>}

ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
DESKTOP_DIR="$HOME/.local/share/applications"

desktop_file="$DESKTOP_DIR/$name.desktop"
if [[ ! -f $desktop_file ]] || ! grep -q '^Exec=.*webapp-launch' "$desktop_file"; then
  echo "Not a web app: $name" >&2
  exit 1
fi

icon_name=$(printf '%s\n' "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^[:alnum:]]\+/-/g; s/^-//; s/-$//')
rm -f "$desktop_file" "$ICON_DIR/$icon_name.png" "$ICON_DIR/$name.png"

command -v update-desktop-database >/dev/null && update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
exit 0
