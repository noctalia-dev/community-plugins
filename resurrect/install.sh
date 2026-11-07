#!/bin/sh
# Installs packages and turns on services that other devices have, in a terminal the panel
# opens:
#   install.sh <file>
# Each line of the file is "<list> <name>", where <list> is pacman, aur, apt, dnf or flatpak,
# or system or user for a service. Services start from the next boot or login. Then it saves
# again, so the panel shows what is still missing.
set -u

file=$1

# The names of one list, on one line each.
names() {
  awk -v list="$1" '$1 == list { print $2 }' "$file"
}

if [ -n "$(names pacman)" ]; then
  # shellcheck disable=SC2024 # the list is read by this user, not by root
  names pacman | sudo pacman -S --needed -
fi
if [ -n "$(names aur)" ]; then
  helper=$(command -v paru || command -v yay || true)
  if [ -n "$helper" ]; then
    names aur | "$helper" -S --needed -
  else
    echo "AUR packages need paru or yay: $(names aur | tr '\n' ' ')"
  fi
fi
if [ -n "$(names apt)" ]; then
  names apt | xargs sudo apt-get install -y
fi
if [ -n "$(names dnf)" ]; then
  names dnf | xargs sudo dnf install -y
fi
if [ -n "$(names flatpak)" ]; then
  names flatpak | xargs flatpak install -y
fi
# One at a time, so a unit this system does not have does not stop the others.
for unit in $(names system); do
  sudo systemctl enable "$unit" || echo "skipped: $unit"
done
for unit in $(names user); do
  systemctl --user enable "$unit" || echo "skipped: $unit"
done

rm -f "$file"
command -v noctalia >/dev/null && noctalia msg plugin omerfuyar/resurrect:service all save >/dev/null
printf 'Done. Press Enter to close. '
read -r _
