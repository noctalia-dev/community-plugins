#!/usr/bin/env bash
# Smoke test for the `faminec/terminal-widgets` plugin on the desktop.
#
# Requires Hyprland with Noctalia and the plugin enabled. Opens the panel, launches
# every widget, checks they are all there, rotates them, checks that positions
# are permuted, closes them and closes the panel. At the end it reviews
# **all** new log lines from the first to the last step, even if the test fails
# earlier, and fails on any [WRN] or [ERR], whether from the plugin or not.
#
#
#   ./test-smoke.sh                  # uses the installed plugin
#   ./test-smoke.sh /path/to/other   # uses the manifest of another copy
#
# Exits with a non-zero code if anything fails.
#
# Variables: NOCTALIA_LOG (log path), OPEN_TIMEOUT, ROTATE_TIMEOUT,
# CLOSE_TIMEOUT (max wait in seconds for each step).

set -u

PLUGIN_ID="faminec/terminal-widgets"
PANEL="$PLUGIN_ID:panel"
PLUGIN_DIR="${1:-$HOME/.local/share/noctalia/plugins/terminal-widgets}"
LOG="${NOCTALIA_LOG:-$HOME/.cache/noctalia/noctalia.log}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/noctalia"
STORE="$STATE_DIR/plugins/data/$PLUGIN_ID/store.json"

OPEN_TIMEOUT="${OPEN_TIMEOUT:-45}"
ROTATE_TIMEOUT="${ROTATE_TIMEOUT:-15}"
CLOSE_TIMEOUT="${CLOSE_TIMEOUT:-20}"
# Settle margin after opening so a command that ends on its own and takes its
# window with it is noticed (`cbonsai -l -p` took ~7 s to print and exit).
SETTLE="${SETTLE:-8}"

LOG_READY=0
LOG_CHECKED=0
FOLLOWER_PID=""
tmp=""

stop_follower() {
  if [ -n "$FOLLOWER_PID" ]; then
    kill "$FOLLOWER_PID" 2>/dev/null || true
    wait "$FOLLOWER_PID" 2>/dev/null || true
    FOLLOWER_PID=""
  fi
}

cleanup() {
  stop_follower
  if [ -n "$tmp" ]; then
    rm -rf "$tmp"
  fi
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  # Even if the test is cut short, the new log lines are still reviewed: a
  # failure cannot hide warnings or errors.
  if [ "$LOG_READY" -eq 1 ] && [ "$LOG_CHECKED" -eq 0 ]; then
    # Flush before reviewing: otherwise the plugin's last lines may still be
    # in the host buffer and the failure would lack context.
    if [ -n "$FOLLOWER_PID" ]; then
      flush_log >/dev/null 2>&1 || true
      stop_follower
    fi
    echo "--- new [WRN]/[ERR] in the log up to the failure ---" >&2
    review_log >&2 || true
  fi
  exit 1
}

if ! command -v noctalia >/dev/null 2>&1; then
  echo "noctalia is not on PATH; this test needs the desktop" >&2
  exit 2
fi

if ! command -v hyprctl >/dev/null 2>&1; then
  echo "hyprctl is not on PATH; this test needs Hyprland" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is not on PATH; it is needed to read the configuration" >&2
  exit 2
fi

[ -f "$PLUGIN_DIR/plugin.toml" ] || fail "cannot find the manifest at $PLUGIN_DIR/plugin.toml"

