#!/usr/bin/env bash
# sync_filter.sh off
# sync_filter.sh on <content-regex> [--apps 'A<FS>B'] [--names 'N<FS>M']
# sync_filter.sh remove
#
# Writes or removes `~/.config/noctalia/contact-sounds.toml`, the helper config
# file holding [notification.filter.contact-sounds-*] rules that silence
# Noctalia's system notification sound for messages the plugin itself plays a
# contact sound for (play_sound = false). Values are TOML-escaped here so names,
# app names and regexes containing quotes or backslashes stay valid.
#
#   on     - enable suppression; --apps lists the allowed apps (one rule per
#            app, matching the app name with `match`), --names adds per-name
#            `match` rules for the case where a contact only appears in the
#            app name
#   off    - write a disabled rule so nothing is suppressed
#   remove - delete the file (used on disable/uninstall)
set -eu

MODE="${1:-}"
REGEX=""
APP_LIST=""
NAME_LIST=""

if [ "$MODE" = "on" ]; then
  [ $# -ge 2 ] || { echo "sync_filter.sh on <regex>" >&2; exit 1; }
  REGEX="$2"
  shift || true
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --apps) APP_LIST="${2:-}"; shift 2 ;;
      --names) NAME_LIST="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
fi

DIR="${NOCTALIA_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}/noctalia"
FILE="${DIR}/contact-sounds.toml"

case "$MODE" in
  remove)
    rm -f "$FILE"
    exit 0
    ;;
  off)
    mkdir -p "$DIR"
    printf '[notification.filter.contact-sounds]\nenabled = false\nplay_sound = false\n' > "$FILE"
    exit 0
    ;;
  on)
    :
    ;;
  *)
    echo "usage: sync_filter.sh on <regex> [--apps 'A<FS>B'] [--names 'N<FS>M'] | off | remove" >&2
    exit 1
    ;;
esac

mkdir -p "$DIR"
TMP="$(mktemp "${DIR}/contact-sounds.toml.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

# TOML basic-string escaping: backslashes first, then quotes.
toml_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

disabled() {
  printf '[notification.filter.contact-sounds]\nenabled = false\nplay_sound = false\n'
}

if [ -z "$REGEX" ]; then
  disabled > "$TMP"
  cp "$TMP" "$FILE"
  exit 0
fi

ES_REGEX="$(toml_escape "$REGEX")"

{
  if [ -n "$APP_LIST" ]; then
    i=0
    IFS=$'\x1f' read -r -a __apps <<< "$APP_LIST"
    for app in "${__apps[@]}"; do
      [ -z "$app" ] && continue
      printf '[notification.filter.contact-sounds-app-%d]\nenabled = true\nmatch = "%s"\nmatch_content = "%s"\nplay_sound = false\n\n' \
        "$i" "$(toml_escape "$app")" "$ES_REGEX"
      i=$((i + 1))
    done
  else
    printf '[notification.filter.contact-sounds]\nenabled = true\nmatch_content = "%s"\nplay_sound = false\n\n' "$ES_REGEX"
    if [ -n "$NAME_LIST" ]; then
      j=0
      IFS=$'\x1f' read -r -a __names <<< "$NAME_LIST"
      for n in "${__names[@]}"; do
        [ -z "$n" ] && continue
        printf '[notification.filter.contact-sounds-name-%d]\nenabled = true\nmatch = "%s"\nplay_sound = false\n\n' \
          "$j" "$(toml_escape "$n")"
        j=$((j + 1))
      done
    fi
  fi
} > "$TMP"

cp "$TMP" "$FILE"