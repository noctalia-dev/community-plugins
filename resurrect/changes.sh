#!/bin/sh
# Shows what changed in the files and Noctalia settings that came from your other devices
# and wait for you, in a terminal the panel opens:
#   changes.sh <repo> <data folder>
# It changes nothing: take or keep each change in the panel.
set -u

repo=$1
data=$2

shown=0
# The data folder's incoming.txt lists the waiting files, by path under the home folder.
while read -r path; do
  [ -n "$path" ] || continue
  shown=$((shown + 1))
  mine=$HOME/$path
  [ -e "$mine" ] || mine=/dev/null
  if [ -f "$repo/shared/files/$path" ]; then
    git --no-pager diff --no-index -- "$mine" "$repo/shared/files/$path"
  else
    printf '\n--- ~/%s was removed on another device.\n' "$path"
  fi
done <"$data/incoming.txt"

# The settings as they would be after taking them.
if [ -f "$data/incoming-settings.toml" ]; then
  shown=$((shown + 1))
  printf '\n--- Noctalia settings ---\n'
  git --no-pager diff --no-index -- "$HOME/.local/state/noctalia/settings.toml" "$data/incoming-settings.toml"
fi

[ "$shown" -eq 0 ] && echo "Nothing from your other devices waits for you."
printf '\nTake or keep each change in the panel. Press Enter to close. '
read -r _
