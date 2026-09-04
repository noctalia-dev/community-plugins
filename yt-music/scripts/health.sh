#!/usr/bin/env bash
# Invoked via:  bash scripts/health.sh <fn> <args...>
# Dependency health check, run once at boot before the browser list is shown.
# Prints HEALTH=<name>:<status>:<detail> lines; status is ok, warn or missing.

# $1=name $2=status $3=detail
report() {
  echo "HEALTH=$1:$2:$3"
}

check_ytdlp() {
  command -v yt-dlp >/dev/null 2>&1 || { report "ytdlp" "missing" "not on PATH"; return; }
  local ver
  ver=$(yt-dlp --version 2>/dev/null | head -1)
  # Flag builds older than ~6 months: rotted extractors are the usual cause
  # of mysterious resolve failures. Unparseable versions pass silently.
  local day
  day=$(date -d "$(echo "$ver" | tr '.' '-')" +%s 2>/dev/null)
  if [ -n "$day" ] && [ $(( ($(date +%s) - day) / 86400 )) -gt 180 ]; then
    report "ytdlp" "warn" "$ver (stale)"
  else
    report "ytdlp" "ok" "$ver"
  fi
}

check_mpv() {
  command -v mpv >/dev/null 2>&1 || { report "mpv" "missing" "not on PATH"; return; }
  report "mpv" "ok" "$(mpv --version 2>/dev/null | head -1)"
}

check_nc() {
  command -v nc >/dev/null 2>&1 || { report "nc" "missing" "not on PATH"; return; }
  # ncat names itself in its help line; any other nc that accepts -U can
  # only be openbsd's. Both give mpv IPC; traditional/busybox don't.
  local variant="openbsd-netcat"
  case "$(nc -h 2>&1 | head -1)" in *[Nn]cat*) variant="ncat" ;; esac
  local err
  err=$(printf '' | nc -U -w1 /tmp/yt-music-ipc-probe 2>&1)
  case "$err" in
    *nvalid*|*sage*|*llegal*) report "nc" "warn" "no unix sockets — install openbsd-netcat or ncat" ;;
    *) report "nc" "ok" "$variant" ;;
  esac
}

check_curl() {
  command -v curl >/dev/null 2>&1 || { report "curl" "missing" "not on PATH"; return; }
  local ver vnum
  ver=$(curl --version 2>/dev/null | head -1 | awk '{print $2}')
  vnum=$(echo "$ver" | awk -F. '{ if ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/) print ($1 * 1000) + $2 }')
  # Thumbnails fetch with --parallel-immediate, which needs curl 7.68+.
  if [ -n "$vnum" ] && [ "$vnum" -ge 7068 ]; then
    report "curl" "ok" "curl $ver"
  else
    report "curl" "warn" "${ver:-unknown version} (too old for parallel fetching)"
  fi
}

check_jq() {
  command -v jq >/dev/null 2>&1 || { report "jq" "missing" "not on PATH"; return; }
  report "jq" "ok" "$(jq --version 2>/dev/null)"
}

health_check() {
  check_ytdlp
  check_mpv
  check_nc
  check_curl
  check_jq
}

fn="${1:?fn required}"; shift
type -t "$fn" >/dev/null 2>&1 || { echo "unknown fn: $fn" >&2; exit 1; }
"$fn" "$@"