# Number of widgets that should end up open: the non-empty commands resulting
# from merging the defaults (manifest or lib/defaults.luau fallback) and the
# panel store, minus deletions. It is the same precedence used by
# `lib/store.luau`; Noctalia Settings no longer participates.
expected_line=$(python3 - "$PLUGIN_DIR/plugin.toml" "$STORE" <<'PY'
import json
import os
import re
import sys
import tomllib

manifest_path, store_path = sys.argv[1:3]
plugin_dir = os.path.dirname(manifest_path)

base = {}
with open(manifest_path, "rb") as handle:
    manifest = tomllib.load(handle)
for setting in manifest.get("setting", []):
    if setting.get("key") == "commands" and isinstance(setting.get("default"), dict):
        base = setting["default"]

# If the manifest no longer carries the commands, the plugin uses the fallback
# table from lib/defaults.luau. It is read here so the test computes the same.
if not base:
    defaults_path = os.path.join(plugin_dir, "lib", "defaults.luau")
    try:
        with open(defaults_path, encoding="utf-8") as handle:
            text = handle.read()
        block = re.search(r"FALLBACK_COMMANDS\s*=\s*\{(.*?)\}", text, re.S)
        if block:
            base = dict(re.findall(r'([A-Za-z0-9_%-]+)\s*=\s*"([^"]*)"', block.group(1)))
    except FileNotFoundError:
        pass

store = {}
try:
    with open(store_path, encoding="utf-8") as handle:
        store = json.load(handle)
except FileNotFoundError:
    pass

commands = {name: value for name, value in base.items() if isinstance(value, str) and value}
commands.update({name: value for name, value in (store.get("commands") or {}).items() if isinstance(value, str)})
for name in store.get("removed") or []:
    commands.pop(name, None)

names = sorted(name for name, value in commands.items() if value)
print(len(names), " ".join(names))
PY
) || fail "could not read the widget configuration"
read -r expected names <<<"$expected_line"
[ "$expected" -ge 1 ] || fail "no widgets are configured"
echo "expected widgets: $expected ($names)"

# The host rotates/truncates `noctalia.log` and its script-runtime lines may
# take a while to flush. `tail -F` follows the file (even if it is renamed or
# truncated) and leaves a private copy with all the new lines; the smoke test
# reviews that copy, not the volatile file.
#
# Close panels from other sessions to reduce host load during the test
# (runtime action, it does not touch other plugins' code; their timers reopen
# them). Can be disabled with CLOSE_FOREIGN_PANELS=0.
if [ "${CLOSE_FOREIGN_PANELS:-1}" != "0" ]; then
  for p in faminec/wallpaper-carousel:panel faminec/lyrics-carousel:panel \
           faminec/notes:panel faminec/notes-sync:panel \
           faminec/cmf-buds:panel faminec/cmf-buds:panel-sound; do
    noctalia msg panel-close "$p" >/dev/null 2>&1 || true
  done
fi

# Before capturing anything, wait for the host to be idle (10 s without log
# growth): otherwise the test drags in noise from other sessions and may
# trigger the host's own performance warnings.
echo "waiting for the host to be idle (up to 60 s)..."
last=0; stable=0; iters=0
if [ -f "$LOG" ]; then
  last=$(wc -l <"$LOG")
fi
while [ "$stable" -lt 50 ] && [ "$iters" -lt 300 ]; do
  sleep 0.2
  iters=$((iters + 1))
  if [ -f "$LOG" ]; then
    cur=$(wc -l <"$LOG")
  else
    cur=0
  fi
  if [ "$cur" -eq "$last" ]; then
    stable=$((stable + 1))
  else
    stable=0
    last=$cur
  fi
done
echo "host idle; starting the test."

tmp=$(mktemp -d /tmp/opencode/terminal-widgets-smoke.XXXXXX) || {
  echo "could not create the temporary directory" >&2
  exit 2
}
# Robust follower: drains the old file to the end before switching to the new
# one when the host rotates/truncates the log (tail -F may lose lines).
python3 - "$LOG" "$tmp/run.log" <<'PY' &
import os
import sys
import time

log, out = sys.argv[1], sys.argv[2]
f = open(out, "ab", buffering=0)
fh = None
inode = None
try:
    fh = open(log, "rb")
    fh.seek(0, os.SEEK_END)
    inode = os.fstat(fh.fileno()).st_ino
except FileNotFoundError:
    fh = None
    inode = None

