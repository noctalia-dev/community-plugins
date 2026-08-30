#!/bin/bash

# Create a desktop launcher for a web app: fetch the site's icon, write a
# .desktop entry whose Exec opens the URL as an app window via the launcher
# script this plugin installed into its data directory.
#
# Usage: webapp-install.sh --launcher <path> [--flags "<browser flags>"] <name> <url> [icon-url-or-file]
#
# Non-interactive by design: the Noctalia panel is the UI. Exit non-zero with
# a one-line message on stderr/stdout when something is wrong.

set -e

ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
DESKTOP_DIR="$HOME/.local/share/applications"

LAUNCHER=""
EXTRA_FLAGS=""
args=()
while (($#)); do
  case "$1" in
    --launcher)
      LAUNCHER=${2:?--launcher needs a value}
      shift 2
      ;;
    --flags)
      EXTRA_FLAGS=${2:?--flags needs a value}
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
set -- "${args[@]}"

APP_NAME="${1:-}"
APP_URL="${2:-}"
ICON_REF="${3:-}"

if [[ -z $LAUNCHER || -z $APP_NAME || -z $APP_URL ]]; then
  echo "usage: webapp-install.sh --launcher <path> [--flags \"...\"] <name> <url> [icon]" >&2
  exit 1
fi

safe_icon_name() {
  printf '%s\n' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^[:alnum:]]\+/-/g; s/^-//; s/-$//'
}

# The name becomes a filename. A slash would turn it into directory levels,
# so the launcher lands somewhere webapp-remove cannot address; a leading
# ../ leaves the applications directory altogether. Most often it is a URL
# typed into the name field.
if [[ $APP_NAME == */* ]]; then
  echo "App name cannot contain '/': $APP_NAME"
  exit 1
fi

# Chromium's --app= treats javascript:, file:, and data: as a document to
# run. Prefix schemeless input with https, then refuse anything not http(s).
if [[ ! $APP_URL =~ ^[a-zA-Z][a-zA-Z0-9+.-]*: ]]; then
  APP_URL="https://$APP_URL"
fi
if [[ $APP_URL =~ [[:space:]] ]]; then
  echo "Error: web app URL must not contain whitespace." >&2
  exit 1
fi
if [[ ! ${APP_URL,,} =~ ^https?:// ]]; then
  echo "Error: web app URL must be http or https." >&2
  exit 1
fi

download_icon() {
  curl -fsSL --max-time 10 -o "$2" "$1" 2>/dev/null &&
    [[ -s $2 && $(file -b --mime-type "$2") == image/* ]]
}

# Prefer the site's own high-res icon (apple-touch-icon is typically 180px+),
# then the well-known path, then a favicon service as a last resort.
fetch_site_icon() {
  local site_url="$1" dest="$2"
  local origin page icon_url
  origin=$(sed -E 's|^(https?://[^/]+).*|\1|' <<<"$site_url")

  page=$(curl -fsSL --max-time 5 "$site_url" 2>/dev/null | head -c 100000 | tr '\n' ' ')
  icon_url=$(grep -oiE "<link[^>]*rel=[\"'][^\"']*apple-touch-icon[^\"']*[\"'][^>]*>" <<<"$page" |
    grep -oiE "href=[\"'][^\"']+" | head -1 | sed -E "s/^href=[\"']//")

  case $icon_url in
  http://* | https://*) ;;
  //*) icon_url="https:$icon_url" ;;
  /*) icon_url="$origin$icon_url" ;;
  ?*) icon_url="$origin/$icon_url" ;;
  esac

  { [[ -n $icon_url ]] && download_icon "$icon_url" "$dest"; } ||
    download_icon "$origin/apple-touch-icon.png" "$dest" ||
    download_icon "https://www.google.com/s2/favicons?domain=${site_url}&sz=256" "$dest"
}

mkdir -p "$ICON_DIR"
ICON_VALUE=$(safe_icon_name "$APP_NAME")
if [[ -z $ICON_REF ]]; then
  if ! fetch_site_icon "$APP_URL" "$ICON_DIR/$ICON_VALUE.png"; then
    echo "Error: could not download an icon for $APP_URL."
    exit 1
  fi
elif [[ $ICON_REF =~ ^https?:// ]]; then
  if ! download_icon "$ICON_REF" "$ICON_DIR/$ICON_VALUE.png"; then
    echo "Error: could not download the icon."
    exit 1
  fi
elif [[ -f $ICON_REF ]]; then
  cp "$ICON_REF" "$ICON_DIR/$ICON_VALUE.png"
else
  # The name of an icon already installed in the system theme.
  ICON_VALUE=$ICON_REF
fi
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true

desktop_string_escape() {
  # Desktop Entry "string" value (freedesktop spec): a raw newline would
  # start a new key line and let a value inject a second Exec=. Escape
  # backslash first, then tab/CR/LF and a leading space.
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//$'\t'/\\t}
  value=${value//$'\r'/\\r}
  value=${value//$'\n'/\\n}
  [[ $value == " "* ]] && value="\\s${value# }"
  printf '%s' "$value"
}

desktop_exec_arg() {
  # One Exec argument, double-quoted per the freedesktop Exec spec: inside
  # quotes " ` $ \ take a backslash and a literal % becomes %%.
  local escaped
  escaped=$(printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/`/\\`/g' -e 's/\$/\\$/g' -e 's/%/%%/g')
  printf '"%s"' "$escaped"
}

EXEC_COMMAND="$(desktop_exec_arg "$LAUNCHER") $(desktop_exec_arg "$APP_URL")"
# Flags split on whitespace; each becomes its own quoted Exec argument.
for flag in $EXTRA_FLAGS; do
  EXEC_COMMAND+=" $(desktop_exec_arg "$flag")"
done

mkdir -p "$DESKTOP_DIR"
DESKTOP_FILE="$DESKTOP_DIR/$APP_NAME.desktop"

name_field=$(desktop_string_escape "$APP_NAME")
exec_field=$(desktop_string_escape "$EXEC_COMMAND")
icon_field=$(desktop_string_escape "$ICON_VALUE")

cat >"$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Name=$name_field
Comment=$name_field
Exec=$exec_field
Terminal=false
Type=Application
Icon=$icon_field
StartupNotify=true
EOF

chmod +x "$DESKTOP_FILE"
command -v update-desktop-database >/dev/null && update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
exit 0
