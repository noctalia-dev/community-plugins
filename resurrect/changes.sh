#!/bin/sh
# Prints what changed in the files and Noctalia settings that came from your other devices
# and wait for you, for the panel's Review to show:
#   changes.sh <repo> <data folder>
# It changes nothing. It shows the review the service wrote to the data folder: review.txt
# lists the waiting files as "<blob>:<mode> <path>", the other devices' version as git names
# it, "-" for a removal, and the path under the home folder; review-settings.toml holds the
# settings as they would be after taking them. Taking a file or the settings takes the
# version shown here. Each file's diff, then the settings', ends with a line holding only the
# character 0x1e when it was shown in full, or 0x1f when it was not, and then it cannot be
# taken. Control characters in a diff are printed as text.
set -u

repo=$1
data=$2
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

complete() {
  printf '\036\n'
}

incomplete() {
  printf '\037\n'
}

# git's diff of $1, this device's file, and $2, the other devices' version, with the two sides
# named in its header and control characters as text. Fails when git could not compare them.
show_diff() {
  git --no-pager diff --no-index --no-color -- "$1" "$2" >"$work/diff"
  [ $? -le 1 ] || return 1
  sed '1,5{/^diff --git /d; /^index /d; /^new file mode /d; /^old mode /d; /^new mode /d; s|^--- .*|--- this device|; s|^+++ .*|+++ the other devices|}' "$work/diff" |
    cat -v
}

# "executable" or "not executable".
describe() {
  if [ "$1" = yes ]; then echo executable; else echo "not executable"; fi
}

while read -r version path; do
  [ -n "$path" ] || continue
  mine=$HOME/$path
  [ -f "$mine" ] || mine=/dev/null
  if [ "$version" = - ]; then
    echo "Removed on another device."
    complete
    continue
  fi
  blob=${version%%:*}
  mode=${version#*:}
  if ! git -C "$repo" cat-file blob "$blob" >"$work/theirs" 2>/dev/null; then
    echo "This version is no longer in the repository."
    incomplete
    continue
  fi
  theirs_exec=no
  [ "$mode" = 100755 ] && theirs_exec=yes
  mine_exec=no
  [ "$mine" != /dev/null ] && [ -x "$mine" ] && mine_exec=yes
  if [ "$mine" = /dev/null ]; then
    echo "New here, $(describe "$theirs_exec")."
  elif [ "$mine_exec" != "$theirs_exec" ]; then
    echo "Becomes $(describe "$theirs_exec"); it is $(describe "$mine_exec") on this device."
  fi
  if show_diff "$mine" "$work/theirs"; then
    complete
  else
    echo "The change could not be shown."
    incomplete
  fi
done <"$data/review.txt"

if [ -f "$data/review-settings.toml" ]; then
  mine=$HOME/.local/state/noctalia/settings.toml
  [ -f "$mine" ] || mine=/dev/null
  if show_diff "$mine" "$data/review-settings.toml"; then
    complete
  else
    echo "The change could not be shown."
    incomplete
  fi
fi
