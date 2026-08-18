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

# ── extra sources: one parser per manager, factory returns the whole array ──
run_extra() {
    fixture=$1
    key=$2
    asserts=$3
    run_case extras.luau "$fixture" "
local byKey = {}
for _, e in ipairs(backend) do byKey[e.key] = e end
local extra = byKey[\"$key\"] or fatal(\"extra $key missing\")
local ign = {}
local n, items = extra.parseCheck(FIXTURE, {}, ign)
$asserts"
}
run_extra fixtures/extras/npm-outdated-parseable.txt npm '
eq(n, 4, "npm count")
eq(items[1].name, "corepack", "npm name")
eq(items[1].from, "0.34.6", "npm current")
eq(items[1].to, "0.35.0", "npm wanted")
eq(items[3].name, "semver", "npm plain package")
eq(items[4].name, "@angular/cli", "npm scoped name keeps its prefix")
eq(items[4].from, "18.2.8", "npm scoped current")
eq(extra.buildRollbackCommand(items[3]), "npm -g install '\''semver@7.5.0'\''", "npm rollback reinstalls the old version")
eq(extra.buildRollbackCommand(items[4]), "npm -g install '\''@angular/cli@18.2.8'\''", "npm scoped rollback")
eq(extra.buildRollbackCommand({ name = "x", from = "" }), nil, "npm rollback needs a recorded old version")
local ign2 = {}
local n2 = extra.parseCheck(FIXTURE, { ["@angular/cli"] = true }, ign2)
eq(n2, 3, "scoped ignore drops from the count")
eq(ign2[1].name, "@angular/cli", "scoped ignore routed to the ignored section")
'
run_extra fixtures/extras/cargo-install-update-list.txt cargo '
eq(n, 1, "cargo count (No rows, header and registry-poll line skipped)")
eq(items[1].name, "ripgrep", "cargo name")
eq(items[1].from, "14.0.3", "cargo installed, v stripped")
eq(items[1].to, "15.2.0", "cargo latest")
eq(extra.buildRollbackCommand(items[1]), "cargo install --force --version '\''14.0.3'\'' '\''ripgrep'\''", "cargo rollback pins the version")
'
run_extra fixtures/extras/pip-list-outdated.txt pip '
eq(n, 2, "pip count (both header lines skipped)")
eq(items[2].name, "requests", "pip name")
eq(items[2].from, "2.31.0", "pip installed")
eq(items[2].to, "2.34.2", "pip latest")
eq(extra.buildUpdateCommand, nil, "pip stays check-only")
eq(extra.rollbackKind, nil, "pip has no rollback")
'
run_extra fixtures/extras/gem-outdated.txt gem '
eq(n, 3, "gem count")
eq(items[2].name, "rake", "gem name")
eq(items[2].from, "13.1.0", "gem installed (highest of the side-by-side versions)")
eq(items[2].to, "13.4.2", "gem latest")
eq(items[3].from, "6.6.3.1", "gem four-part version")
eq(
    extra.buildRollbackCommand(items[2]),
    "gem uninstall -x -I '\''rake'\'' -v '\''13.4.2'\'' >/dev/null 2>&1; gem install '\''rake'\'' -v '\''13.1.0'\''",
    "gem rollback removes the new version, then ensures the old one"
)
'
run_extra fixtures/extras/snap-refresh-list.txt snap '
eq(n, 2, "snap count (header skipped)")
eq(items[2].name, "firefox", "snap name")
eq(items[2].from, "", "snap has no old version")
eq(items[2].to, "130.0.1-1", "snap new version")
eq(extra.rollbackKind, "revert", "snap rollback is a revert")
eq(extra.buildRollbackCommand(items[2]), "snap revert '\''firefox'\''", "snap revert needs no version")
'
run_extra fixtures/extras/brew-outdated-quiet.txt brew '
eq(n, 2, "brew count")
eq(items[1].name, "wget", "brew name")
eq(items[1].to, "", "brew reports names only")
eq(extra.rollbackKind, nil, "brew has no rollback")
'

# ── packagekit: ignore honored via an explicit pending-minus-ignored list ────
run_case backends/packagekit.luau /dev/null '
eq(backend.buildBackgroundCommand({}, nil), "pkcon -y --plain refresh && pkcon -y --plain update", "pk no filter = update all")
eq(
    backend.buildBackgroundCommand({"x"}, {"'\''curl'\''", "'\''vim'\''"}),
    "pkcon -y --plain refresh && pkcon -y --plain update '\''curl'\'' '\''vim'\''",
    "pk explicit names"
)
eq(backend.buildBackgroundCommand({"x"}, {}), "pkcon -y --plain refresh", "pk everything ignored = refresh only")
eq(backend.ignoreByExplicitList, true, "pk asks the engine for the pending list")
'

# ── apt: opportunistic cache rollback pieces ─────────────────────────────────
run_case backends/apt.luau /dev/null '
eq(backend.caps.rollback, "cache", "apt rollback is cache-kind")
if backend.findPkgSh:find("%3a", 1, true) == nil then fatal("apt findPkgSh must encode the epoch colon as %3a") end
if backend.rollbackInstall:find("--allow-downgrades", 1, true) == nil then fatal("apt rollback install needs --allow-downgrades") end
if backend.depsListCommand("curl"):find("--recurse --installed", 1, true) == nil then fatal("apt deps list must be recursive and installed-only") end
'

# ── dnf: per-item downgrade with reasoned failure ────────────────────────────
run_case backends/dnf.luau /dev/null '
eq(
    backend.rollbackItemCommand({ name = "openssl-libs", from = "1:3.2.2-9.fc41" }),
    "pkexec dnf -y downgrade '\''openssl-libs-1:3.2.2-9.fc41'\''",
    "dnf downgrade pins the exact recorded version, epoch included"
)
eq(backend.rollbackItemCommand({ name = "curl", from = "" }), nil, "dnf item rollback needs a recorded version")
if backend.itemProbeSh:find("repoquery", 1, true) == nil or backend.itemProbeSh:find("%-C", 1) == nil then
    fatal("dnf probe must be a cache-only repoquery")
end
eq(backend.rollbackFailHintKey, "err_dnf_rollback_unavailable", "dnf failure names its cause")
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
