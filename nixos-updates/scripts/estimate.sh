#!/bin/sh
# Download estimate for the button in the panel, never run on its own: what the
# system built from the updated lock of the last check needs that is not in the
# Nix store yet, by nix build --dry-run. Nothing is built; Nix asks the binary
# caches which store paths they have and how large they are.
#
#   estimate.sh <out_dir> <flake_dir> <nixos_configuration>
#
# Same protocol as check.sh (step, fail, done). Result: dry-run.txt, and
# estimate.lock, a copy of the lock it was made for, so a later check can tell
# whether the estimate still applies.

set -u
umask 077
out=$1
dir=$2
cfg=$3

err="$out/stderr-estimate"
rc=0
# 10 minutes plus 30 seconds for timeout -k; the service waits longer.
. "$(dirname "$0")/lib.sh"

[ -n "$cfg" ] || cfg=$(cat /proc/sys/kernel/hostname)
rm -f "$out/dry-run.txt" "$out/estimate.lock"
echo "step size"
if [ ! -f "$out/new.lock" ]; then
	echo "fail size no-lock"
elif run_nix 10 build --dry-run --no-link --no-write-lock-file --reference-lock-file "$out/new.lock" \
	"$dir#nixosConfigurations.\"$cfg\".config.system.build.toplevel" >/dev/null 2>"$err"; then
	mv "$err" "$out/dry-run.txt"
	cp "$out/new.lock" "$out/estimate.lock"
else
	fail size
fi
rm -f "$err"
echo "done"
