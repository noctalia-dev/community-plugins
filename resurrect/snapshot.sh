#!/bin/sh
# Saves this device's setup into a git repository, for restore.sh to bring back.
#   snapshot.sh <repo> <remote> <packages> <services> <noctalia> <share> [path...] [-- path...]
# <remote> may be empty. <packages>, <services>, <noctalia> and <share> are "true" or "false".
# Each path is a full path to a file or folder under the home folder. Paths after -- are
# kept on this device only.
#
# What the plugin saves of this device goes into devices/<hostname>/, so devices sharing one
# repository never overwrite each other. With <share>, what the devices share goes into
# shared/ instead: the dotfiles, Noctalia's config and settings, and the package and service
# lists. share.sh, settings.sh and lists.sh bring in what other devices changed, and this
# device's folder keeps only what differs. Then every executable file in hooks/save/ runs,
# in name order, and in devices/<hostname>/hooks/save/, for the owner's own steps.
# Prints "count <what> <number>" lines, share.sh's lines, then "saved" or "unchanged", and
# "pushed".
set -u

repo=$1
remote=$2
packages=$3
services=$4
noctalia=$5
share=$6
shift 6
here=$(cd "$(dirname "$0")" && pwd)
device=$(uname -n)

# A new device starts from the remote's saves, so all devices share one history.
if [ ! -d "$repo/.git" ] && [ -n "$remote" ] && [ -z "$(ls -A "$repo" 2>/dev/null)" ] &&
  [ -n "$(git ls-remote "$remote" 2>/dev/null)" ]; then
  git clone -q "$remote" "$repo" || exit 2
fi
mkdir -p "$repo" || exit 1
cd "$repo" || exit 1
[ -d .git ] || git init -q || exit 1

# The other devices' latest saves, for share.sh: the remote's branch merged with this
# repository's own, the remote's side winning where both changed a file.
theirs=
if [ -n "$remote" ]; then
  if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$remote"
  else
    git remote add origin "$remote"
  fi
  branch=$(git symbolic-ref --short HEAD)
  git fetch -q origin "$branch" 2>/dev/null
fi
# The remote's save share.sh starts from; see the push below.
fetched=$(git rev-parse -q --verify "origin/${branch:-}" 2>/dev/null)
if git rev-parse -q --verify HEAD >/dev/null; then
  theirs=HEAD
  if [ -n "$remote" ] && git rev-parse -q --verify "origin/$branch" >/dev/null; then
    theirs=$(git merge-tree --write-tree -X theirs HEAD "origin/$branch" 2>/dev/null | head -n 1)
    git cat-file -e "$theirs" 2>/dev/null || theirs=origin/$branch
  fi
elif [ -n "$remote" ] && git rev-parse -q --verify "origin/$branch" >/dev/null; then
  theirs=origin/$branch
fi

dir=devices/$device
mkdir -p "$dir"
git_dir=$(git rev-parse --git-dir)
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

# Prints "count <what> <lines in the files>".
count() {
  what=$1
  shift
  echo "count $what $(cat "$@" 2>/dev/null | grep -c .)"
}

# Lines of a list you keep by hand, without comments and blank lines.
entries() {
  sed 's/#.*//; s/[[:space:]]*$//; /^$/d' "$1" 2>/dev/null
}

# Where list $1 goes: packages, or services for system and user.
kind() {
  case $1 in
    system | user) echo services ;;
    *) echo packages ;;
  esac
}

# Puts the other devices' version of folder $1 in place, so this save starts from it.
from_theirs() {
  rm -rf "$1"
  [ -n "$theirs" ] || return 0
  git -c core.quotePath=false ls-tree -r --name-only "$theirs" -- "$1" | while IFS= read -r file; do
    mkdir -p "$(dirname "$file")" && git show "$theirs:$file" >"$file"
  done
}

# Adds the lines of file $2, when it is set, to list $1, then removes $2.
add_lines() {
  [ -n "$2" ] || return 0
  if [ -s "$2" ]; then
    cat "$2" >>"$1"
    sort -u -o "$1" "$1"
  fi
  rm -f "$2"
}