while True:
    time.sleep(0.1)
    try:
        st = os.stat(log)
    except FileNotFoundError:
        continue
    if fh is None or st.st_ino != inode:
        if fh is not None:
            # Drain the old file to the end; the host may write the closing
            # line right after rotating, so it is re-read once more after a
            # short wait.
            for _ in range(2):
                try:
                    data = fh.read()
                    if data:
                        f.write(data)
                except Exception:
                    pass
                time.sleep(0.2)
            try:
                fh.close()
            except Exception:
                pass
        try:
            fh = open(log, "rb")
            inode = os.fstat(fh.fileno()).st_ino
            fh.seek(0, os.SEEK_END)
        except FileNotFoundError:
            fh = None
            inode = None
            continue
    try:
        pos = fh.tell()
        size = os.fstat(fh.fileno()).st_size
    except Exception:
        continue
    if pos > size:
        fh.seek(0)
    try:
        data = fh.read()
    except Exception:
        continue
    if data:
        f.write(data)
PY
FOLLOWER_PID=$!
sleep 0.2

# Wait up to $2 s for $tmp/run.log to stop growing for $1 s in a row (no new
# activity). Always returns 0: it is a stability wait, not a success
# criterion.
wait_log_quiet() {
  local quiet="${1:-1}"
  local max="${2:-5}"
  local deadline=$((SECONDS + max)) last cur stable=0
  last=$(wc -l <"$tmp/run.log" 2>/dev/null || echo 0)
  while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.2
    cur=$(wc -l <"$tmp/run.log" 2>/dev/null || echo 0)
    if [ "$cur" -eq "$last" ]; then
      stable=$((stable + 1))
      if [ "$stable" -ge $((quiet * 5)) ]; then
        return 0
      fi
    else
      stable=0
      last="$cur"
    fi
  done
  return 0
}

# Stable starting point: wait for the log to stop growing for one second, so
# the review does not drag in noise from the previous run or from startup.
wait_log_quiet 5 25
LOG_READY=1

# Review all new log lines (the copy), without excluding any pattern: any
# [WRN] or [ERR] fails the test, whether from the plugin or not.
review_log() {
  local total plugin_lines problems
  if [ ! -f "$tmp/run.log" ]; then
    echo "   (no log copy; cannot check)" >&2
    return 1
  fi
  total=$(wc -l <"$tmp/run.log")
  # The stable count is the plugin's (own lines + panel + reload + hot-reload);
  # the host adds unrelated noise that varies between runs. The [WRN]/[ERR]
  # review is done over ALL lines, without filtering.
  plugin_lines=$(grep -c -E "terminal-widgets|panel\.luau'" "$tmp/run.log" 2>/dev/null || true)
  [ -n "$plugin_lines" ] || plugin_lines=0
  problems=$(grep -E "\[WRN\]|\[ERR\]" "$tmp/run.log" || true)
  if [ -n "$problems" ]; then
    echo "   $total host lines ($plugin_lines from the plugin); warnings/errors found:" >&2
    printf '%s\n' "$problems" >&2
    return 1
  fi
  echo "   $total host lines reviewed ($plugin_lines from the plugin); no [WRN]/[ERR] ✔"
  return 0
}

# Wait up to $2 seconds for $1 to appear in the new lines of $3 (the log copy)
# from mark $4. The host's native lines are written immediately; script-runtime
# lines may still be in the buffer.
wait_log_line() {
  local pattern="$1" deadline=$((SECONDS + ${2:-2})) file="${3:-$tmp/run.log}" mark="${4:-0}"
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -f "$file" ] && tail -n +"$((mark + 1))" "$file" | grep -q "$pattern"; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

