#!/usr/bin/env bash
# txn.lua against a throwaway directory. systemd-run and systemctl are fakes
# that record their arguments, so nothing touches the real session.
set -u
here=$(cd "$(dirname "$0")" && pwd)
txn="$here/../txn.lua"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/data" "$tmp/dotfiles" "$tmp/config"

cat > "$tmp/bin/systemd-run" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$tmp/systemd-run.log"
exit \${FAKE_SYSTEMD_RUN_EXIT:-0}
EOF
cat > "$tmp/bin/systemctl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$tmp/systemctl.log"
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

data="$tmp/data"
real="$tmp/dotfiles/hyprland-settings.lua"
link="$tmp/config/hyprland-settings.lua"
ln -s "$real" "$link"

failures=0
check() { # name, condition...
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; failures=$((failures + 1)); fi
}
run() { flock -w 10 "$data/lock" lua "$txn" "$@" >/dev/null 2>&1; }
gaps() { echo "hl.config({ general = { gaps_in = $1 } })"; }
begin() { # id, gaps value, [seconds], [adopt]
  gaps "$2" > "$data/candidate.$1.lua"
  run begin "$data" "$link" "$1" "${3:-15}" ${4:-}
}

# 1. first write through the symlink into a missing file
begin t1 1; code=$?
check "first write exits 0" test $code -eq 0
check "link is still a symlink" test -L "$link"
check "real file has the candidate" grep -q 'gaps_in = 1' "$real"
check "candidate consumed" test ! -e "$data/candidate.t1.lua"
check "watchdog armed for 20 s" grep -q -- '--unit=hyprland-settings-revert-t1 --on-active=20' "$tmp/systemd-run.log"
check "deadline is on the boot clock" grep -q '^boot=' "$data/txn"

# 2. a second begin while pending is refused
begin t2 2; code=$?
check "second begin is busy (3)" test $code -eq 3

# 3. keep confirms; a late revert (the watchdog) must not undo it
run keep "$data" t1; code=$?
check "keep exits 0" test $code -eq 0
check "keep is a single status write" grep -q "status=confirmed" "$data/txn"
run revert "$data" t1; code=$?
check "revert after keep is refused (1)" test $code -eq 1
check "confirmed change stays" grep -q 'gaps_in = 1' "$real"
check "keep stopped the timer" grep -q 'stop hyprland-settings-revert-t1.timer' "$tmp/systemctl.log"

# 4. revert restores the previous text
begin t3 3
run revert "$data" t3; code=$?
check "revert exits 0" test $code -eq 0
check "old text is back" grep -q 'gaps_in = 1' "$real"
run revert "$data" t3; code=$?
check "second revert is refused, file unchanged" test $code -eq 1

# 5. an outside edit during the countdown is reported, not overwritten
begin t4 4
echo '-- edited by hand' >> "$real"
run keep "$data" t4; code=$?
check "keep refuses an outside edit (2)" test $code -eq 2
run revert "$data" t4; code=$?
check "revert conflict exits 2" test $code -eq 2
check "outside edit kept" grep -q 'edited by hand' "$real"
check "backup of the conflict kept" grep -q 'gaps_in = 1' "$data/backup-t4.lua"

# 6. a file edited since the last save is not ours any more
begin t5 5; code=$?
check "edited file is refused (7)" test $code -eq 7
check "edited file unchanged" grep -q 'edited by hand' "$real"

# 7. a hand-written file needs adopt, and its original is kept for good
rm -f "$data/current.lua"
echo '-- my own config' > "$real"
begin t6 6; code=$?
check "hand-written file is refused (7)" test $code -eq 7
check "hand-written file unchanged" grep -q 'my own config' "$real"
begin t7 7 15 adopt; code=$?
check "adopt takes it over" test $code -eq 0
check "original kept for good" grep -q 'my own config' "$data/original-t7.lua"
run revert "$data" t7
check "revert gives the hand-written file back" grep -q 'my own config' "$real"

# 8. a syntax error never reaches the target
echo 'hl.config({' > "$data/candidate.t8.lua"
run begin "$data" "$link" t8 15 adopt; code=$?
check "syntax error exits 4" test $code -eq 4
check "target unchanged after syntax error" grep -q 'my own config' "$real"

# 9. no watchdog, no change
FAKE_SYSTEMD_RUN_EXIT=1 begin t9 9 15 adopt; code=$?
check "failed watchdog exits 5" test $code -eq 5
check "target unchanged without watchdog" grep -q 'my own config' "$real"

# 10. the recorded watchdog command really reverts
begin t10 10 15 adopt
cmdline=$(grep -- 'revert-t10' "$tmp/systemd-run.log" | sed 's/.*--on-active=[0-9]* //')
eval "$cmdline" >/dev/null 2>&1
check "watchdog command reverts" grep -q 'my own config' "$real"

# 11. keep after the deadline is refused; revert still works
begin t11 11 0 adopt
run keep "$data" t11; code=$?
check "expired keep is refused (1)" test $code -eq 1
run revert "$data" t11; code=$?
check "expired txn reverts" test $code -eq 0 && grep -q 'my own config' "$real"

# 12. crashes in the middle are safe to repeat
cp "$real" "$data/backup.lua"
printf 'id=t12\ntarget=%s\nhad_old=1\nstatus=prepared\n' "$real" > "$data/txn"
run revert "$data" t12; code=$?
check "crash before replace: revert is a no-op" test $code -eq 0 && grep -q 'my own config' "$real"
printf 'id=t13\ntarget=%s\nhad_old=1\nstatus=pending\n' "$real" > "$data/txn"
gaps 13 > "$data/applied.lua"
run revert "$data" t13; code=$?
check "crash after restore: no false conflict" test $code -eq 0 && grep -q 'my own config' "$real"

# 13. a target that cannot be read is never treated as missing
rm -f "$real"; mkdir "$real"
begin t14 14 15 adopt; code=$?
check "unreadable target stops begin (6)" test $code -eq 6
check "unreadable target untouched" test -d "$real"
check "nothing pending after the failure" test "$(grep status "$data/txn")" != "status=pending"

# 14. ownership follows confirm/revert, also across a failed begin
rm -rf "$real" "$data"/*; mkdir -p "$data"
begin o1 21; run keep "$data" o1
echo 'hl.config({' > "$data/candidate.o2.lua"
run begin "$data" "$link" o2 15; code=$?
check "broken candidate after a confirm is refused (4)" test $code -eq 4
begin o3 23; code=$?
check "the confirmed file is still ours after that" test $code -eq 0
run revert "$data" o3
begin o4 24; code=$?
check "after a revert the older confirmed file is ours" test $code -eq 0
run keep "$data" o4
check "keep is one write: no current.lua churn" grep -q 'gaps_in = 21' "$data/current.lua"
begin o5 25; code=$?
check "next begin owns the kept text" test $code -eq 0 && grep -q 'gaps_in = 24' "$data/current.lua"

# 15. an empty file (the README's first step) is taken over without adopt
rm -rf "$real" "$data"/*; mkdir -p "$data"; : > "$real"
begin e1 31; code=$?
check "empty file needs no adopt" test $code -eq 0
check "no original kept for an empty file" test ! -e "$data/original-e1.lua"

echo "$failures failure(s)"
exit $((failures > 0))
