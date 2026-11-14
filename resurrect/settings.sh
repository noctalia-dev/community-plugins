#!/bin/sh
# Shares Noctalia's settings.toml between devices, one setting at a time. snapshot.sh runs it
# from the repository's folder:
#   settings.sh <settings.toml> <theirs> <base> [<local>]
# <theirs> is the other devices' shared settings, <base> the shared settings this device last
# agreed on; either may be a missing file. It writes:
# - shared/noctalia/settings.toml, the shared settings;
# - <base>, the same, for the next save;
# - <local>, when given, the settings that stay on this device, or no file when there are none;
# - <settings.toml>, when other devices changed something, in one step.
#
# Each setting is compared in three versions: this device's, theirs and the base. One that
# only another device changed is taken; otherwise this device's value stays. The list of
# enabled plugins is merged item by item. Settings tied to the hardware are never shared:
# brightness and battery, any table named after a monitor or placed on one (except the
# wallpaper's), and Resurrect's share and device_files. Plugin sources that are folders on
# this device stay too. A setting shared for the first time, with no agreed version yet,
# takes the value already shared, so the device that shared it first wins. settings.awk
# does the comparing.
#
# Prints "settings applied <count>" and "count settings <number>".
set -u
here=$(cd "$(dirname "$0")" && pwd)
settings=$1
theirs=$2
base=$3
local=${4:-}

for file in "$theirs" "$base"; do
  [ ! -e "$file" ] || [ -r "$file" ] || exit 1
done
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
cp -- "$settings" "$work/before" || exit 1

counts=$(LC_ALL=C awk -f "$here/settings.awk" -v mine="$work/before" -v theirs="$theirs" \
  -v base="$base" -v out="$work") || exit 1

# Copies file $1 next to file $2, then moves it over $2 in one step.
replace() {
  mkdir -p "$(dirname "$2")" || return 1
  tmp=$(dirname "$2")/.$(basename "$2").resurrect-tmp
  cp -- "$1" "$tmp" && mv -f -- "$tmp" "$2"
}

replace "$work/shared" shared/noctalia/settings.toml || exit 1
replace "$work/shared" "$base" || exit 1
if [ -n "$local" ]; then
  if [ -s "$work/local" ]; then
    replace "$work/local" "$local" || exit 1
  else
    rm -f "$local"
  fi
fi

applied=0
# Noctalia may have written the file meanwhile; then this waits for the next save.
if [ -f "$work/settings" ] && cmp -s "$work/before" "$settings"; then
  replace "$work/settings" "$settings" || exit 1
  applied=$(echo "$counts" | sed -n 's/^taken //p')
fi
echo "settings applied $applied"
echo "count settings $(echo "$counts" | sed -n 's/^count //p')"
