#!/bin/sh
# Lists the files a save takes from the given paths, relative to the home folder, one per line:
#   pick.sh <path>...
# Each path is a full path under the home folder. A file named itself is always taken. Inside
# a folder, these are left out: nested git folders; caches, logs and crash reports; the data
# of browsers and Electron apps, which is a folder with a "Local State" or "profiles.ini"
# file; binary files; and files over 1 MB. Every path in $RESURRECT_LEAVE_OUT, one per line,
# is left out with all it holds. Links are followed.
#
# A file or folder it cannot read stops it with "could not read" lines and exit 1. When the
# files add up to more than 50 MB, nothing is listed: it prints "too big" lines for the
# largest folders, the largest last, and exits 5.
set -u
IFS='
'
set -f

LIMIT_KB=51200
leave=${RESURRECT_LEAVE_OUT:-}
out=$(mktemp) || exit 1
trap 'rm -f "$out" "$out.sizes" "$out.errors"' EXIT

# True when path $1 is left out, or inside a path that is.
left_out() {
  for left in $leave; do
    left=${left%/}
    case $1 in
      "$left" | "$left"/*) return 0 ;;
    esac
  done
  return 1
}

for path in "$@"; do
  path=${path%/}
  case $path in
    "$HOME"/*) ;;
    *) continue ;;
  esac
  left_out "$path" && continue
  if [ -d "$path" ]; then
    find -L "$path" \( -type d \( -name .git -o -iname cache -o -iname caches \
      -o -iname cacheddata -o -iname gpucache -o -iname 'code cache' -o -iname logs \
      -o -iname crashpad -o -iname 'crash reports' \
      -o -exec test -e '{}/Local State' -o -e '{}/profiles.ini' \; \) -prune \) \
      -o -type f -size -1025k -print 2>>"$out.errors" |
      while read -r file; do
        left_out "$file" && continue
        [ -r "$file" ] || { printf '%s\n' "$file" >>"$out.errors"; continue; }
        # An empty file is text too; grep finds no line in it.
        if [ -s "$file" ]; then printf '%s\n' "$file"; else printf '%s\n' "$file" >>"$out"; fi
      done |
      tr '\n' '\0' | xargs -0r grep -IlZ '' 2>/dev/null | tr '\0' '\n' >>"$out"
  elif [ -f "$path" ]; then
    printf '%s\n' "$path" >>"$out"
  fi
done

# A file or folder that cannot be read stops the save, so it never reads as removed.
if [ -s "$out.errors" ]; then
  head -n 3 "$out.errors" | sed 's/^/could not read: /'
  exit 1
fi
sort -u -o "$out" "$out"
tr '\n' '\0' <"$out" | du -kL --files0-from=- 2>/dev/null >"$out.sizes"
total=$(awk '{ sum += $1 } END { print sum + 0 }' "$out.sizes")
if [ "$total" -gt "$LIMIT_KB" ]; then
  # Sizes by the folder two levels under the home folder, such as .config/app.
  awk -v home="$HOME/" -F '\t' '{
      path = substr($2, length(home) + 1)
      n = split(path, part, "/")
      folder = n > 2 ? part[1] "/" part[2] : path
      size[folder] += $1
    } END { for (f in size) printf "%d\t%s\n", size[f], f }' "$out.sizes" |
    sort -n | tail -n 5 |
    awk -F '\t' '{ printf "too big: ~/%s is %d MB, leave it out\n", $2, ($1 + 1023) / 1024 }'
  exit 5
fi
awk -v home="$HOME/" 'index($0, home) == 1 { print substr($0, length(home) + 1) }' "$out"
