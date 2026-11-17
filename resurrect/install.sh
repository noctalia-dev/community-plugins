#!/bin/sh
# Installs packages and turns on services that other devices have, in a terminal the panel
# opens:
#   install.sh <file>
# Each line of the file is "<list> <name>", where <list> is pacman, aur, apt, dnf or flatpak,
# or system or user for a service. It shows the names and asks first. Services start from
# the next boot or login. Then it saves again, so the panel shows what is still missing.
set -u

file=$1

# The names of one list, on one line each. Only letters, digits and @ . _ + : -, not starting
# with "-", so a name from another device is never read as an option.
names() {
  sed -n "s/^$1 //p" "$file" | grep -E '^[[:alnum:]@_+][[:alnum:]@._+:-]*$'
}

for list in pacman aur apt dnf flatpak system user; do
  [ -n "$(names "$list")" ] && printf '%s: %s\n' "$list" "$(names "$list" | tr '\n' ' ')"
done
printf '\nInstall the packages and turn on the services listed above? [y/N] '
read -r answer
if [ "$answer" != y ] && [ "$answer" != Y ]; then
  rm -f "$file"
  exit 0
fi

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
  names apt | xargs sudo apt-get install -y --
fi
if [ -n "$(names dnf)" ]; then
  names dnf | xargs sudo dnf install -y --
fi
if [ -n "$(names flatpak)" ]; then
  names flatpak | xargs flatpak install -y --
fi
# One at a time, so a unit this system does not have does not stop the others.
for unit in $(names system); do
  sudo systemctl enable -- "$unit" || echo "skipped: $unit"
done
for unit in $(names user); do
  systemctl --user enable -- "$unit" || echo "skipped: $unit"
done

rm -f "$file"
command -v noctalia >/dev/null && noctalia msg plugin omerfuyar/resurrect:service all save >/dev/null
printf 'Done. Press Enter to close. '
read -r _
