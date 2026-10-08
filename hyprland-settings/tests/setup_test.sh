#!/usr/bin/env bash
# setup.lua against a throwaway config directory.
set -u
here=$(cd "$(dirname "$0")" && pwd)
setup="$here/../setup.lua"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/dotfiles" "$tmp/hypr" "$tmp/backup"
failures=0
check() {
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; failures=$((failures + 1)); fi
}
run() { lua "$setup" "$tmp/hypr/hyprland.lua" "$tmp/hypr/hyprland-settings.lua" hyprland-settings "$tmp/backup" 2>/dev/null; }

# 1. hyprland.lua is a symlink into dotfiles, without the line
printf 'require("optik")\nhl.config({ general = { gaps_in = 3 } })' > "$tmp/dotfiles/hyprland.lua"
ln -s "$tmp/dotfiles/hyprland.lua" "$tmp/hypr/hyprland.lua"
out=$(run); code=$?
check "adds the line" test "$code" -eq 0 -a "$out" = "added"
check "require is at the end" test "$(tail -1 "$tmp/dotfiles/hyprland.lua")" = 'require("hyprland-settings")'
check "existing content kept" grep -q 'gaps_in = 3' "$tmp/dotfiles/hyprland.lua"
check "symlink kept" test -L "$tmp/hypr/hyprland.lua"
check "settings file created empty" test -f "$tmp/hypr/hyprland-settings.lua" -a ! -s "$tmp/hypr/hyprland-settings.lua"
check "backup of the original" grep -q 'gaps_in = 3' "$tmp/backup"/hyprland.lua.before-setup-*
check "result passes luac" luac -p "$tmp/dotfiles/hyprland.lua"

# 2. running again changes nothing
before=$(cat "$tmp/dotfiles/hyprland.lua")
out=$(run); code=$?
check "second run reports present" test "$code" -eq 0 -a "$out" = "present"
check "second run changes nothing" test "$(cat "$tmp/dotfiles/hyprland.lua")" = "$before"

# 3. a hand-written require (other quotes, no parentheses) counts as present
printf "require 'hyprland-settings'\n" > "$tmp/dotfiles/hyprland.lua"
out=$(run)
check "own require style is recognized" test "$out" = "present"

# 4. a broken hyprland.lua is not touched
printf 'hl.config({\n' > "$tmp/dotfiles/hyprland.lua"
run; code=$?
check "syntax error stops (4)" test $code -eq 4
check "broken file untouched" test "$(cat "$tmp/dotfiles/hyprland.lua")" = 'hl.config({'

# 5. only hyprland.conf: not supported
rm "$tmp/hypr/hyprland.lua"; : > "$tmp/hypr/hyprland.conf"
run; code=$?
check "conf-only setup refused (3)" test $code -eq 3

echo "$failures failure(s)"
exit $((failures > 0))
