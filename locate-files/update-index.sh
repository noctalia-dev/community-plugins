#!/bin/sh

set -u
umask 077

if [ "$#" -lt 5 ]; then
  exit 2
fi

database=$1
paths_cache=$2
status_file=$3
token=$4
shift 4

staged_database="$database.tmp.$token"
staged_cache="$paths_cache.tmp.$token"

cleanup() {
  rm -f "$staged_database" "$staged_cache"
}

trap cleanup EXIT HUP INT TERM

exec 9>"$database.lock"
if ! flock -n 9; then
  exit 0
fi

write_status() {
  status=$1
  printf '%s|%s\n' "$status" "$token" >"$status_file.tmp"
  mv -f "$status_file.tmp" "$status_file"
}

write_status running

if "$@" >"$database.log" 2>&1 \
  && locate -d "$staged_database" -0 / >"$staged_cache" 2>>"$database.log" \
  && [ -s "$staged_database" ] \
  && [ -s "$staged_cache" ] \
  && chmod 600 "$staged_database" "$staged_cache" \
  && mv -f "$staged_cache" "$paths_cache" \
  && mv -f "$staged_database" "$database"; then
  trap - EXIT HUP INT TERM
  write_status ready
else
  code=$?
  printf 'error|%s|%s\n' "$token" "$code" >"$status_file.tmp"
  mv -f "$status_file.tmp" "$status_file"
fi
