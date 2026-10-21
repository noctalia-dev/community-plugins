#!/bin/bash

# Run a command with no deadline and record its result for the service.
#
#   run-detached.sh PREFIX -- CMD [ARG...]
#
# noctalia.runAsync clamps every timeout to 60s, which is too short for a picker
# the user may take minutes to finish, and for finalizing a long recording. The
# service launches this instead, with no callback, and polls PREFIX.code: it is
# written last, so its appearance means PREFIX.out and PREFIX.err are complete.
#
# Writes PREFIX.out, PREFIX.err and PREFIX.code (the exit status).

set -uo pipefail

prefix=${1:-}
shift
[[ ${1:-} == "--" ]] && shift

if [[ -z $prefix || $# -eq 0 ]]; then
  echo "usage: $(basename "$0") PREFIX -- CMD [ARG...]" >&2
  exit 2
fi

out="$prefix.out"
err="$prefix.err"
code="$prefix.code"
tmp_out="$prefix.out.$$"
tmp_err="$prefix.err.$$"

rm -f "$out" "$err" "$code"
"$@" >"$tmp_out" 2>"$tmp_err"
rc=$?
mv -f "$tmp_out" "$out"
mv -f "$tmp_err" "$err"
printf '%s' "$rc" >"$prefix.code.$$"
mv -f "$prefix.code.$$" "$code"
exit 0
