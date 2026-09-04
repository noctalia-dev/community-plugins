--!nonstrict
-- topgrade-wrapper — singleton engine: counts pending updates and starts runs.
--
-- Runs once regardless of how many bars show the widget. The widget and the
-- panel are pure renderers wired through the plugin's shared state:
--   engine publishes  "topgrade_state"   = { nonce, phase, step, total, counts,
--                                            uncounted, dismissed, err,
--                                            checkedAt, configPath, excluded }
--   UI entries send   "topgrade_request" = { nonce, action }  -- check|update|dismiss
--
-- Counting is two-staged, because topgrade has no "how many packages?" mode of
-- its own. First `topgrade --dry-run` reports the steps it would actually run,
-- so the user's own topgrade.toml (plus this plugin's --disable overrides)
-- decides what is counted; every "Dry running: <cmd>" line it prints is then
-- matched against the COUNTERS table to learn which package managers are in
-- play. Each matched manager gets one read-only query listing what it has
-- pending, run one at a time so a slow mirror never stalls the others'
-- timeouts. Steps with no counter are reported by name instead of being folded
-- into the total: a wrong number is worse than an honest "not counted".
--
-- The queries list packages rather than count them, so a `counts` entry carries
-- both `n` and the `items` behind it ({ name, from, to }) and the panel can
-- expand a row into them without asking a mirror twice.
--
-- Upgrades never run in the background. runUpdate() opens a terminal window so
-- package managers can prompt and sudo can ask for the password on the tty.
-- While one runs, processMatches() polls for the topgrade process and re-counts
-- as soon as it is gone, so the bar clears itself.
--
-- Since 0.0.9 the topgrade command line is an argument vector (buildArgv,
-- plugin_api >= 24) and the dry-run check execs it directly, so no shell parses
-- the configured config path on the automated path. The two lines that still
-- need a shell keep one: the upgrade, because runInTerminal takes a string, and
-- each per-manager counter, because those are genuine pipelines.

local shared = require("./shared.luau")

local UPDATES_SOUND = "topgrade-updates-found" -- name registered with noctalia.sound.load
local soundReady = false -- true once UPDATES_SOUND has finished loading

local DRY_TIMEOUT_MS = 45000 -- topgrade --dry-run: PATH probes, no network
local COUNT_TIMEOUT_MS = 60000 -- per manager; several of these hit the network
local RUN_POLL_SECONDS = 3 -- how often a running topgrade is polled for
local RUN_GRACE_SECONDS = 20 -- how long to wait for the process to show up
local AUTO_CHECK_DELAY = 10 -- ticks before the startup check, when enabled
-- Packages per manager kept for the panel's expandable list. Every entry is
-- republished on each state update, so this bounds a pathological case (hundreds
-- of outdated site-packages) without touching the reported count.
local MAX_LISTED = 200

