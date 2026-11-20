#!/bin/sh
# Brings back a setup saved by Resurrect, on this device, from a clone of its repository:
#   restore.sh <repo>
# It is the plugin's own copy, which the panel's Restore... runs; the repository holds none.
# With sharing on, it brings back what the devices share, and this device's own folder when
# there is one. Without, it uses this device's save, or asks which device's save to use. It
# asks before each step. Files it would replace are first copied to a backup folder. Last, it
# offers each of the owner's restore steps.
set -u

if [ $# -ne 1 ]; then
  echo "usage: restore.sh <repository>" >&2
  exit 2
fi
cd "$1" || exit 1
repo=$(pwd)
# A save never writes a link, so a link where a restore reads did not come from Resurrect,
# and the restore could read or write through it. git makes none when cloning with
# core.symlinks=false.
links=$(
  find . -mindepth 1 -maxdepth 1 \( -name shared -o -name devices -o -name hooks -o -name packages \) -type l
  for folder in shared devices hooks packages; do
    [ -d "$folder" ] && [ ! -L "$folder" ] && find "$folder" -type l
  done
)
if [ -n "$links" ]; then
  echo "The repository holds links, which Resurrect never saves, so nothing was restored:"
  echo "$links" | sed 's/^/  /'
  echo "Clone it with: git clone -c core.symlinks=false <your repository>"
  exit 1
fi
backup=$HOME/.local/state/resurrect/backup-$(date '+%Y%m%d-%H%M%S')
work=$(mktemp -d) || exit 1
# Resurrect's data folder, with this device's approved steps. Nothing restored goes into it.
data=$HOME/.local/state/noctalia/plugins/data/omerfuyar/resurrect
mkdir -p "$data" && data=$(cd -P "$data" && pwd -P) || exit 1
trap 'rm -rf "$work"' EXIT

ask() {
  printf '\n%s [y/N] ' "$1"
  read -r answer
  [ "$answer" = y ] || [ "$answer" = Y ]
}

# Shows list file $2 under the title $1, when it has names.
show() {
  [ -s "$2" ] || return 0
  printf '\n%s:\n' "$1"
  fmt -w 90 "$2" | sed 's/^/  /'
}

# Only the lines that are a package or service name: letters, digits and @ . _ + : -, not
# starting with "-", so a name from the repository is never read as an option, and not
# ending with "-", which tells apt to remove the package.
names_only() {
  grep -E '^[[:alnum:]@_+]([[:alnum:]@._+:-]*[[:alnum:]@._+:])?$'
}

# Lines of a list you keep by hand, without comments and blank lines.
entries() {
  sed 's/#.*//; s/[[:space:]]*$//; /^$/d' "$1" 2>/dev/null
}

# Copies file $1 to path $2 under the home folder. A file already there is first copied to
# the same place under $backup, once, so the backup keeps the file as it was before the
# restore; when that fails, it is left as it is and the failure noted.
# The folder is resolved through its links first, and a path that leads into Resurrect's data
# folder is left out. A link at $2 itself is replaced, not written through.
put_file() {
  folder=$(mkdir -p "$(dirname "$2")" && cd -P "$(dirname "$2")" && pwd -P) || {
    echo "$2" >>"$work/failed"
    return 1
  }
  case $folder/ in "$data"/*)
    echo "Left out $2: it leads into Resurrect's data folder."
    return 1
    ;;
  esac
  if { [ -e "$2" ] || [ -L "$2" ]; } && [ ! -e "$backup${2#"$HOME"}" ] && [ ! -L "$backup${2#"$HOME"}" ]; then
    if ! { mkdir -p "$(dirname "$backup${2#"$HOME"}")" && cp -a "$2" "$backup${2#"$HOME"}"; }; then
      echo "Could not back up $2, so it was left as it is."
      echo "$2" >>"$work/failed"
      return 1
    fi
  fi
  rm -f "$2" && cp -p "$1" "$2" || { echo "$2" >>"$work/failed"; return 1; }
}

# Copies the regular files of folder $1 over folder $2, which is under the home folder,
# except those folder $3, when given, also holds: they win, and are put back from there.
put_back() {
  (cd "$1" && find . -type f) | while read -r file; do
    file=${file#./}
    [ -n "${3:-}" ] && [ -f "$3/$file" ] && continue
    put_file "$1/$file" "$2/$file"
  done
}

# With sharing on, this device's own folder, when there is one. Without, this device's own
# save, the only one, or the one the user picks.
device=$(uname -n)
if [ -d shared ]; then
  if [ -d "devices/$device" ]; then
    echo "Restoring what your devices share, with what $device keeps for itself."
  else
    echo "Restoring what your devices share."
  fi
else
  if [ ! -d "devices/$device" ]; then
    set --
    for folder in devices/*/; do
      [ -d "$folder" ] && set -- "$@" "$(basename "$folder")"
    done
    if [ $# -eq 1 ]; then
      device=$1
    elif [ $# -gt 1 ]; then
      echo "Saves of these devices are here: $*"
      printf 'Which one should this device get? '
      read -r device
    fi
  fi
  [ -d "devices/$device" ] && echo "Restoring the save of $device."
fi
own=$repo/devices/$device

# The names this device gets from list $2 of kind $1, packages or services, one per line:
# the shared list without what this device leaves out, and what it keeps only for itself.
wanted() {
  if [ -d "$repo/shared" ]; then
    entries "$own/exclude.txt" >"$work/excluded"
    {
      [ -f "$repo/shared/$1/$2.txt" ] && grep -vxFf "$work/excluded" "$repo/shared/$1/$2.txt"
      [ -f "$own/extra.txt" ] && sed -n "s/^$2 //p" "$own/extra.txt"
    } | sort -u
  elif [ -f "$own/$1/$2.txt" ]; then
    cat "$own/$1/$2.txt"
  fi
}

for list in pacman aur apt dnf flatpak; do
  wanted packages "$list" | names_only >"$work/$list"
done
# Packages kept by hand in the repository's packages/extra.txt, such as ones pacman counts as
# dependencies and so leaves out of the saved lists.
entries "$repo/packages/extra.txt" | names_only >>"$work/pacman"
sort -u -o "$work/pacman" "$work/pacman"
show "pacman" "$work/pacman"
show "AUR" "$work/aur"
show "apt" "$work/apt"
show "dnf" "$work/dnf"
show "Flatpak" "$work/flatpak"
if [ -n "$(cat "$work"/pacman "$work"/aur "$work"/apt "$work"/dnf "$work"/flatpak)" ] &&
  ask "Install the packages listed above?"; then
  if [ -s "$work/pacman" ] && command -v pacman >/dev/null; then
    # shellcheck disable=SC2024 # the list is read by this user, not by root
    sudo pacman -S --needed - <"$work/pacman"
  fi
  if [ -s "$work/aur" ]; then
    helper=$(command -v paru || command -v yay || true)
    if [ -n "$helper" ]; then
      "$helper" -S --needed - <"$work/aur"
    else
      echo "AUR packages need paru or yay: $(tr '\n' ' ' <"$work/aur")"
    fi
  fi
  if [ -s "$work/apt" ] && command -v apt-get >/dev/null; then
    xargs -a "$work/apt" sudo apt-get install -y --no-remove --
  fi
  if [ -s "$work/dnf" ] && command -v dnf >/dev/null; then
    xargs -a "$work/dnf" sudo dnf install -y --
  fi
  if [ -s "$work/flatpak" ] && command -v flatpak >/dev/null; then
    xargs -a "$work/flatpak" flatpak install -y --
  fi
fi

# Files shared between devices first, then this device's own, which win.
if { [ -d "$repo/shared/files" ] || [ -d "$own/files" ]; } &&
  ask "Put back the saved dotfiles? Replaced files go to $backup"; then
  [ -d "$repo/shared/files" ] && put_back "$repo/shared/files" "$HOME" "$own/files"
  [ -d "$own/files" ] && put_back "$own/files" "$HOME"
fi

# Noctalia's settings: the shared ones and those this device kept for itself, such as its
# monitors, or this device's saved copy. Resurrect puts them in place, with its settings
# reader, when Noctalia runs with it on, and keeps this device's plugin sources, so the
# repository never adds code to run. The config folder comes with the dotfiles when it is
# shared.
# $1 is the shared settings, $2 those this device kept, each when there is one.
leave_settings() {
  [ -f "$2" ] && cp "$2" "$data/.restore-device.tmp" && mv -f "$data/.restore-device.tmp" "$data/restore-device.toml"
  [ -f "$1" ] && cp "$1" "$data/.restore-settings.tmp" && mv -f "$data/.restore-settings.tmp" "$data/restore-settings.toml"
  echo "Resurrect puts them in place once Noctalia runs with it on."
}
if [ -f "$repo/shared/noctalia/settings.toml" ]; then
  if ask "Put back Noctalia's settings?"; then
    leave_settings "$repo/shared/noctalia/settings.toml" "$own/settings.toml"
  fi
  # The plugins that are on, from the line "enabled = [...]" in [plugins], as Resurrect
  # writes it.
  sed -n '/^\[plugins\]$/,/^\[/s/^enabled = \[\(.*\)\]$/\1/p' "$repo/shared/noctalia/settings.toml" |
    tr ',' '\n' | sed 's/^ *"//; s/" *$//; /^$/d' >"$work/plugins"
elif [ -d "$own/noctalia" ]; then
  if ask "Put back Noctalia's config and settings?"; then
    [ -d "$own/noctalia/config" ] && put_back "$own/noctalia/config" "$HOME/.config/noctalia"
    leave_settings "$own/noctalia/state/settings.toml" "$own/noctalia/state/settings.toml"
  fi
  cp "$own/noctalia/plugins.txt" "$work/plugins" 2>/dev/null
fi
# Only plugin ids, <author>/<name>.
grep -E '^[[:alnum:]_.-]+/[[:alnum:]_.-]+$' "$work/plugins" >"$work/ids" 2>/dev/null

show "Noctalia plugins" "$work/ids"
if [ -s "$work/ids" ] && command -v noctalia >/dev/null &&
  ask "Turn on the Noctalia plugins listed above? Noctalia must be running, with their sources added."; then
  # Resurrect first, so it adds this device's own settings.
  grep -x 'omerfuyar/resurrect' "$work/ids" >"$work/first"
  grep -v -x 'omerfuyar/resurrect' "$work/ids" >>"$work/first"
  while read -r plugin; do
    noctalia msg plugins enable "$plugin" </dev/null >/dev/null || echo "skipped: $plugin"
  done <"$work/first"
fi

wanted services system | names_only >"$work/system"
wanted services user | names_only >"$work/user"
show "System services" "$work/system"
show "User services" "$work/user"
if [ -n "$(cat "$work/system" "$work/user")" ] && ask "Turn on the services listed above?"; then
  # One at a time, so a unit this system does not have does not stop the others.
  while read -r unit; do
    sudo systemctl enable -- "$unit" </dev/null 2>/dev/null || echo "skipped: $unit"
  done <"$work/system"
  while read -r unit; do
    systemctl --user enable -- "$unit" </dev/null 2>/dev/null || echo "skipped: $unit"
  done <"$work/user"
fi

# The owner's own steps, in name order, each with the same variables as when saving: the
# shared ones in hooks/restore/, then this device's own in devices/<name>/hooks/restore/.
cd "$repo" || exit 1
run_steps() {
  [ -d "$1" ] || return 0
  for hook in "$1"/*; do
    [ -f "$hook" ] && [ -x "$hook" ] && [ ! -L "$hook" ] || continue
    printf '\n%s\n' "--- $hook ---"
    cat -v "$hook"
    if ask "Run your step $(basename "$hook"), shown above?"; then
      RESURRECT_REPO=$repo RESURRECT_DEVICE=$device RESURRECT_DIR=$2 "$hook" ||
        echo "The step $(basename "$hook") failed."
    fi
  done
}
if [ -d shared ]; then
  run_steps hooks/restore "$repo/shared/steps"
else
  run_steps hooks/restore "$own"
fi
run_steps "$own/hooks/restore" "$own"

[ -d "$backup" ] && echo "Replaced files were saved in $backup."
if [ -s "$work/failed" ]; then
  echo "These files were not put back:"
  sed 's/^/  /' "$work/failed"
  status=1
else
  echo "Done. Log out and back in to load everything."
  status=0
fi
printf 'Press Enter to close. '
read -r _
exit $status
