#!/bin/sh
# Prints what changed in the files and Noctalia settings that came from your other devices
# and wait for you, for the panel's Review to show:
#   changes.sh <repo> <data folder>
# It changes nothing: take or keep each change in the panel. Taking a file takes the version
# shown here; when another device changes it again, it waits again. Control characters are
# printed as text.
set -u

repo=$1
data=$2
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

# git's diff of $1, this device's file, and $2, the other devices' version, with the two sides
# named in its header.
show_diff() {
  git --no-pager diff --no-index --no-color -- "$1" "$2" |
    sed '1,5{/^diff --git /d; /^index /d; /^new file mode /d; s|^--- .*|--- this device|; s|^+++ .*|+++ the other devices|}'
}

shown=0
{
  # The data folder's incoming.txt lists the waiting files as "<blob> <path>": the other
  # devices' version as git names it, "-" for a removal, and the path under the home folder.
  while read -r blob path; do
    [ -n "$path" ] || continue
    shown=$((shown + 1))
    mine=$HOME/$path
    [ -f "$mine" ] || mine=/dev/null
    if [ "$blob" = - ]; then
      printf '\n--- ~/%s was removed on another device.\n' "$path"
    elif git -C "$repo" cat-file blob "$blob" >"$work/theirs" 2>/dev/null; then
      printf '\n--- ~/%s\n' "$path"
      show_diff "$mine" "$work/theirs"
    fi
  done <"$data/incoming.txt"

  # The settings as they would be after taking them.
  if [ -f "$data/incoming-settings.toml" ]; then
    shown=$((shown + 1))
    printf '\n--- Noctalia settings ---\n'
    show_diff "$HOME/.local/state/noctalia/settings.toml" "$data/incoming-settings.toml"
  fi

  [ "$shown" -eq 0 ] && echo "Nothing from your other devices waits for you."
} | cat -v
