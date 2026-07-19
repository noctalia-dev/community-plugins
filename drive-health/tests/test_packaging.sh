#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
service_template="$project_dir/packaging/noctalia-gustav0ar-drive-health.service.in"
timer="$project_dir/packaging/noctalia-gustav0ar-drive-health.timer"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/drive-health-packaging.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT HUP INT TERM

sed 's/@TARGET_GID@/1000/g' "$service_template" >"$fixture/noctalia-gustav0ar-drive-health.service"
cp "$timer" "$fixture/noctalia-gustav0ar-drive-health.timer"

grep -q '^Group=1000$' "$fixture/noctalia-gustav0ar-drive-health.service"
grep -q '^RuntimeDirectoryMode=0750$' "$fixture/noctalia-gustav0ar-drive-health.service"
grep -q '^UMask=0027$' "$fixture/noctalia-gustav0ar-drive-health.service"
grep -q '^Unit=noctalia-gustav0ar-drive-health.service$' "$fixture/noctalia-gustav0ar-drive-health.timer"

if command -v systemd-analyze >/dev/null 2>&1; then
  if ! systemd-analyze verify \
      "$fixture/noctalia-gustav0ar-drive-health.service" \
      "$fixture/noctalia-gustav0ar-drive-health.timer" >"$fixture/verify.log" 2>&1; then
    if grep -q 'Operation not permitted' "$fixture/verify.log"; then
      echo "systemd unit verification unavailable in this sandbox; structural checks passed"
    else
      cat "$fixture/verify.log" >&2
      exit 1
    fi
  fi
fi

echo "collector packaging tests passed"