-- One entry per package manager we can ask what it has pending.
--   signals  — Lua patterns matched against the "Dry running:" commands of a
--              step; any match means this manager is part of the run.
--   requires — binary that must exist for the query to work.
--   cmd      — read-only query printing ONE PACKAGE PER LINE as
--              `name<TAB>installed<TAB>available`. Either version may be empty
--              when the tool does not report it.
--
-- Every query — and the dry run itself — is spawned with `export LC_ALL=C;` in
-- front of it: these parsers key off English words and fixed column layouts
-- (`^Inst `, the zypper table, the pip header), which a translated system turns
-- into gibberish. Reported upstream from a French desktop (community-plugins
-- #204). The interactive run is deliberately left in the user's own locale.
--
-- The count is simply how many lines came back, so the number on the bar and the
-- list the panel expands are the same answer to the same question, asked once:
-- no second round trip to a mirror, and no way for the two to disagree.
--
-- Homebrew and npm give names only: `brew outdated --quiet` and
-- `npm -g outdated --parseable` do not carry a usable pair.
--
-- `pip` deliberately matches only the pip-review / pipupgrade steps: topgrade's
-- own `pip3` step upgrades pip itself, and counting every outdated site-package
-- against it would badly overstate the run.
local COUNTERS = {
    {
        key = "pacman",
        requires = "checkupdates",
        -- An AUR helper counts too: it upgrades the repositories as well as the
        -- AUR, and it does not always name pacman on its command line (yay is
        -- invoked as `yay --pacman pacman -Syu`, paru plainly as `paru -Syu`).
        -- Matching only "pacman" would leave repository updates uncounted on a
        -- paru system, so every helper that carries -Syu fires this counter and
        -- the AUR-only counters below add their own share on top.
        signals = { "pacman[^\n]*%-Sy+u", "yay[^\n]*%-Sy+u", "paru[^\n]*%-Sy+u" },
        cmd = [[checkupdates 2>/dev/null | awk '{print $1"\t"$2"\t"$4}']],
    },
    {
        key = "aur_yay",
        requires = "yay",
        signals = { "yay[^\n]*%-Sy+u" },
        cmd = [[yay -Qua 2>/dev/null | awk '{print $1"\t"$2"\t"$4}']],
    },
    {
        key = "aur_paru",
        requires = "paru",
        signals = { "paru[^\n]*%-Sy+u" },
        cmd = [[paru -Qua 2>/dev/null | awk '{print $1"\t"$2"\t"$4}']],
    },
    {
        key = "apt",
        requires = "apt-get",
        signals = { "apt%-get[^\n]*upgrade", "apt[^\n]*full%-upgrade", "apt[^\n]*dist%-upgrade", "nala[^\n]*upgrade" },
        cmd = [[apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | awk '/^Inst /{gsub(/[][]/,"",$3); gsub(/[()]/,"",$4); print $2"\t"$3"\t"$4}']],
    },
    {
        key = "dnf",
        requires = "dnf",
        signals = { "dnf[^\n]*upgrade" },
        cmd = [[dnf -q check-update 2>/dev/null | awk 'NF==3{print $1"\t\t"$2}']],
    },
    {
        key = "zypper",
        requires = "zypper",
        signals = { "zypper" },
        cmd = [[zypper --quiet --non-interactive list-updates 2>/dev/null | awk -F'|' '/^v/{gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$4); gsub(/^ +| +$/,"",$5); print $3"\t"$4"\t"$5}']],
    },
    {
        key = "flatpak",
        requires = "flatpak",
        signals = { "flatpak[^\n]*update" },
        -- Two queries joined in one pass: `list` for what is installed (whose
        -- commit column is `active`, not `commit`) and `remote-ls --updates` for
        -- what is pending. Flatpak tracks commits, so an app's version string
        -- often does not move across an update — verified: floorp goes 12.16.3 →
        -- 12.16.3 — and an arrow between two equal versions would claim a change
        -- the numbers deny. So the version pair is used when it really differs
        -- and short commits stand in when it does not. The tag is a letter and a
        -- space rather than a tab: POSIX sed has no \t in a replacement.
        cmd = [[
{ flatpak list --columns=application,version,active 2>/dev/null | sed 's/^/L /'
  flatpak remote-ls --updates --columns=application,version,commit 2>/dev/null | sed 's/^/R /'
} | awk -F'\t' '
{ tag=substr($1,1,1); app=substr($1,3) }
tag=="L" { v[app]=$2; c[app]=$3 }
tag=="R" { from=v[app]; to=$2
           if (from=="" || to=="" || from==to) { from=substr(c[app],1,7); to=substr($3,1,7) }
           print app"\t"from"\t"to }'
]],
    },
    {
        key = "snap",
        requires = "snap",
        signals = { "snap[^\n]*refresh" },
        cmd = [[snap refresh --list 2>/dev/null | tail -n +2 | awk '{print $1"\t\t"$2}']],
    },
    {
        key = "brew",
        requires = "brew",
        signals = { "brew[^\n]*upgrade" },
        cmd = "brew outdated --quiet 2>/dev/null",
    },
    {
        key = "cargo",
        -- The cargo-update subcommand, not cargo itself: without it the query
        -- would answer 0 and read as "up to date".
        requires = "cargo-install-update",
        signals = { "install%-update" },
        cmd = [[cargo install-update --list 2>/dev/null | awk '$NF=="Yes"{print $1"\t"$2"\t"$3}']],
    },
    {
        key = "npm",
        requires = "npm",
        signals = { "npm[^\n]*update", "npm[^\n]*upgrade" },
        cmd = "npm -g outdated --parseable 2>/dev/null | awk -F: '{print $2}'",
    },
    {
        key = "gem",
        requires = "gem",
        signals = { "gem[^\n]*update" },
        cmd = [[gem outdated 2>/dev/null | awk '{gsub(/[()]/,"",$2); gsub(/[()]/,"",$4); print $1"\t"$2"\t"$4}']],
    },
    {
        key = "pip",
        requires = "pip",
        signals = { "pip%-review", "pipupgrade" },
        -- --format=freeze is rejected outright with --outdated; the default
        -- table carries the installed and latest versions side by side, past a
        -- two-line header.
        cmd = [[pip list --outdated 2>/dev/null | awk 'NR>2{print $1"\t"$2"\t"$3}']],
    },
}

-- Where topgrade looks for its configuration, in its own order of preference.
-- Detected for display only: with no override the plugin passes no --config at
-- all and lets topgrade resolve the file itself.
local CONFIG_CANDIDATES = {
    "$XDG_CONFIG_HOME/topgrade.toml",
    "$XDG_CONFIG_HOME/topgrade/topgrade.toml",
    "~/.config/topgrade.toml",
    "~/.config/topgrade/topgrade.toml",
}

local phase = "idle" -- idle|checking|clean|ready|running|error|missing
local step = "" -- manager being counted (phase == "checking")
local counts = {} -- array of { key, n, items }, every manager actually queried
local uncounted = {} -- step names topgrade would run that we cannot count
local total = 0
local dismissed = false -- "Dismiss" pressed; counts kept, bar goes quiet
local errMsg = nil
local checkedAt = ""
local stateNonce = 0
local lastRequestNonce = 0

local queue = {} -- counters still to run this check
local planTotal = 0 -- counters this check started with, for the progress bar
local runTicks = 0 -- seconds since the terminal was launched
local runSeen = false -- the topgrade process was observed at least once
local runPollTicks = 0
local sinceCheck = 0 -- seconds since the last completed check
local startupTicks = 0
local commandSig = nil -- signature of the settings that shape the command line

local startCheck

local function cfg(key)
    return noctalia.getConfig(key)
end

local function tr(key, args)
    return shared.tr(key, args)
end

local function trim(value)
    return noctalia.string.trim(value or "")
end

local function shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

-- Which exclusions apply, per the exclude_mode setting: either topgrade's own
-- configuration alone ("config" — the plugin adds nothing to the command line),
-- or that plus the plugin's own list ("override").
--
-- Step ids reach the command line, so accept only topgrade's own id shape
-- (lowercase, digits, underscore). Anything else is dropped with a log line
-- rather than quoted, so a typo can never smuggle in shell syntax.
local function excludedSteps()
    if cfg("exclude_mode") ~= "override" then
        return {}
    end
    local raw = cfg("exclude_steps")
    if type(raw) ~= "table" then
        return {}
    end
    local steps = {}
    for _, entry in ipairs(raw) do
        local id = trim(tostring(entry)):lower()
        if id:match("^[a-z0-9_]+$") ~= nil then
            table.insert(steps, id)
        elseif id ~= "" then
            noctalia.log("topgrade-wrapper: ignoring invalid step id '" .. id .. "'")
        end
    end
    return steps
end

local function configOverride()
    local path = trim(cfg("topgrade_config"))
    if path == "" then
        return nil
    end
    return noctalia.expandPath(path)
end

-- The topgrade config actually in force: the override when set, else the first
-- candidate that exists. nil when topgrade is running on its defaults.
local function detectedConfig()
    local override = configOverride()
    if override ~= nil then
        return override
    end
    local xdg = noctalia.getenv("XDG_CONFIG_HOME")
    for _, candidate in ipairs(CONFIG_CANDIDATES) do
        local path = candidate
        if path:find("$XDG_CONFIG_HOME", 1, true) ~= nil then
            if xdg == nil or xdg == "" then
                continue
            end
            path = path:gsub("%$XDG_CONFIG_HOME", (xdg:gsub("%%", "%%%%")))
        end
        path = noctalia.expandPath(path)
        if noctalia.fileExists(path) then
            return path
        end
    end
    return nil
end

-- Settings that change what topgrade would do; a check result is stale once
-- any of them moves, so onConfigChanged can tell a real change from a cosmetic
-- one (a glyph edit must not throw away a fresh count).
local function commandSignature()
    return tostring(configOverride()) .. "\0" .. table.concat(excludedSteps(), ",")
end

-- The topgrade command line as an argument vector — the one source of truth for
-- both callers. The dry-run check execs it directly (plugin_api >= 24), so
-- nothing parses the configured config path; the upgrade needs a shell string,
-- which buildCommand below quotes out of this same vector rather than building
-- its own and risking the two drifting apart.
local function buildArgv(dry)
    local argv = { "topgrade" }
    local override = configOverride()
    if override ~= nil then
        table.insert(argv, "--config")
        table.insert(argv, override)
    end
    -- One flag per step: repeating --disable keeps clap from swallowing the
    -- flags that follow, which a space-separated list would.
    for _, id in ipairs(excludedSteps()) do
        table.insert(argv, "--disable")
        table.insert(argv, id)
    end
    if dry then
        -- --no-self-update keeps the count from doing a release check it would
        -- never act on in dry mode.
        table.insert(argv, "--dry-run")
        table.insert(argv, "--no-self-update")
    else
        if cfg("assume_yes") == true then
            table.insert(argv, "--yes")
        end
        if cfg("sudo_loop") == true then
            table.insert(argv, "--sudoloop")
        end
        if cfg("keep_terminal_open") == true then
            table.insert(argv, "--keep")
        end
    end
    return argv
end

-- The same command as one shell line, for the upgrade: runInTerminal and the
-- `<term> -e sh -lc` form are both string-only, so that path cannot leave the
-- shell behind. Every element is quoted, config path included.
local function buildCommand(dry)
    local parts = {}
    for index, value in ipairs(buildArgv(dry)) do
        parts[index] = shellQuote(value)
    end
    return table.concat(parts, " ")
end

local function publish()
    stateNonce += 1
    local config = detectedConfig()
    noctalia.state.set(shared.STATE_KEY, {
        nonce = stateNonce,
        phase = phase,
        step = step,
        progress = planTotal > 0 and (planTotal - #queue) / planTotal or 0,
        total = total,
        counts = counts,
        uncounted = uncounted,
        dismissed = dismissed,
        err = errMsg,
        checkedAt = checkedAt,
        configPath = config,
        excluded = #excludedSteps(),
    })
end

-- ── Counting ────────────────────────────────────────────────────────────────

-- `topgrade --dry-run` prints one header per step it would run,
--   ―― HH:MM:SS - <Step name> ――
-- followed by its "Dry running: <cmd>" lines (a step can have none). The
-- trailing "Summary" header repeats the names with their outcome, so parsing
-- stops there. The header is matched loosely — timestamp, " - ", name, bar —
-- so a cosmetic change to topgrade's rule characters cannot break the parse.
local function parseDryRun(stdout)
    local steps = {}
    local current = nil
    for line in stdout:gmatch("[^\n]+") do
        local cmd = line:match("^Dry running:%s*(.+)$")
        if cmd ~= nil then
            if current == nil then
                current = { name = tr("step_unnamed"), cmds = {} }
                table.insert(steps, current)
            end
            table.insert(current.cmds, cmd)
        else
            local name = line:match("%d%d:%d%d:%d%d%s*%-%s*(.-)%s*\u{2015}")
            if name ~= nil then
                if name == "Summary" then
                    break
                end
                current = { name = name, cmds = {} }
                table.insert(steps, current)
            end
        end
    end
    return steps
end

local function signalsMatch(counter, blob)
    for _, pattern in ipairs(counter.signals) do
        if blob:find(pattern) ~= nil then
            return true
        end
    end
    return false
end

-- Turns parsed steps into the ordered list of counters to run, plus everything
-- that will be missing from the total. A manager shared by several steps —
-- Flatpak's user and system steps, say — is queried once.
--
-- What gets reported as not counted depends on how much of a step is covered:
--   * nothing answered   → the step's own name, which means more to the reader
--                          than the name of a tool they do not have;
--   * partly answered    → the managers that could not answer. Without this an
--                          Arch box with an AUR helper but no pacman-contrib
--                          would show the AUR total as if it were the whole
--                          system update, with nothing to hint at the gap.
local function planCounters(steps)
    local plan = {}
    local seen = {} -- counter keys already queued
    local absent = {} -- counter keys already reported as unavailable
    local skipped = {}
    for _, entry in ipairs(steps) do
        local blob = table.concat(entry.cmds, "\n")
        local matched = false
        local unavailable = {}
        for _, counter in ipairs(COUNTERS) do
            if signalsMatch(counter, blob) then
                if seen[counter.key] then
                    matched = true
                elseif noctalia.commandExists(counter.requires) then
                    seen[counter.key] = true
                    table.insert(plan, counter)
                    matched = true
                else
                    table.insert(unavailable, counter)
                end
            end
        end
        if not matched then
            table.insert(skipped, entry.name)
        else
            for _, counter in ipairs(unavailable) do
                if not absent[counter.key] then
                    absent[counter.key] = true
                    table.insert(skipped, tr("count." .. counter.key))
                end
            end
        end
    end
    return plan, skipped
end

local function finishCheck()
    total = 0
    for _, entry in ipairs(counts) do
        total += entry.n
    end
    step = ""
    phase = total > 0 and "ready" or "clean"
    dismissed = false
    checkedAt = noctalia.formatTime("%H:%M")
    sinceCheck = 0
    publish()
    if total > 0 and cfg("notify_on_updates") == true then
        noctalia.notify(tr("title"), noctalia.trp("notify_updates", total, { count = total }))
    end
    if total > 0 and soundReady and cfg("sound_on_updates") == true then
        noctalia.sound.play(UPDATES_SOUND)
    end
end

local function failCheck(message)
    queue = {}
    step = ""
    phase = "error"
    errMsg = message
    publish()
end

local pumpQueue
pumpQueue = function()
    if #queue == 0 then
        finishCheck()
        return
    end
    local counter = table.remove(queue, 1)
    step = tr("count." .. counter.key)
    publish()
    local started = noctalia.runAsync("export LC_ALL=C; " .. counter.cmd, function(result)
        -- A query that timed out or reported an error is recorded as unknown
        -- rather than zero: saying "up to date" because a mirror was down would
        -- be a lie. Note that most of these commands end in a filter, so their
        -- exit status is the filter's — this catches the queries that speak for
        -- themselves (flatpak, brew), not every possible failure.
        if result.timedOut or result.exitCode ~= 0 then
            table.insert(uncounted, tr("count." .. counter.key))
            pumpQueue()
            return
        end
        -- One package per line, tab-separated. The full count is kept even when
        -- the stored list is capped, so the total never quietly shrinks to what
        -- the panel can show.
        local items = {}
        local n = 0
        for line in (result.stdout or ""):gmatch("[^\n]+") do
            -- Trailing empty fields matter (a tool that reports no versions
            -- yields "name\t\t"), so append a separator and take every field.
            local fields = {}
            for field in (line .. "\t"):gmatch("([^\t]*)\t") do
                table.insert(fields, trim(field))
            end
            local name = fields[1] or ""
            if name ~= "" then
                n += 1
                if #items < MAX_LISTED then
                    table.insert(items, { name = name, from = fields[2] or "", to = fields[3] or "" })
                end
            end
        end
        table.insert(counts, { key = counter.key, n = n, items = items })
        pumpQueue()
    end, COUNT_TIMEOUT_MS)
    if not started then
        table.insert(uncounted, tr("count." .. counter.key))
        pumpQueue()
    end
end

startCheck = function()
    if phase == "checking" then
        return
    end
    if not noctalia.commandExists("topgrade") then
        phase = "missing"
        errMsg = tr("err_no_topgrade")
        publish()
        return
    end

    phase = "checking"
    errMsg = nil
    counts = {}
    uncounted = {}
    queue = {}
    planTotal = 0
    total = 0
    step = tr("step_planning")
    publish()

    -- LC_ALL=C through `env`: parseDryRun matches topgrade's own English step
    -- headings, and with no shell in the picture `env` is the only way left to
    -- fix the locale.
    local dryArgv = { "env", "LC_ALL=C" }
    for _, value in ipairs(buildArgv(true)) do
        table.insert(dryArgv, value)
    end

    local started = noctalia.runAsync(dryArgv, function(result)
        if result.timedOut then
            failCheck(tr("err_dry_timeout"))
            return
        end
        -- A bad --disable id is the likely cause here, and topgrade names it on
        -- stderr; surfacing its first line beats a generic failure.
        if result.exitCode ~= 0 then
            local detail = trim((result.stderr or ""):match("[^\n]+") or "")
            failCheck(detail ~= "" and detail or tr("err_dry_failed"))
            return
        end
        local plan, skipped = planCounters(parseDryRun(result.stdout or ""))
        uncounted = skipped
        queue = plan
        planTotal = #plan
        if #queue == 0 then
            finishCheck()
            return
        end
        pumpQueue()
    end, DRY_TIMEOUT_MS)

    if not started then
        failCheck(tr("err_spawn"))
    end
end

-- ── Running ─────────────────────────────────────────────────────────────────

-- Noctalia's own terminal discovery ($TERMINAL, then the usual emulators) is
-- used unless a terminal is configured. A configured one is wired up the same
-- way the host does it: `<term> -e sh -lc <cmd>`, with the separator the few
-- GTK terminals need instead of -e.
local function launchTerminal(cmd)
    local term = trim(cfg("terminal"))
    if term == "" then
        return noctalia.runInTerminal(cmd)
    end
    local first = term:match("^%S+") or term
    local bin = first:match("([^/]+)$") or first
    local separator = (bin == "gnome-terminal" or bin == "kgx" or bin == "ptyxis") and "--" or "-e"
    return noctalia.runAsync(term .. " " .. separator .. " sh -lc " .. shellQuote(cmd))
end

local function runUpdate()
    if phase == "running" or phase == "checking" then
        return
    end
    if not noctalia.commandExists("topgrade") then
        phase = "missing"
        errMsg = tr("err_no_topgrade")
        publish()
        return
    end
    if not launchTerminal(buildCommand(false)) then
        phase = "error"
        errMsg = tr("err_no_terminal")
        publish()
        noctalia.notifyError(tr("title"), tr("err_no_terminal"))
        return
    end
    phase = "running"
    errMsg = nil
    step = ""
    runTicks = 0
    runPollTicks = 0
    runSeen = false
    publish()
end

-- Polls for the topgrade process while a run is in flight. Seeing it and then
-- losing it means the run ended, which is the cue to re-count. Never seeing it
-- within the grace period means the terminal died on startup (or the run was
-- over instantly), so re-count anyway rather than sit in "running" forever.
local function pollRun()
    runPollTicks += 1
    if runPollTicks < RUN_POLL_SECONDS then
        return
    end
    runPollTicks = 0
    noctalia.processMatches(function(matched)
        if phase ~= "running" then
            return
        end
        if matched then
            runSeen = true
            return
        end
        if runSeen or runTicks >= RUN_GRACE_SECONDS then
            startCheck()
        end
    end, "topgrade")
end

-- ── Requests, lifecycle ─────────────────────────────────────────────────────

local function handle(action)
    if action == "check" then
        -- Counting halfway through an upgrade would publish a number that is
        -- already wrong; the run's own completion poll re-checks anyway.
        if phase ~= "running" then
            startCheck()
        end
    elseif action == "update" then
        runUpdate()
    elseif action == "dismiss" then
        if not dismissed then
            dismissed = true
            publish()
        end
    end
end

noctalia.state.watch(shared.REQUEST_KEY, function(value)
    if type(value) ~= "table" then
        return
    end
    local nonce = tonumber(value.nonce) or 0
    if nonce <= lastRequestNonce then
        return
    end
    lastRequestNonce = nonce
    handle(value.action)
end)

-- Scriptable control:
--   noctalia msg plugin nightwatch75/topgrade-wrapper:service all check
--   noctalia msg plugin nightwatch75/topgrade-wrapper:service all update
function onIpc(event, _payload)
    handle(event)
end

function onConfigChanged()
    local sig = commandSignature()
    if sig ~= commandSig then
        commandSig = sig
        -- The count described a different topgrade invocation; drop it instead
        -- of showing a number the new settings would not produce.
        if phase == "ready" or phase == "clean" or phase == "error" then
            phase = "idle"
            counts = {}
            uncounted = {}
            total = 0
            checkedAt = ""
            errMsg = nil
        end
    end
    publish()
end

-- plugin_api >= 17. A hot reload (editing this file) tears this VM down and a
-- fresh one starts moments later, which republishes its own state on load —
-- nothing to do for "reload". On disable/uninstall/shutdown mid-check/run,
-- though, nothing ever republishes again: without this, every widget/panel
-- instance reading the shared state would stay frozen on "checking"/"running"
-- forever. This cannot (and does not try to) kill the underlying topgrade or
-- query process — runAsync hands back no killable handle — it only stops
-- describing it as in progress.
function onExit(_signal, reason)
    if reason == "reload" then
        return
    end
    if phase == "checking" or phase == "running" then
        phase = "idle"
        step = ""
        publish()
    end
end

function update()
    if phase == "running" then
        runTicks += 1
        pollRun()
        return
    end
    if phase == "checking" then
        return
    end

    local hours = tonumber(cfg("auto_check_hours")) or 0
    if hours <= 0 then
        return
    end
    if phase == "idle" then
        -- Staggered so enabling the setting does not fire a check into a
        -- still-starting session.
        startupTicks += 1
        if startupTicks >= AUTO_CHECK_DELAY then
            startCheck()
        end
        return
    end
    sinceCheck += 1
    if sinceCheck >= hours * 3600 then
        startCheck()
    end
end

noctalia.sound.load(UPDATES_SOUND, "sounds/updates-found.wav", function(ok)
    soundReady = ok == true
end)

noctalia.setUpdateInterval(1000)
commandSig = commandSignature()
if not noctalia.commandExists("topgrade") then
    phase = "missing"
    errMsg = tr("err_no_topgrade")
end
publish()
