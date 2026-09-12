#!/usr/bin/env bash
# sync_filter.sh <regex>
# Configures [notification.filter.contact-sounds] so Noctalia's system
# notification sound is suppressed for notifications whose content matches one
# of the contact names (the plugin plays the contact's sound instead).
# With an empty <regex>, the filter is disabled so nothing is suppressed.
set -eu

REGEX="${1:-}"
DIR="${NOCTALIA_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}/noctalia"
mkdir -p "$DIR"

TMP="$(mktemp "${DIR}/contact-sounds.toml.XXXXXX")"
if [ -n "$REGEX" ]; then
  printf '[notification.filter.contact-sounds]\nenabled = true\nmatch_content = "%s"\nplay_sound = false\n' "$REGEX" > "$TMP"
else
  printf '[notification.filter.contact-sounds]\nenabled = false\nmatch_content = "____contact_sounds_disabled____"\nplay_sound = false\n' > "$TMP"
fi
cat "$TMP" > "${DIR}/contact-sounds.toml"
rm -f "$TMP"