# This device's lists, in $work/lists: <list>.txt holds what was installed or turned on on
# purpose, <list>.all every package installed, so a dependency never reads as removed.
# Packages come by package manager, without the names that packages/exclude.txt matches: one
# regular expression per line, for the whole name. Services come for the system and the user.
mkdir -p "$work/lists"
if [ "$packages" = true ]; then
  entries packages/exclude.txt >"$work/exclude"
  [ -s "$work/exclude" ] || echo '^$' >"$work/exclude"
  if command -v pacman >/dev/null; then
    pacman -Qqen | grep -vxEf "$work/exclude" >"$work/lists/pacman.txt"
    pacman -Qqem | grep -vxEf "$work/exclude" >"$work/lists/aur.txt"
    pacman -Qq >"$work/lists/pacman.all"
    cp "$work/lists/pacman.all" "$work/lists/aur.all"
  fi
  if command -v apt-mark >/dev/null; then
    apt-mark showmanual | grep -vxEf "$work/exclude" >"$work/lists/apt.txt"
    dpkg-query -W -f '${Package}\n' >"$work/lists/apt.all" 2>/dev/null
  fi
  if command -v dnf >/dev/null; then
    dnf repoquery --userinstalled --qf '%{name}\n' 2>/dev/null | grep -vxEf "$work/exclude" >"$work/lists/dnf.txt"
    rpm -qa --qf '%{NAME}\n' >"$work/lists/dnf.all" 2>/dev/null
  fi
  if command -v flatpak >/dev/null; then
    flatpak list --app --columns=application | grep -vxEf "$work/exclude" >"$work/lists/flatpak.txt"
    flatpak list --columns=application >"$work/lists/flatpak.all"
  fi
  count packages "$work"/lists/pacman.txt "$work"/lists/aur.txt "$work"/lists/apt.txt \
    "$work"/lists/dnf.txt "$work"/lists/flatpak.txt
fi
if [ "$services" = true ] && command -v systemctl >/dev/null; then
  systemctl list-unit-files --state=enabled --no-legend --type=service,timer,socket |
    awk '{print $1}' >"$work/lists/system.txt"
  systemctl --user list-unit-files --state=enabled --no-legend --type=service,timer,socket |
    awk '{print $1}' >"$work/lists/user.txt"
  count services "$work/lists/system.txt" "$work/lists/user.txt"
fi

