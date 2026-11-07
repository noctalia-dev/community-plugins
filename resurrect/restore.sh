#!/bin/sh
# Brings back a setup saved by Resurrect, on this device. Run it from the saved
# repository: ./restore.sh
# With sharing on, it brings back what the devices share, and this device's own folder when
# there is one. Without, it uses this device's save, or asks which device's save to use. It
# asks before each step. Files it would replace are first copied to a backup folder. Last, it
# offers each of the owner's restore steps.
set -u

cd "$(dirname "$0")" || exit 1
repo=$(pwd)
backup=$HOME/.local/state/resurrect/backup-$(date '+%Y%m%d-%H%M%S')
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

ask() {
  printf '\n%s [y/N] ' "$1"
  read -r answer
  [ "$answer" = y ] || [ "$answer" = Y ]
}

# Lines of a list you keep by hand, without comments and blank lines.
entries() {
  sed 's/#.*//; s/[[:space:]]*$//; /^$/d' "$1" 2>/dev/null
}

# Copies file $1 to path $2 under the home folder. A file already there is first copied to
# the same place under $backup.
put_file() {
  if [ -e "$2" ]; then
    mkdir -p "$(dirname "$backup${2#"$HOME"}")"
    cp -a "$2" "$backup${2#"$HOME"}"
  fi
  mkdir -p "$(dirname "$2")"
  cp -a "$1" "$2"
}

# Copies the content of folder $1 over folder $2, which is under the home folder.
put_back() {
  (cd "$1" && find . -type f -o -type l) | while read -r file; do
    file=${file#./}
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
      [ -f "$own/extra.txt" ] && awk -v list="$2" '$1 == list { print $2 }' "$own/extra.txt"
    } | sort -u
  elif [ -f "$own/$1/$2.txt" ]; then
    cat "$own/$1/$2.txt"
  fi
}

for list in pacman aur apt dnf flatpak; do
  wanted packages "$list" >"$work/$list"
done
if [ -n "$(cat "$work"/pacman "$work"/aur "$work"/apt "$work"/dnf "$work"/flatpak)" ] &&
  ask "Install the saved packages?"; then
  if [ -s "$work/pacman" ] && command -v pacman >/dev/null; then
    # shellcheck disable=SC2024 # the list is read by this user, not by root
    sudo pacman -S --needed - <"$work/pacman"
  fi
  # Packages kept by hand in the repository's packages/extra.txt, such as ones pacman
  # counts as dependencies and so leaves out of the saved lists.
  if [ -f "$repo/packages/extra.txt" ] && command -v pacman >/dev/null; then
    entries "$repo/packages/extra.txt" | sudo pacman -S --needed -
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
    xargs -a "$work/apt" sudo apt-get install -y
  fi
  if [ -s "$work/dnf" ] && command -v dnf >/dev/null; then
    xargs -a "$work/dnf" sudo dnf install -y
  fi
  if [ -s "$work/flatpak" ] && command -v flatpak >/dev/null; then
    xargs -a "$work/flatpak" flatpak install -y
  fi
fi

# Files shared between devices first, then this device's own, which win.
if { [ -d "$repo/shared/files" ] || [ -d "$own/files" ]; } &&
  ask "Put back the saved dotfiles? Replaced files go to $backup"; then
  [ -d "$repo/shared/files" ] && put_back "$repo/shared/files" "$HOME"
  [ -d "$own/files" ] && put_back "$own/files" "$HOME"
fi

# Noctalia's settings: the shared ones with this device's own, or this device's saved copy.
# Its config folder comes with the dotfiles when it is shared.
if [ -f "$repo/shared/noctalia/settings.toml" ]; then
  if ask "Put back Noctalia's settings?"; then
    if LC_ALL=C awk -f "$repo/settings.awk" -v mine="$own/settings.toml" \
      -v theirs="$repo/shared/noctalia/settings.toml" -v base= -v out="$work" >/dev/null &&
      [ -f "$work/settings" ]; then
      put_file "$work/settings" "$HOME/.local/state/noctalia/settings.toml"
    else
      echo "Could not read the saved settings."
    fi
  fi
  # The plugins that are on, from the line settings.awk writes in [plugins].
  awk '/^\[/ { table = $0; next }
    table == "[plugins]" && /^enabled = \[/ {
      sub(/^enabled = \[/, ""); sub(/\]$/, "")
      n = split($0, ids, /, /)
      for (i = 1; i <= n; i++) { gsub(/^"|"$/, "", ids[i]); if (ids[i] != "") print ids[i] }
    }' "$repo/shared/noctalia/settings.toml" >"$work/plugins"
elif [ -d "$own/noctalia" ]; then
  if ask "Put back Noctalia's settings?"; then
    [ -d "$own/noctalia/config" ] && put_back "$own/noctalia/config" "$HOME/.config/noctalia"
    [ -d "$own/noctalia/state" ] && put_back "$own/noctalia/state" "$HOME/.local/state/noctalia"
  fi
  cp "$own/noctalia/plugins.txt" "$work/plugins" 2>/dev/null
fi

if [ -s "$work/plugins" ] && command -v noctalia >/dev/null &&
  ask "Turn on the saved Noctalia plugins? Noctalia must be running."; then
  while read -r plugin; do
    noctalia msg plugins enable "$plugin" </dev/null >/dev/null || echo "skipped: $plugin"
  done <"$work/plugins"
fi

wanted services system >"$work/system"
wanted services user >"$work/user"
if [ -n "$(cat "$work/system" "$work/user")" ] && ask "Turn on the saved services?"; then
  # One at a time, so a unit this system does not have does not stop the others.
  while read -r unit; do
    sudo systemctl enable "$unit" </dev/null 2>/dev/null || echo "skipped: $unit"
  done <"$work/system"
  while read -r unit; do
    systemctl --user enable "$unit" </dev/null 2>/dev/null || echo "skipped: $unit"
  done <"$work/user"
fi

# The owner's own steps, in name order, each with the same variables as when saving: the
# shared ones in hooks/restore/, then this device's own in devices/<name>/hooks/restore/.
cd "$repo" || exit 1
run_steps() {
  [ -d "$1" ] || return 0
  for hook in "$1"/*; do
    [ -f "$hook" ] && [ -x "$hook" ] || continue
    if ask "Run your step $(basename "$hook")?"; then
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
echo "Done. Log out and back in to load everything."
printf 'Press Enter to close. '
read -r _
