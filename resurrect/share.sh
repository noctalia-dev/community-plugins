#!/bin/sh
# Shares files between the devices that save into one repository. snapshot.sh runs it from
# the repository's folder:
#   share.sh <theirs> <path>... [-- <path kept on this device>...]
# <theirs> is a commit or tree with the other devices' latest saves, or empty. Each path is a
# full path under the home folder. A path after -- is not shared, nor anything inside it,
# and neither is a path in $RESURRECT_LEAVE_OUT. pick.sh chooses the files inside folders.
#
# shared/files/ holds every shared file at its place under the home folder. For each file
# there are three versions: this device's, the one in <theirs>, and the one this device last
# agreed on, kept in .git/resurrect-base. A file only this device changed is saved. A file
# only another device changed is put in place here, after a backup. A file both changed is
# left alone on both sides and reported, until $RESURRECT_RESOLVE says "mine <path>" or
# "theirs <path>". When files put in place give Hyprland config errors, they go back and
# stay held in .git/resurrect-held until another device changes them again. When another
# device removed more than half of the shared files at once, none is removed here; this
# device shares them again. A file that cannot be read stops the save, so it never reads as removed.
#
# Prints "applied <path>", "removed <path>", "conflict <path>", "held <path>",
# "kept <number> files another device removed" and "count shared <number>".
set -u
IFS='
'
set -f

