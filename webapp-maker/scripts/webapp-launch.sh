#!/bin/bash

# Launch a URL as a web-app window (no tabs, no URL bar).
# Only chromium-family browsers have an --app mode; when the default browser
# is not one of them (e.g. Firefox), the first installed chromium-family
# browser is used instead. Extra arguments are passed to the browser as-is.

url=${1:?usage: webapp-launch <url> [browser flags...]}
shift

browser=$(xdg-settings get default-web-browser 2>/dev/null)
case $browser in
chromium* | chrome* | google-chrome* | brave* | microsoft-edge* | opera* | vivaldi* | helium*) ;;
*) browser="" ;;
esac

exec_bin=""
if [[ -n $browser ]]; then
  exec_bin=$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' \
    "$HOME/.local/share/applications/$browser" "/usr/share/applications/$browser" 2>/dev/null | head -1)
fi
if [[ -z $exec_bin ]]; then
  for candidate in chromium google-chrome-stable google-chrome brave vivaldi microsoft-edge-stable; do
    if command -v "$candidate" >/dev/null; then
      exec_bin=$candidate
      break
    fi
  done
fi
if [[ -z $exec_bin ]]; then
  command -v notify-send >/dev/null && notify-send "Web app" "No chromium-family browser found for app windows"
  exit 1
fi

exec setsid "$exec_bin" --app="$url" "$@"