rm -rf "$dir/packages" "$dir/services" "$dir/noctalia"
if [ "$share" != true ]; then
  # Without sharing, this device's lists are saved in its own folder.
  for file in "$work"/lists/*.txt; do
    [ -f "$file" ] || continue
    mkdir -p "$dir/$(kind "$(basename "$file" .txt)")"
    cp "$file" "$dir/$(kind "$(basename "$file" .txt)")/"
  done
else
  # With sharing on, the devices share one list of each kind. This device's folder keeps
  # only what differs: exclude.txt, shared names it leaves out, and extra.txt, "<list>
  # <name>" lines it keeps only here. The panel's choices come in $RESURRECT_EXCLUDE,
  # $RESURRECT_ONLY and $RESURRECT_AGAIN. Prints "missing <list> <name>" for each shared
  # name this device does not have, and "left <list> <name>" for each one another device
  # removed that this device still has.
  if [ -f "$dir/skip.txt" ]; then
    cat "$dir/skip.txt" >>"$dir/exclude.txt"
    sort -u -o "$dir/exclude.txt" "$dir/exclude.txt"
    rm -f "$dir/skip.txt"
  fi
  add_lines "$dir/exclude.txt" "${RESURRECT_EXCLUDE:-}"
  add_lines "$dir/extra.txt" "${RESURRECT_ONLY:-}"
  entries "$dir/exclude.txt" >"$work/excluded"
  from_theirs shared/packages
  from_theirs shared/services
  for file in "$work"/lists/*.txt; do
    [ -f "$file" ] || continue
    list=$(basename "$file" .txt)
    awk -v list="$list" '$1 == list { print $2 }' "$dir/extra.txt" >"$work/extra" 2>/dev/null
    awk -v list="$list" '$1 == list { print $2 }' "${RESURRECT_AGAIN:-/dev/null}" >"$work/again" 2>/dev/null
    sh "$here/lists.sh" "$list" "$file" "$work/lists/$list.all" "shared/$(kind "$list")/$list.txt" \
      "$git_dir/resurrect-lists/$list.txt" "$work/excluded" "$work/extra" "$work/again" || exit 1
    [ -s "shared/$(kind "$list")/$list.txt" ] || rm -f "shared/$(kind "$list")/$list.txt"
    # A name kept only here leaves extra.txt once it is not installed or turned on here.
    if [ -f "$dir/extra.txt" ]; then
      awk -v list="$list" -v all="$work/lists/$list.all" -v here="$file" '
        BEGIN {
          while ((getline name <all) > 0) have[name] = 1
          while ((getline name <here) > 0) have[name] = 1
        }
        $1 != list || $2 in have' "$dir/extra.txt" >"$work/extra.txt" &&
        mv -f "$work/extra.txt" "$dir/extra.txt"
    fi
  done
  [ -n "${RESURRECT_AGAIN:-}" ] && rm -f "$RESURRECT_AGAIN"
  for file in "$dir/exclude.txt" "$dir/extra.txt"; do
    [ -s "$file" ] || rm -f "$file"
  done
fi

# Noctalia's config, the settings changed in its settings window, and the plugins that are
# on. Links are followed, as for the dotfiles. With sharing on, the config folder is shared
# like the dotfiles, the settings one at a time, and this device's folder keeps only the
# settings tied to its hardware, in settings.toml.
rm -f "$dir/settings.toml"
if [ "$noctalia" = true ]; then
  if [ "$share" != true ]; then
    mkdir -p "$dir/noctalia/config" "$dir/noctalia/state"
    [ -d "$HOME/.config/noctalia" ] && cp -RL --preserve=mode,timestamps "$HOME/.config/noctalia/." "$dir/noctalia/config/"
    [ -f "$HOME/.local/state/noctalia/settings.toml" ] &&
      cp -L --preserve=mode,timestamps "$HOME/.local/state/noctalia/settings.toml" "$dir/noctalia/state/"
  fi
  if command -v noctalia >/dev/null; then
    noctalia msg plugins list 2>/dev/null | awk '$4 == "enabled" {print $1}' >"$work/plugins.txt"
    count plugins "$work/plugins.txt"
    [ "$share" != true ] && cp "$work/plugins.txt" "$dir/noctalia/plugins.txt"
  fi
fi

# Dotfiles, kept at their place under the home folder, as pick.sh chooses them. Links are
# followed, so files kept elsewhere, as with GNU Stow, are saved themselves. With sharing on,
# only the ones kept on this device are saved here.
rm -rf "$dir/files"
after=false
own=
for path in "$@"; do
  if [ "$path" = -- ]; then
    after=true
    continue
  fi
  [ "$share" = true ] && ! $after && continue
  case $path in
    "$HOME"/*) ;;
    *) echo "skipped, not in the home folder: $path"; continue ;;
  esac
  [ -e "$path" ] || { echo "skipped, missing: $path"; continue; }
  own="$own$path
"
done
files=0
if [ -n "$own" ]; then
  # shellcheck disable=SC2086 # one path per line
  picked=$(IFS='
' && set -f && sh "$here/pick.sh" $own) || { printf '%s\n' "$picked"; exit 1; }
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    mkdir -p "$dir/files/$(dirname "$relative")" &&
      cp -L --preserve=mode,timestamps "$HOME/$relative" "$dir/files/$relative" ||
      { echo "could not read ~/$relative"; exit 1; }
    files=$((files + 1))
  done <<EOF
$picked
EOF
fi
echo "count files $files"

if [ "$share" = true ]; then
  # Noctalia's config folder is shared like the dotfiles; its settings.toml one setting at
  # a time. The settings come first, so a file list another device changed is in place for
  # the plugin's next save.
  if [ "$noctalia" = true ]; then
    if [ -f "$HOME/.local/state/noctalia/settings.toml" ]; then
      their_settings=$(mktemp)
      [ -n "$theirs" ] && git show "$theirs:shared/noctalia/settings.toml" >"$their_settings" 2>/dev/null
      # The agreed settings change in a copy, which takes their place once the save is
      # committed. A setting of a save that was not committed would otherwise read, on the
      # next save, as removed by another device, and be removed here too.
      [ -f "$git_dir/resurrect-settings" ] && cp "$git_dir/resurrect-settings" "$work/base"
      result=$(sh "$here/settings.sh" "$HOME/.local/state/noctalia/settings.toml" \
        "$their_settings" "$work/base" "$dir/settings.toml") || {
        rm -f "$their_settings"
        echo "could not share Noctalia's settings"
        exit 1
      }
      rm -f "$their_settings"
      echo "$result"
      case $result in
        "settings applied 0"*) ;;
        *) command -v noctalia >/dev/null && noctalia msg config-reload >/dev/null 2>&1 ;;
      esac
    fi
    sh "$here/share.sh" "$theirs" "$HOME/.config/noctalia" "$@" || exit 1
  else
    sh "$here/share.sh" "$theirs" "$@" || exit 1
  fi
fi

cp "$here/restore.sh" restore.sh
chmod +x restore.sh
# restore.sh reads the shared settings with it.
cp "$here/settings.awk" settings.awk

# The owner's own steps: hooks/save/ on every device, then this device's own, in
# devices/<name>/hooks/save/. Each gets the repository, this device's name and the folder
# its files go in: with sharing on, shared/steps/ for the shared steps, else this device's.
hooks=0
run_hooks() {
  [ -d "$1" ] || return 0
  for hook in "$1"/*; do
    [ -f "$hook" ] && [ -x "$hook" ] || continue
    hooks=$((hooks + 1))
    mkdir -p "$2"
    RESURRECT_REPO=$(pwd) RESURRECT_DEVICE=$device RESURRECT_DIR=$2 "$hook" ||
      { echo "hook failed: $hook"; exit 3; }
  done
}
if [ "$share" = true ]; then
  from_theirs shared/steps
  run_hooks hooks/save "$(pwd)/shared/steps"
else
  run_hooks hooks/save "$(pwd)/$dir"
fi
run_hooks "$dir/hooks/save" "$(pwd)/$dir"
echo "count hooks $hooks"

git add -A

# Nothing that looks like a password or key is committed, since saves may be pushed, except
# in Noctalia's config and settings, which are saved whole (gitleaks.toml). Known findings
# can be allowed in .gitleaksignore. The secret_check setting turns this off.
if [ "${RESURRECT_SECRET_CHECK:-true}" != false ] && command -v gitleaks >/dev/null &&
  ! found=$(gitleaks git --pre-commit --staged --redact --no-banner -v \
    --config "$here/gitleaks.toml" . 2>&1); then
  git reset -q
  echo "$found" | sed 's/\x1b\[[0-9;]*m//g' | sed -n 's/^File:[[:space:]]*/secret found in: /p' | sort -u
  exit 4
