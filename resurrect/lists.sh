#!/bin/sh
# Shares one list of packages or services between devices. snapshot.sh runs it:
#   lists.sh <list> <here> <installed> <shared> <base> <excluded> <extra> <again>
# <list> is a package manager, or system or user for services. Each other argument is a file
# with one name per line; a missing file counts as empty:
# - <here>: what this device installed or turned on on purpose;
# - <installed>: every package installed here, so a dependency never reads as removed;
# - <shared>: the shared list as the other devices left it, replaced with the new one;
# - <base>: the shared list this device last agreed on, replaced for the next save. Next to
#   it, <base> with .had in place of .txt holds the shared names this device had then;
# - <excluded>: names this device leaves out, from its exclude.txt;
# - <extra>: names only this device keeps, from its extra.txt;
# - <again>: names the owner shares again.
#
# A name only this device added joins the list. A shared name this device had and removed
# leaves it. A name another device removed, which this device still has, does not come back
# by itself: it stays out until the owner shares it again or keeps it only here, and the
# base keeps it, so it still reads as removed elsewhere on the next save.
#
# Prints "missing <list> <name>" for each shared name this device does not have, and
# "left <list> <name>" for each name another device removed that this device still has.
set -u

list=$1
shared=$4
base=$5
had=${base%.txt}.had

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

LC_ALL=C awk -v here="$2" -v installed="$3" -v theirs="$shared" -v base="$base" \
  -v had="$had" -v excluded="$6" -v extra="$7" -v again="$8" '
  function load(file, names,   line) {
    while ((getline line <file) > 0) if (line != "") names[line] = 1
    close(file)
  }
  BEGIN {
    load(here, HERE)
    load(installed, INSTALLED)
    load(theirs, THEIRS)
    load(base, BASE)
    load(had, HAD)
    load(excluded, EXCLUDED)
    load(extra, EXTRA)
    load(again, AGAIN)
    for (name in HERE) INSTALLED[name] = 1
    for (name in THEIRS) {
      # Removed here: this device had it, and it is not installed or turned on any more.
      if (!(name in HAD) || name in INSTALLED || name in EXCLUDED) print "shared " name
    }
    for (name in HERE) {
      if (name in THEIRS || name in EXTRA) continue
      if (name in BASE && !(name in AGAIN)) print "left " name
      else print "shared " name
    }
  }' >"$work/result" || exit 1

sed -n 's/^shared //p' "$work/result" | LC_ALL=C sort -u >"$work/shared"
sed -n -e 's/^shared //p' -e 's/^left //p' "$work/result" | LC_ALL=C sort -u >"$work/base"
mkdir -p "$(dirname "$shared")" "$(dirname "$base")" || exit 1
cp "$work/shared" "$shared.resurrect-tmp" && mv -f "$shared.resurrect-tmp" "$shared" || exit 1
cp "$work/base" "$base.resurrect-tmp" && mv -f "$base.resurrect-tmp" "$base" || exit 1
cat "$3" "$2" 2>/dev/null | LC_ALL=C sort -u >"$work/installed"
LC_ALL=C grep -xFf "$work/installed" "$work/shared" >"$had.resurrect-tmp"
mv -f "$had.resurrect-tmp" "$had" || exit 1

# What waits for the owner. Names this device has, or leaves out, are not missing.
cat "$3" "$2" "$6" 2>/dev/null | LC_ALL=C sort -u >"$work/have"
LC_ALL=C grep -vxFf "$work/have" "$work/shared" | sed "s/^/missing $list /"
sed -n "s/^left /left $list /p" "$work/result" | LC_ALL=C sort
exit 0