# The host writes script-runtime logs to a buffer and may take tens of seconds
# to flush them to the file. `log-level-set` with the current level is a no-op
# that writes a native line and drains that buffer; wait for that line to
# appear in the copy so an incomplete log is not reviewed.
flush_log() {
  local level mark deadline
  level=$(noctalia msg log-level-status 2>/dev/null) || return 1
  [ -n "$level" ] || return 1
  mark=$(wc -l <"$tmp/run.log" 2>/dev/null || echo 0)
  deadline=$((SECONDS + 12))
  # The host may take several seconds to process the queue: retry and wait for
  # any native line to reach the copy. Since they come after the plugin lines,
  # seeing one implies those were flushed too.
  # volcaron.
  while [ "$SECONDS" -lt "$deadline" ]; do
    noctalia msg log-level-set "$level" >/dev/null 2>&1 || return 1
    if wait_log_line "log level set to $level" 2 "$tmp/run.log" "$mark"; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

plugin_geometry() {
  hyprctl clients -j 2>/dev/null | python3 -c '
import json
import sys

try:
    clients = json.load(sys.stdin)
except Exception:
    clients = []

for client in sorted(
    (c for c in clients if c.get("class", "").startswith("noctalia-term-")),
    key=lambda c: c.get("class", ""),
):
    at = client.get("at") or [0, 0]
    print(client.get("class", ""), int(at[0]), int(at[1]))
'
}

plugin_count() {
  plugin_geometry | grep -c . || true
}

# Wait until there are exactly $1 plugin windows, up to $2 seconds.
wait_count() {
  local target="$1" deadline=$((SECONDS + $2))
  while :; do
    [ "$(plugin_count)" -eq "$target" ] && return 0
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 0.3
  done
}

# Wait for the geometry to stop changing for ~1 s. The counter reaches its
# number as soon as the window exists, but the plugin places and resizes it a
# moment later: without this, the rotation "before" would be a snapshot
# mid-placement and the permutation would not match.
wait_stable() {
  local deadline=$((SECONDS + 10)) previous current stable=0
  previous=$(plugin_geometry)
  while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.4
    current=$(plugin_geometry)
    if [ "$current" = "$previous" ]; then
      stable=$((stable + 1))
      [ "$stable" -ge 2 ] && return 0
    else
      stable=0
      previous="$current"
    fi
  done
  return 1
}

# Active panel according to the host. It is the only reliable source: another
# plugin can steal focus and the log may take seconds to flush.
active_panel() {
  noctalia msg status 2>/dev/null | python3 -c '
import json
import sys

try:
    print(json.load(sys.stdin).get("activePanelId") or "")
except Exception:
    print("")
'
}

# The panel only handles IPC while it is open and active. `panel-open` is
# idempotent: if it is already open it reactivates it. It is checked against
# the host's real state, not the log.
ensure_panel() {
  local active deadline
  active=$(active_panel)
  if [ "$active" = "$PANEL" ]; then
    return 0
  fi
  noctalia msg panel-open "$PANEL" >/dev/null 2>&1 || fail "the panel could not be opened"
  deadline=$((SECONDS + 5))
  while [ "$SECONDS" -lt "$deadline" ]; do
    active=$(active_panel)
    if [ "$active" = "$PANEL" ]; then
      return 0
    fi
    sleep 0.15
  done
  fail "the panel did not become active (active: ${active:-none})"
}

# Send an event to the panel and retry if another panel stole focus just
# before: `ensure_panel` reactivates it and it is sent again.
plugin_ipc() {
  local event="$1" tries=3
  while [ "$tries" -gt 0 ]; do
    ensure_panel
    if noctalia msg plugin "$PANEL" all "$event" >/dev/null 2>&1; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 0.2
  done
  return 1
}

# The plugin parses `plugin.toml` once and keeps it in memory; the host only
# reloads the script when a `.luau` changes, not when the manifest changes.
# The installed panel's mtime is touched (without changing its content) so the
# test starts with the commands currently on disk.
INSTALLED_PANEL="$HOME/.local/share/noctalia/plugins/terminal-widgets/panel.luau"
if [ -f "$INSTALLED_PANEL" ]; then
  touch "$INSTALLED_PANEL"
  sleep 1.5
fi

echo "0) start from scratch"
plugin_ipc close-all || fail "the close-all IPC did not respond"
wait_count 0 "$CLOSE_TIMEOUT" || fail "windows were left open at startup: $(plugin_geometry)"

echo "1) open all widgets"
opened=0
for attempt in 1 2 3; do
  plugin_ipc open-all || fail "the open-all IPC did not respond"
  if wait_count "$expected" 15; then
    opened=1
    break
  fi
  echo "   attempt $attempt: $(plugin_count) of $expected windows" >&2
  sleep 2
done
if [ "$opened" -ne 1 ]; then
  echo "   open: $(plugin_geometry | tr '\n' ' ')" >&2
  fail "expected $expected windows but there are $(plugin_count)"
fi
wait_stable || fail "the windows did not finish being placed"
sleep "$SETTLE"
if [ "$(plugin_count)" -ne "$expected" ]; then
  echo "   open after ${SETTLE}s: $(plugin_geometry | tr '\n' ' ')" >&2
  fail "a widget closed itself (remaining $(plugin_count) of $expected)"
fi
echo "   open windows: $(plugin_count) ✔"

echo "2) rotate"
cat >"$tmp/check_rotation.py" <<'PY'
import sys


def load(path):
    out = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            parts = line.split()
            if len(parts) == 3:
                out[parts[0]] = (int(parts[1]), int(parts[2]))
    return out


before = load(sys.argv[1])
after = load(sys.argv[2])
if set(before) != set(after):
    print("the open windows changed on rotation", file=sys.stderr)
    sys.exit(1)
if sorted(before.values()) != sorted(after.values()):
    print("the rotation was not a permutation of positions", file=sys.stderr)
    sys.exit(1)
if before == after:
    print("no window changed position", file=sys.stderr)
    sys.exit(1)
print(
    "permutation: "
    + ", ".join(
        f"{name}: {before[name]} -> {after[name]}"
        for name in sorted(before)
        if before[name] != after[name]
    )
)
PY
ensure_panel
plugin_geometry >"$tmp/before"
plugin_ipc rotate || fail "the rotate IPC did not respond"
deadline=$((SECONDS + ROTATE_TIMEOUT))
rotated=0
while [ "$SECONDS" -lt "$deadline" ]; do
  plugin_geometry >"$tmp/after"
  if python3 "$tmp/check_rotation.py" "$tmp/before" "$tmp/after" >"$tmp/check" 2>&1; then
    rotated=1
    break
  fi
  sleep 0.3
done
if [ "$rotated" -ne 1 ]; then
  cat "$tmp/check" >&2
  echo "   before:" >&2
  sed 's/^/     /' "$tmp/before" >&2
  echo "   after:" >&2
  sed 's/^/     /' "$tmp/after" >&2
  fail "the rotation did not permute the window positions"
fi
cat "$tmp/check"

echo "3) close all"
plugin_ipc close-all || fail "the close-all IPC did not respond"
if ! wait_count 0 "$CLOSE_TIMEOUT"; then
  echo "   remaining: $(plugin_geometry | tr '\n' ' ')" >&2
  fail "$(plugin_count) windows were left open"
fi
echo "   remaining windows: 0 ✔"

echo "4) close the test panel"
ensure_panel
# Give the panel time to finish opening before closing it.
sleep 0.5
# Closing is confirmed by the host state. It is retried because another panel
# may steal focus just before, or the host may ignore a close during the
# opening animation.
deadline=$((SECONDS + 8))
while [ "$SECONDS" -lt "$deadline" ]; do
  [ "$(active_panel)" != "$PANEL" ] && break
  noctalia msg panel-close "$PANEL" >/dev/null 2>&1 || true
  sleep 0.3
done
if [ "$(active_panel)" = "$PANEL" ]; then
  fail "the panel did not close (still active)"
fi
# onClose runs on close; the flush is forced before reviewing.
if ! flush_log; then
  fail "could not force the log flush; the review would not be complete"
fi
# Capture lines that arrive late (unrelated noise or deferred flush) before
# freezing the copy.
wait_log_quiet 3 15
stop_follower
# With the copy flushed, check that the close was logged. The follower drains
# the old file before switching, so the line must be there.
# Closing must have been logged in the copy (the follower drains the old file
# before switching, so a rotation does not hide it).
if ! grep -q "closing \"$PANEL\"" "$tmp/run.log"; then
  fail "the panel did not close ('closing' does not appear in the log copy)"
fi

echo "5) new warnings and errors in the log during the whole test"
LOG_CHECKED=1
review_log || fail "the log received warnings or errors during the test"

echo "OK: the smoke test passed"
