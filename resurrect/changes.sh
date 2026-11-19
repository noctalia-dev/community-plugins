#!/bin/sh
# Prints what changed in the files and Noctalia settings that came from your other devices
# and wait for you, for the panel's Review to show:
#   changes.sh <repo> <data folder>
# It changes nothing. It shows the review the service wrote to the data folder: review.txt
# lists the waiting files as "<blob> <path>", the other devices' version as git names it, "-"
# for a removal, and the path under the home folder; review-settings.toml holds the settings
# as they would be after taking them. Taking a file or the settings takes the version shown
# here. Each file's diff, then the settings', ends with a line holding only the character
# 0x1e; control characters in a diff are printed as text.
set -u

repo=$1
data=$2
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

# git's diff of $1, this device's file, and $2, the other devices' version, with the two sides
# named in its header and control characters as text.
show_diff() {
  git --no-pager diff --no-index --no-color -- "$1" "$2" |
    sed '1,5{/^diff --git /d; /^index /d; /^new file mode /d; s|^--- .*|--- this device|; s|^+++ .*|+++ the other devices|}' |
    cat -v
}

end() {
  printf '\036\n'
}

while read -r blob path; do
  [ -n "$path" ] || continue
  mine=$HOME/$path
  [ -f "$mine" ] || mine=/dev/null
  if [ "$blob" = - ]; then
    echo "Removed on another device."
  elif git -C "$repo" cat-file blob "$blob" >"$work/theirs" 2>/dev/null; then
    show_diff "$mine" "$work/theirs"
  else
    echo "This version is no longer in the repository."
  fi
  end
done <"$data/review.txt"

if [ -f "$data/review-settings.toml" ]; then
  mine=$HOME/.local/state/noctalia/settings.toml
  [ -f "$mine" ] || mine=/dev/null
  show_diff "$mine" "$data/review-settings.toml"
  end
fi