theirs=$1
shift
here=$(cd "$(dirname "$0")" && pwd)
shared=
only=${RESURRECT_LEAVE_OUT:+$RESURRECT_LEAVE_OUT
}
after=false
for path in "$@"; do
  if [ "$path" = -- ]; then
    after=true
    continue
  fi
  path=${path%/}
  case $path in
    "$HOME"/*) ;;
    *) continue ;;
  esac
  if $after; then
    only="$only$path
"
  else
    shared="$shared$path
"
  fi
done
# The kept paths, relative to the home folder like the rest.
kept_paths=
for path in $only; do
  path=${path%/}
  case $path in
    "$HOME"/*) kept_paths="$kept_paths${path#"$HOME"/}
" ;;
  esac
done
only=$kept_paths

git_dir=$(git rev-parse --git-dir) || exit 1
base=$git_dir/resurrect-base
held=$git_dir/resurrect-held
resolve=${RESURRECT_RESOLVE:-}
backup=$HOME/.local/state/resurrect/backup-$(date '+%Y%m%d-%H%M%S')
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
mine=$work/mine
mkdir -p "$mine"
touch "$base" "$held" "$work/theirs" "$work/base" "$work/held" "$work/applied"

# True when the path is kept on this device.
kept() {
  for kept_path in $only; do
    case $1 in
      "$kept_path" | "$kept_path"/*) return 0 ;;
    esac
  done
  return 1
}

# The first word of the line whose rest is $2, in file $1.
lookup() {
  awk -v want="$2" '{ word = $1; sub(/^[^ ]+ /, ""); if ($0 == want) { print word; exit } }' "$1"
}

# Word $2 (1 for the blob, 2 for the mode) of path $1 in <theirs>.
their() {
  awk -v want="$1" -v n="$2" '{ word = $n; sub(/^[^ ]+ [^ ]+ /, ""); if ($0 == want) { print word; exit } }' "$work/theirs"
}

# Copies path $1 under the home folder into this device's files, or stops the save.
take() {
  mkdir -p "$mine/$(dirname "$1")" &&
    cp -L --preserve=mode,timestamps "$HOME/$1" "$mine/$1" ||
    { echo "could not read ~/$1"; exit 1; }
}

# This device's shared files, as pick.sh chooses them. Links are followed.
# shellcheck disable=SC2086 # one path per line
picked=$(RESURRECT_LEAVE_OUT=$(printf '%s\n' $only | sed -e '/^$/d' -e "s|^|$HOME/|") sh "$here/pick.sh" $shared) ||
  { printf '%s\n' "$picked"; exit 1; }
for path in $picked; do
  take "$path"
done

# "<blob> <mode> <path>" for each shared file in <theirs>.
if [ -n "$theirs" ]; then
  git -c core.quotePath=false ls-tree -r "$theirs" -- shared/files |
    awk -F '\t' '{ split($1, f, " "); sub(/^shared\/files\//, "", $2); print f[3], f[1], $2 }' >"$work/theirs"
fi

# A file other devices share is this device's too when it is here, even outside the paths
# it lists; otherwise its next save would read it as deleted.
{
  cut -d ' ' -f 3- "$work/theirs"
  cut -d ' ' -f 2- "$base"
} | sort -u | while read -r path; do
  [ -n "$path" ] && [ -f "$HOME/$path" ] && [ ! -e "$mine/$path" ] || continue
  take "$path"
done || exit 1
for path in $only; do
  rm -rf "${mine:?}/$path"
done
find "$mine" -name .git -prune -exec rm -rf {} +

# Puts blob $2 with mode $3 at path $1 under the home folder, in one step.
put() {
  target=$HOME/$1
  if [ -d "$target" ] && [ ! -L "$target" ]; then
    return 1
  fi
  if [ -e "$target" ] || [ -L "$target" ]; then
    mkdir -p "$backup/$(dirname "$1")"
    cp -PR --preserve=mode,timestamps "$target" "$backup/$1"
  fi
  mkdir -p "$(dirname "$target")" || return 1
  tmp=$(dirname "$target")/.$(basename "$target").resurrect-tmp
  git cat-file blob "$2" >"$tmp" || { rm -f "$tmp"; return 1; }
  if [ "$3" = 100755 ]; then chmod 755 "$tmp"; else chmod 644 "$tmp"; fi
  mv -f "$tmp" "$target"
}

# Moves path $1 under the home folder into the backup.
drop() {
  [ -e "$HOME/$1" ] || return 0
  mkdir -p "$backup/$(dirname "$1")"
  mv -f "$HOME/$1" "$backup/$1"
}

# Writes the shared copy of path $1: this device's file, or blob $2 with mode $3.
keep() {
  mkdir -p "shared/files/$(dirname "$1")"
  if [ -z "${2:-}" ]; then
    cp -p "$mine/$1" "shared/files/$1"
  else
    git cat-file blob "$2" >"shared/files/$1"
    if [ "$3" = 100755 ]; then chmod 755 "shared/files/$1"; else chmod 644 "shared/files/$1"; fi
  fi
}

rm -rf shared/files
mkdir -p shared/files
{
  (cd "$mine" && find . -type f) | sed 's|^\./||'
  cut -d ' ' -f 3- "$work/theirs"
  cut -d ' ' -f 2- "$base"
} | sort -u >"$work/paths"

# Files only another device removed. More than half of them at once is a mistake, such as
# a failed save there: then none is removed here.
removing=0
while read -r path; do
  [ -n "$path" ] && ! kept "$path" && [ -f "$mine/$path" ] && [ -z "$(their "$path" 1)" ] || continue
  b=$(lookup "$base" "$path")
  [ -n "$b" ] && [ "$(git hash-object "$mine/$path")" = "$b" ] && removing=$((removing + 1))
done <"$work/paths"
many_removed=false
[ "$removing" -gt 0 ] && [ $((removing * 2)) -gt "$(grep -c . "$base")" ] && many_removed=true

while read -r path; do
  [ -n "$path" ] || continue
  t=$(their "$path" 1)
  mode=$(their "$path" 2)
  b=$(lookup "$base" "$path")
  m=
  [ -f "$mine/$path" ] && m=$(git hash-object "$mine/$path")
  # Theirs is held when it is the version that broke Hyprland here.
  h=$(lookup "$held" "$path")
  is_held=false
  [ -n "$h" ] && [ "$h" = "$t" ] && is_held=true
  choice=
  [ -n "$resolve" ] && [ -f "$resolve" ] && choice=$(lookup "$resolve" "$path")

  # Kept on this device: the shared copy stays as the other devices left it.
  if kept "$path"; then
    [ -n "$t" ] && keep "$path" "$t" "$mode"
    [ -n "$b" ] && echo "$b $path" >>"$work/base"
    continue
  fi

  if [ "$m" = "$t" ] || [ "$choice" = mine ] || { [ "$t" = "$b" ] && [ "$choice" != theirs ]; } ||
    { [ -z "$t" ] && [ -n "$m" ] && $many_removed && [ "$choice" != theirs ]; }; then
    # Same on both sides, or only this device changed it: this device's version is shared.
    [ -n "$m" ] && keep "$path" && echo "$m $path" >>"$work/base"
  elif { [ "$m" = "$b" ] && ! $is_held; } || [ "$choice" = theirs ]; then
    # Only another device changed it, or the owner took theirs: it is put in place here.
    if [ -z "$t" ]; then
      drop "$path" && echo "removed $path"
    elif put "$path" "$t" "$mode"; then
      keep "$path" "$t" "$mode"
      echo "$t $path" >>"$work/base"
      echo "$path" >>"$work/applied"
      echo "applied $path"
    else
      keep "$path" "$t" "$mode"
      [ -n "$b" ] && echo "$b $path" >>"$work/base"
      echo "conflict $path"
    fi
  else
    # Changed on both sides, or held back: nothing moves until the owner chooses.
    [ -n "$t" ] && keep "$path" "$t" "$mode"
    [ -n "$b" ] && echo "$b $path" >>"$work/base"
    if $is_held; then
      echo "$t $path" >>"$work/held"
      echo "held $path"
    else
      echo "conflict $path"
    fi
  fi
done <"$work/paths"

# Hyprland reloads its config when a file changes. If what came in gives config errors,
# every file put in place goes back, and stays held until another device changes it.
if grep -q '^\.config/hypr/' "$work/applied" && command -v hyprctl >/dev/null &&
  hyprctl reload >/dev/null 2>&1; then
  sleep 1
  errors=$(hyprctl configerrors 2>&1 | grep -v -i -x '[[:space:]]*\(no errors\)\{0,1\}[[:space:]]*')
  if [ -n "$errors" ]; then
    while read -r path; do
      if [ -e "$backup/$path" ]; then
        tmp=$(dirname "$HOME/$path")/.$(basename "$path").resurrect-tmp
        cp -PR --preserve=mode,timestamps "$backup/$path" "$tmp" && mv -f "$tmp" "$HOME/$path"
      else
        rm -f "$HOME/$path"
      fi
      t=$(their "$path" 1)
      # The agreed version goes back to what it was, so the file stays a difference.
      grep -v -F -x "$t $path" "$work/base" >"$work/base.new"
      mv "$work/base.new" "$work/base"
      b=$(lookup "$base" "$path")
      [ -n "$b" ] && echo "$b $path" >>"$work/base"
      echo "$t $path" >>"$work/held"
      echo "held $path"
    done <"$work/applied"
    hyprctl reload >/dev/null 2>&1
  fi
fi

$many_removed && echo "kept $removing files another device removed"
mv "$work/base" "$base"
mv "$work/held" "$held"
[ -n "$resolve" ] && rm -f "$resolve"
echo "count shared $(find shared/files -type f | wc -l)"