fi

if git diff --cached --quiet; then
  echo "unchanged"
else
  git -c user.name="${USER:-resurrect}" -c user.email="${USER:-resurrect}@$device" \
    commit -q -m "Snapshot of $device on $(date '+%Y-%m-%d %H:%M')" || exit 1
  echo "saved"
fi
[ -f "$work/base" ] && mv -f "$work/base" "$git_dir/resurrect-settings"

if [ -n "$remote" ]; then
  # Other devices push to the same repository. Their saves are in their own folders, and
  # share.sh already took in their shared files, so this save goes on top of theirs; a file
  # both changed keeps this device's version.
  branch=$(git symbolic-ref --short HEAD)
  saved=$(git rev-parse HEAD)
  if git fetch -q origin "$branch" 2>/dev/null; then
    if ! git -c user.name="${USER:-resurrect}" -c user.email="${USER:-resurrect}@$device" \
      rebase -q -X theirs "origin/$branch" >/dev/null 2>&1; then
      git rebase --abort 2>/dev/null
      echo "could not combine this save with the other devices' saves; see git status in $repo"
      exit 2
    fi
    # share.sh already merged the other devices' shared files into shared/, so it stays as
    # this save made it, also where it equals this device's last save. When another device
    # pushed meanwhile, its save is newer: the next save merges it.
    if [ "$share" = true ] && [ "$(git rev-parse -q --verify "origin/$branch")" = "$fetched" ]; then
      git restore -q --source="$saved" --staged --worktree -- shared 2>/dev/null
      if ! git diff --cached --quiet; then
        git -c user.name="${USER:-resurrect}" -c user.email="${USER:-resurrect}@$device" \
          commit -q -m "Snapshot of $device on $(date '+%Y-%m-%d %H:%M')" || exit 1
      fi
    fi
  fi
  git push -q -u origin HEAD || exit 2
  echo "pushed"
fi
