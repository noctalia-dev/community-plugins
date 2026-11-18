#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> lint"
noctalia plugins lint .

echo "==> unit tests"
lua5.4 tests/group_order_test.lua

if command -v noctalia >/dev/null 2>&1 && pgrep -x noctalia >/dev/null 2>&1; then
  echo "==> ipc refresh"
  noctalia msg plugin mdj2812/mihomo-control:service all refresh

  echo "==> ipc self-test"
  noctalia msg plugin mdj2812/mihomo-control:service all self-test
else
  echo "==> skipping live IPC tests (noctalia is not running)"
fi

echo "mihomo-control smoke tests: ok"
