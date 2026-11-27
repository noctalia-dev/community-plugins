#!/bin/sh
# Shows each save step that waits for this device's approval, in a terminal the panel opens,
# and approves the ones the owner accepts:
#   review.sh <repo> <approved file>
# A step waits when it is new or changed since it was approved, such as one that came from
# the remote. The approved file holds "<checksum> <path>" lines and lives outside the
# repository, so approving a step on one device never approves it on another.
set -u

repo=$1
approved=$2
cd "$repo" || exit 1
device=$(uname -n)
mkdir -p "$(dirname "$approved")" && touch "$approved" || exit 1

found=0
for hook in hooks/save/* "devices/$device/hooks/save/"*; do
  [ -f "$hook" ] && [ -x "$hook" ] && [ ! -L "$hook" ] || continue
  sum=$(sha256sum "$hook" | cut -d ' ' -f 1)
  grep -q -x -F "$sum $hook" "$approved" && continue
  found=$((found + 1))
  printf '\n--- %s ---\n' "$hook"
  cat -v "$hook"
  printf '\nRun this step on every save on this device? [y/N] '
  read -r answer
  if [ "$answer" = y ] || [ "$answer" = Y ]; then
    # Approving a path again replaces its old checksum.
    { while read -r old_sum path; do
        [ "$path" = "$hook" ] || echo "$old_sum $path"
      done <"$approved"
      echo "$sum $hook"; } >"$approved.new" &&
      mv -f "$approved.new" "$approved" && echo "Approved. It runs from the next save."
  else
    echo "Left waiting. It does not run."
  fi
done
[ "$found" -eq 0 ] && echo "No step waits for your approval."
printf '\nPress Enter to close. '
read -r _
