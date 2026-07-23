#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
service_template="$project_dir/packaging/noctalia-drive-health.service.in"
timer="$project_dir/packaging/noctalia-drive-health.timer"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/drive-health-packaging.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT HUP INT TERM

sed 's/@TARGET_GID@/1000/g' "$service_template" >"$fixture/noctalia-drive-health.service"
cp "$timer" "$fixture/noctalia-drive-health.timer"

grep -q '^Group=1000$' "$fixture/noctalia-drive-health.service"
grep -q '^RuntimeDirectoryMode=0750$' "$fixture/noctalia-drive-health.service"
grep -q '^UMask=0027$' "$fixture/noctalia-drive-health.service"
grep -q '^Unit=noctalia-drive-health.service$' "$fixture/noctalia-drive-health.timer"

if grep -R -q 'noctalia-smart-monito[r]' "$project_dir"; then
  echo "generic legacy collector namespace must not be read, modified, or removed" >&2
  exit 1
fi

if grep -R -q 'noctalia-gustav0ar-drive-healt[h]' "$project_dir"; then
  echo "publisher-specific collector namespace must not be packaged" >&2
  exit 1
fi

declared_dependencies=$(sed -n 's/^dependencies = \[\(.*\)\]$/\1/p' "$project_dir/plugin.toml")
for dependency in \
    lsblk smartctl sh date dirname mkdir mktemp rm sed cat chmod mv sudo env bash \
    install systemctl pkexec id tr pacman apt-get dnf zypper apk xbps-install emerge; do
  case "$declared_dependencies" in
    *\"$dependency\"*) ;;
    *)
      echo "runtime command is missing from plugin.toml dependencies: $dependency" >&2
      exit 1
      ;;
  esac
  grep -q "\`$dependency\`" "$project_dir/README.md" || {
    echo "runtime command is missing from README requirements: $dependency" >&2
    exit 1
  }
done

if command -v systemd-analyze >/dev/null 2>&1; then
  if ! systemd-analyze verify \
      "$fixture/noctalia-drive-health.service" \
      "$fixture/noctalia-drive-health.timer" >"$fixture/verify.log" 2>&1; then
    if grep -q 'Operation not permitted' "$fixture/verify.log"; then
      echo "systemd unit verification unavailable in this sandbox; structural checks passed"
    else
      cat "$fixture/verify.log" >&2
      exit 1
    fi
  fi
fi

echo "collector packaging tests passed"
