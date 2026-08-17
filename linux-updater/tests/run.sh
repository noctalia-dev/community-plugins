#!/bin/sh
# Layer-1 parser tests: run every backend's parseCheck against the recorded
# fixtures with the `luau` CLI (pacman -S luau). The CLI has no file IO, so
# each case is assembled into one temporary chunk: fixture text as a long
# string + the backend source wrapped into a factory + assertions.
#
# Usage: tests/run.sh   (from the plugin root or anywhere)

set -u
cd "$(dirname "$0")/.." || exit 1

command -v luau >/dev/null 2>&1 || { echo "SKIP: luau CLI not installed (pacman -S luau)"; exit 0; }

pass=0
fail=0

# run_case <backend-file> <fixture-file> <assertions-luau>
run_case() {
    backend=$1
    fixture=$2
    asserts=$3
    tmp=$(mktemp --suffix=.luau)
    {
        echo "local FIXTURE = [=======["
        cat "$fixture"
        echo "]=======]"
        echo "local factory = (function()"
        cat "$backend"
        echo "end)()"
        cat << 'HARNESS'
local env = {
    trim = function(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end,
    shellQuote = function(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end,
    cfg = function(_) return nil end,
    commandExists = function(_) return false end,
    MAX_LISTED = 300,
    osRelease = "",
}
local backend = factory(env)
local function parse(ignoredNames)
    local ignored = {}
    for _, n in ipairs(ignoredNames or {}) do ignored[n] = true end
    local out = {}
    local n, items = backend.parseCheck(FIXTURE, ignored, out)
    return n, items, out
end
local function fatal(msg)
    print("FAIL: " .. msg)
    error(msg, 0)
end
local function eq(got, want, what)
    if got ~= want then
        fatal(what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end
HARNESS
        echo "$asserts"
        echo 'print("OK")'
    } > "$tmp"
    out=$(luau "$tmp" 2>&1)
    if [ "$(printf '%s' "$out" | tail -n 1)" = "OK" ]; then
        pass=$((pass + 1))
        echo "ok   $(basename "$backend" .luau) / $(basename "$fixture")"
    else
        fail=$((fail + 1))
        echo "FAIL $(basename "$backend" .luau) / $(basename "$fixture")"
        printf '%s\n' "$out" | sed 's/^/     /'
    fi
    rm -f "$tmp"
}

# ── pacman: checkupdates format, [ignored] marker, plugin-ignore routing ─────
cat > /tmp/linup-test-pacman.txt << 'EOF'
zip 3.0-13 -> 3.0-14
libical 4.0.4-1 -> 4.0.5-1
assistant 6.5-1 -> 6.5.0-3 [ignored]
EOF
run_case backends/pacman.luau /tmp/linup-test-pacman.txt '
local n, items, ign = parse({"libical"})
eq(n, 1, "pacman count")
eq(items[1].name, "zip", "pacman name")
eq(items[1].from, "3.0-13", "pacman from")
eq(items[1].to, "3.0-14", "pacman to")
eq(#ign, 2, "pacman ignored entries")
eq(ign[1].source, "plugin", "plugin ignore routed (fixture order)")
eq(ign[2].source, "system", "IgnorePkg routed as system")
'

# ── packagekit: identical format on Fedora and Ubuntu ────────────────────────
run_case backends/packagekit.luau fixtures/packagekit/fedora41-get-updates.txt '
local n, items = parse({})
eq(n, 5, "pk fedora count")
eq(items[1].name, "curl", "pk fedora name")
eq(items[1].to, "8.9.1-4.fc41", "pk fedora version")
eq(items[3].name, "openssl-libs", "pk epoch name split")
eq(items[3].to, "1:3.2.6-2.fc41", "pk epoch kept in version")
'
run_case backends/packagekit.luau fixtures/packagekit/ubuntu2404-get-updates.txt '
local n, items = parse({})
eq(n, 2, "pk ubuntu count")
eq(items[2].name, "libcurl4t64", "deb name with digits split")
eq(items[2].to, "8.5.0-2ubuntu10.11", "deb version")
'

# ── dnf: name|old|new composed by the check shell ────────────────────────────
run_case backends/dnf.luau fixtures/dnf/fedora41-backend-check.txt '
local n, items = parse({"vim-data"})
eq(n, 4, "dnf count minus ignored")
eq(items[1].name, "curl", "dnf name")
eq(items[1].from, "8.9.1-2.fc41", "dnf old version")
eq(items[3].from, "1:3.2.2-9.fc41", "dnf epoch old")
'

# ── apt: list --upgradable + ::HOLDS separator ───────────────────────────────
run_case backends/apt.luau fixtures/apt/ubuntu2404-backend-check.txt '
local n, items, ign = parse({"libudev1"})
eq(n, 3, "apt count minus ignored")
eq(items[1].name, "curl", "apt name")
eq(items[1].from, "8.5.0-2ubuntu10", "apt old")
eq(items[1].to, "8.5.0-2ubuntu10.11", "apt new")
eq(ign[1].name, "libudev1", "apt plugin-ignore routed")
'
cat > /tmp/linup-test-apt-hold.txt << 'EOF'
Listing...
curl/noble-updates 8.5.0-2ubuntu10.11 amd64 [upgradable from: 8.5.0-2ubuntu10]
::HOLDS
curl
EOF
run_case backends/apt.luau /tmp/linup-test-apt-hold.txt '
local n, items, ign = parse({})
eq(n, 0, "held package not pending")
eq(ign[1].source, "system", "apt hold routed as system")
'

# ── zypper: table rows, header and warnings skipped ──────────────────────────
run_case backends/zypper.luau fixtures/zypper/tw-list-updates.txt '
local n, items = parse({})
eq(n, 1, "zypper count")
eq(items[1].name, "openSUSE-build-key", "zypper name")
eq(items[1].from, "1.0-68.1", "zypper current")
eq(items[1].to, "1.0-69.1", "zypper available")
'

# ── xbps: pkgver split at the last dash ──────────────────────────────────────
run_case backends/xbps.luau fixtures/xbps/void-check.txt '
local n, items = parse({})
eq(n, 1, "xbps count")
eq(items[1].name, "libarchive", "xbps name")
eq(items[1].to, "3.8.9_1", "xbps version")
'

# ── fail-closed ignores: the upgrade must be gated (&&) on refresh/hold/lock
# setup, never chained with ";" — a failed hold must stop the upgrade ────────
check_gated() {
    file=$1
    what=$2
    run_case "$file" /dev/null "
local cmd = backend.buildBackgroundCommand({\"pkga\", \"pkgb\"})
local upgradeAt = cmd:find(\"$what\", 1, true) or fatal(\"$what missing from bg command\")
local prefix = cmd:sub(1, upgradeAt - 1)
if prefix:find(\";\", 1, true) ~= nil then
    fatal(\"$(basename "$file" .luau): hold/refresh chained with ; before the upgrade (fail-open)\")
end
if prefix:find(\"&&\", 1, true) == nil then
    fatal(\"$(basename "$file" .luau): upgrade not gated on the ignore setup\")
end
"
}
check_gated backends/apt.luau "apt-get -y"
check_gated backends/zypper.luau " up"
check_gated backends/xbps.luau "xbps-install -Suy"

echo "----"
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
