--!nonstrict
-- linux-updater singleton engine. Checks pacman, the AUR helper and Flatpak,
-- publishes the result as shared state, and runs the update in the
-- BACKGROUND: one click, pkexec (polkit) asks for the password, the run is
-- fully non-interactive (--noconfirm and friends) and its log streams into
-- the panel.
--
--   state    "linup_state"   = { nonce, phase, step, total, pacman, aur,
--                                flatpak, extras, downloadSizeMiB, rebootRecommended,
--                                newsUnread, newsLatestTitle, err, checkedAt,
--                                ignoredCount, ignoredPending, ignoredDynamic,
--                                ignoredConfig, history, activity, lastUpdateAt,
--                                logTail, logPath, runExit,
--                                progress = { done, total } }
--   requests "linup_request" = { nonce, action, pkg }
--                              -- check|update|update_background|update_terminal
--                              -- |dismiss|open_news
--                              -- |ignore|unignore (pkg = package name)
--
-- "update" follows the update_mode setting: "background" (default) runs
-- non-interactively as described above; "terminal" opens a terminal window
-- where prompts (and the PKGBUILD review on Arch) work as usual. Both write
-- to the same log, so the panel's live tail, the progress bar and the
-- history strip work in either mode.
--
-- The update run is spawned fully detached (double-fork + setsid), writing to
-- <plugin data dir>/update.log; it survives a shell restart. The engine polls
-- the log every RUN_POLL_SECONDS with `tail` and finishes when the runner's
-- "::EXIT <code>" marker appears. If a background run cannot proceed
-- non-interactively it exits non-zero without touching the system, and the
-- panel offers a terminal retry ("update_terminal") where prompts work
-- normally.

local STATE_KEY = "linup_state"
local REQUEST_KEY = "linup_request"
local NEWS_FILE = "news_state.json"
local IGNORE_FILE = "ignore.json"
local RUNS_FILE = "runs.json"
local RUN_META_FILE = "run_meta.json"
local ACTIVITY_FILE = "activity_state.json" -- pending-count trend per check, for the panel's graph
local MAX_RUNS = 15 -- update runs kept for the history strip / rollback
local MAX_RUN_PACKAGES = 100 -- per-run package list cap (storage and state)
local LOG_FILE = "update.log"

local CHECK_TIMEOUT_MS = 45000 -- pacman/AUR/flatpak checks: each may sync a mirror
local SIZE_TIMEOUT_MS = 20000 -- pacman -Si: local db, no mirror sync
local FAST_TIMEOUT_MS = 5000 -- log tail / reboot check: local filesystem only
local NEWS_RECHECK_HOURS = 6
local RUN_POLL_SECONDS = 2
local RUN_STALE_LIMIT_S = 1800 -- no log growth for this long = the background run is stuck
local RUN_RESUME_MAX_AGE_S = 6 * 3600 -- older unfinished logs are not resumed
local AUTO_CHECK_DELAY = 10 -- ticks before an enabled auto-check's first run
local MAX_LISTED = 300 -- packages kept per source for the panel's expandable list

local phase = "idle" -- idle|checking|clean|ready|running|error|missing
local step = "" -- source label being checked (phase == "checking")
local total = 0
local sources = { pacman = { n = 0, items = {} }, aur = { n = 0, items = {}, helper = "" }, flatpak = { n = 0, items = {} } }
local downloadSizeMiB = nil
local rebootRecommended = false
local newsUnread = 0
local newsLatestTitle = nil
local newsItems = {}
local newsLastSeenGuid = nil
local errMsg = nil
local checkedAt = ""
local stateNonce = 0
local lastRequestNonce = 0

local runPollTicks = 0
local runExit = nil -- exit code of the last background run, nil while unknown
local runDone = 0 -- progress: package lines seen in the log so far
local runTotal = 0 -- progress: pending count when the run started
local runStaleS = 0 -- seconds without log growth during a run
local logTail = {} -- last log lines for the panel
local lastTailText = ""
local sinceCheck = 0
local startupTicks = 0
local resumeProbed = false -- resumeRunIfActive's log probe has answered
local sinceNewsCheck = 0
local newsStateLoaded = false
local newsDirty = false
local ignoredPending = {} -- ignored packages that had a pending update in the last check
local dynamicIgnore = nil -- panel-managed ignore list, persisted in IGNORE_FILE
local polkitRuleInstalled = nil -- nil until the async check ran, then boolean
local polkitInstallBusy = false
local selfCheckState = nil -- failing backend self-checks, for the panel's hint rows
local runsHistory = nil -- lazy-loaded array of {at, rollback, packages}, newest last
local activityHistory = {} -- activity graph: { n, at, afterUpdate } per check, oldest first
local activityLastUpdateAt = nil -- os.time() of the last update run that finished
local activityLoaded = false
local checkIsPostUpdate = false -- next finished check followed an update run
local runKind = "update" -- update|rollback: what the current run does
local runMode = "background" -- background|terminal: how the current run was launched
local runFailHintKey = nil -- backend-specific "why it failed" key for the current rollback
local runPackages = nil -- packages of the current run, for the history entry
local probeResult = nil -- cache/required-by info for one run, {at, pkgs}

local startCheck
local checkNews
local finishRun

local function cfg(key)
    return noctalia.getConfig(key)
end

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function trim(value)
    return noctalia.string.trim(value or "")
end

local function shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

-- The package-manager backends: every distro-specific command, parser and
-- capability lives there; the engine only orchestrates.
local BACKEND_FACTORIES = {
    pacman = require("./backends/pacman.luau"),
    packagekit = require("./backends/packagekit.luau"),
    dnf = require("./backends/dnf.luau"),
    apt = require("./backends/apt.luau"),
    zypper = require("./backends/zypper.luau"),
    xbps = require("./backends/xbps.luau"),
}

-- Backend choice: the "backend" setting wins; "auto" resolves from
-- /etc/os-release (ID, then ID_LIKE — Manjaro and friends carry
-- ID_LIKE=arch), then falls back by installed tooling: a native backend's
-- manager first, PackageKit as the generic answer for everything else.
local OS_RELEASE = noctalia.readFile("/etc/os-release") or ""

local function resolveBackendId()
    local choice = cfg("backend")
    if type(choice) == "string" and BACKEND_FACTORIES[choice] ~= nil then
        return choice
    end
    local osRelease = OS_RELEASE
    local id = osRelease:match('\nID="?([%w%-%._]+)') or osRelease:match('^ID="?([%w%-%._]+)') or ""
    local idLike = osRelease:match('ID_LIKE="?([%w%-%._ ]+)') or ""
    local haystack = " " .. id .. " " .. idLike .. " "
    if haystack:find(" arch ", 1, true) ~= nil then
        return "pacman"
    end
    if (haystack:find("fedora", 1, true) ~= nil or haystack:find("rhel", 1, true) ~= nil)
        and noctalia.commandExists("dnf") then
        return "dnf"
    end
    if (haystack:find("debian", 1, true) ~= nil or haystack:find("ubuntu", 1, true) ~= nil)
        and noctalia.commandExists("apt-get") then
        return "apt"
    end
    if haystack:find("suse", 1, true) ~= nil and noctalia.commandExists("zypper") then
        return "zypper"
    end
    if haystack:find("void", 1, true) ~= nil and noctalia.commandExists("xbps-install") then
        return "xbps"
    end
    -- Unrecognized distro: fall back by whichever native tool exists,
    -- PackageKit as the generic answer for everything else.
    for _, candidate in ipairs({
        { tool = "pacman", id = "pacman" },
        { tool = "dnf", id = "dnf" },
        { tool = "apt-get", id = "apt" },
        { tool = "zypper", id = "zypper" },
        { tool = "xbps-install", id = "xbps" },
    }) do
        if noctalia.commandExists(candidate.tool) then
            return candidate.id
        end
    end
    return "packagekit"
end

local backend = BACKEND_FACTORIES[resolveBackendId()]({
    trim = trim,
    shellQuote = shellQuote,
    cfg = cfg,
    MAX_LISTED = MAX_LISTED,
    commandExists = noctalia.commandExists,
    osRelease = OS_RELEASE,
})

-- Cross-distro extra sources (npm, cargo, pip, gem, snap, brew): opt-in
-- per-manager, checked after Flatpak and appended to the update run where
-- they support updating. All display-only in the run history — no rollback
-- and no installed-versions verification, like Flatpak.
local EXTRAS = require("./extras.luau")({
    trim = trim,
    shellQuote = shellQuote,
    cfg = cfg,
    MAX_LISTED = MAX_LISTED,
    commandExists = noctalia.commandExists,
})

local extraSources = {} -- key -> { n, items } for the extras of the last check

local function enabledExtras()
    local list = {}
    for _, extra in ipairs(EXTRAS) do
        if cfg(extra.settingKey) == true and noctalia.commandExists(extra.tool) then
            table.insert(list, extra)
        end
    end
    return list
end

-- Sources whose packages the backend itself installed — the only ones the
-- backend's own rollback and the installed-versions verification may touch.
local function nativeSource(source)
    return source == "pacman" or source == "aur"
end

-- Per-item rollback capability of the non-backend sources, published so the
-- panel can offer the right control: "version" reinstalls the recorded old
-- version through the manager itself, "revert" restores the manager's own
-- previous state (snap), "commit" pins the previous Flatpak commit.
local SOURCE_ROLLBACK = (function()
    local map = { flatpak = "commit" }
    for _, extra in ipairs(EXTRAS) do
        if extra.rollbackKind ~= nil then
            map[extra.key] = extra.rollbackKind
        end
    end
    return map
end)()

local EXTRAS_BY_KEY = (function()
    local map = {}
    for _, extra in ipairs(EXTRAS) do
        map[extra.key] = extra
    end
    return map
end)()
-- nil when the backend needs no keep-authorization rule (e.g. PackageKit
-- brings its own polkit policies) — the whole rule machinery is off then.
local POLKIT_RULE_PATH = backend.polkitRuleName ~= nil
    and ("/etc/polkit-1/rules.d/" .. backend.polkitRuleName)
    or nil

local function logPath()
    local dir, err = noctalia.pluginDataDir()
    if dir == nil then
        noctalia.log("linux-updater: cannot resolve plugin data dir: " .. tostring(err))
        return nil
    end
    return dir .. "/" .. LOG_FILE
end

-- Package names reach the command line (--ignore, pacman -Si), so only
-- pacman's own name grammar is accepted. Anything else is dropped with a log
-- line instead of being quoted.
local function validName(name)
    return name:match("^[a-zA-Z0-9._+-]+$") ~= nil
end

-- The ignore list also holds extra-source names, which may be npm scoped
-- packages ("@scope/pkg") — wider than the native grammar but still shaped
-- (must start with a word character or @, no shell metacharacters).
local function validIgnoreName(name)
    return name:match("^[%w@][%w@/._+-]*$") ~= nil
end

-- Backend commands splice ignore names in unquoted (--ignore a,b,
-- apt-mark hold ...), and a scoped npm name there would make e.g. apt-mark
-- fail — which, correctly, aborts the gated upgrade. So the backend only
-- ever sees names of its own grammar; the wider ones stay with the quoted
-- consumers (flatpak filter, extras).
local function nativeIgnoreNames(ignored)
    local names = {}
    for _, name in ipairs(ignored) do
        if validName(name) then
            table.insert(names, name)
        end
    end
    return names
end

-- Two plugin-side ignore sources: the "ignore_packages" setting and a
-- panel-managed list in IGNORE_FILE (the panel cannot write settings).
-- pacman.conf's IgnorePkg arrives from the checkers as "[ignored]" lines
-- and is displayed only, never managed here.
local function ignorePath()
    local dir, err = noctalia.pluginDataDir()
    if dir == nil then
        noctalia.log("linux-updater: cannot resolve plugin data dir: " .. tostring(err))
        return nil
    end
    return dir .. "/" .. IGNORE_FILE
end

local function loadDynamicIgnore()
    if dynamicIgnore ~= nil then
        return
    end
    dynamicIgnore = {}
    local path = ignorePath()
    local encoded = path ~= nil and noctalia.readFile(path) or nil
    local ok, decoded = pcall(function()
        return encoded ~= nil and noctalia.json.decode(encoded) or nil
    end)
    if ok and type(decoded) == "table" and type(decoded.packages) == "table" then
        for _, entry in ipairs(decoded.packages) do
            local name = trim(tostring(entry))
            if validIgnoreName(name) then
                table.insert(dynamicIgnore, name)
            end
        end
    end
end

local function saveDynamicIgnore()
    local path = ignorePath()
    if path == nil then
        return
    end
    local encoded = noctalia.json.encode({ packages = dynamicIgnore })
    if encoded ~= nil then
        noctalia.writeFile(path, encoded)
    end
end

local function configIgnoreList()
    local raw = cfg("ignore_packages")
    if type(raw) ~= "table" then
        return {}
    end
    local names = {}
    for _, entry in ipairs(raw) do
        local name = trim(tostring(entry))
        if validIgnoreName(name) then
            table.insert(names, name)
        elseif name ~= "" then
            noctalia.log("linux-updater: ignoring invalid package name '" .. name .. "'")
        end
    end
    return names
end

local function ignoreList()
    loadDynamicIgnore()
    local names = {}
    local seen = {}
    for _, name in ipairs(configIgnoreList()) do
        if not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end
    for _, name in ipairs(dynamicIgnore) do
        if not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end
    return names
end

local function ignoreSet()
    local set = {}
    for _, name in ipairs(ignoreList()) do
        set[name] = true
    end
    return set
end

-- Settings that change what a check would count. Once any of them moves,
-- the published numbers describe a check the new settings would not
-- produce, so the result is dropped (back to "not checked yet") instead of
-- shown; cosmetic settings (glyph, log lines) leave it alone. Note that a
-- backend switch additionally needs a plugin reload to take effect — the
-- stale count is still wrong to keep either way. Checked once per tick.
local checkSig = nil -- nil until the startup snapshot below

local function checkSignature()
    local parts = {
        tostring(cfg("backend")),
        tostring(cfg("aur_helper")),
        tostring(cfg("aur_check_cmd")),
        tostring(cfg("flatpak_enabled")),
        table.concat(configIgnoreList(), ","),
    }
    for _, extra in ipairs(EXTRAS) do
        table.insert(parts, tostring(cfg(extra.settingKey)))
    end
    return table.concat(parts, "\0")
end

-- Appends to the panel-managed list without touching the current snapshot;
-- used in bulk after a rollback when rollback_auto_ignore is on.
local function addIgnoreName(name)
    name = trim(tostring(name or ""))
    if not validIgnoreName(name) then
        return
    end
    loadDynamicIgnore()
    for _, existing in ipairs(ignoreList()) do
        if existing == name then
            return
        end
    end
    table.insert(dynamicIgnore, name)
    saveDynamicIgnore()
end

-- ── Run history ──────────────────────────────────────────────────────────────

-- One entry per finished background run: when it ran, whether it was a
-- rollback, and the "name from -> to" list it applied. This is what the
-- panel's history strip shows and what rollback resolves versions from.
local function runsPath()
    local dir = noctalia.pluginDataDir()
    return dir ~= nil and (dir .. "/" .. RUNS_FILE) or nil
end

local function loadRuns()
    if runsHistory ~= nil then
        return
    end
    runsHistory = {}
    local path = runsPath()
    local encoded = path ~= nil and noctalia.readFile(path) or nil
    local ok, decoded = pcall(function()
        return encoded ~= nil and noctalia.json.decode(encoded) or nil
    end)
    if ok and type(decoded) == "table" and type(decoded.runs) == "table" then
        for _, entry in ipairs(decoded.runs) do
            if type(entry) == "table" and tonumber(entry.at) ~= nil and type(entry.packages) == "table" then
                table.insert(runsHistory, entry)
            end
        end
    end
end

local function saveRuns()
    local path = runsPath()
    if path == nil then
        return
    end
    local encoded = noctalia.json.encode({ runs = runsHistory })
    if encoded ~= nil then
        noctalia.writeFile(path, encoded)
    end
end

local historyState = nil -- cached newest-first copy for publish()

local function historyForState()
    if historyState == nil then
        loadRuns()
        historyState = {}
        for i = #runsHistory, 1, -1 do
            local entry = runsHistory[i]
            table.insert(historyState, {
                at = entry.at,
                rollback = entry.rollback == true,
                n = #entry.packages,
                packages = entry.packages,
                txId = entry.txId,
            })
        end
    end
    return historyState
end

local function recordRun(kind, packages, txId)
    if type(packages) ~= "table" or #packages == 0 then
        return
    end
    loadRuns()
    table.insert(runsHistory, { at = os.time(), rollback = kind == "rollback", packages = packages, txId = txId })
    while #runsHistory > MAX_RUNS do
        table.remove(runsHistory, 1)
    end
    historyState = nil
    saveRuns()
end

local function findRun(at)
    loadRuns()
    for _, entry in ipairs(runsHistory) do
        if tonumber(entry.at) == tonumber(at) then
            return entry
        end
    end
    return nil
end

-- Snapshot of everything the update run is about to apply, taken at launch:
-- the run itself is non-interactive, so its target set is exactly the
-- pending list. Flatpak entries are kept for display but can't be rolled
-- back through the pacman cache.
local function collectPendingPackages()
    local packages = {}
    local slots = { { key = "pacman", entry = sources.pacman }, { key = "aur", entry = sources.aur }, { key = "flatpak", entry = sources.flatpak } }
    for _, extra in ipairs(EXTRAS) do
        -- Check-only extras (pip) are not part of the run, so recording their
        -- packages as applied would lie.
        if extra.buildUpdateCommand ~= nil and extraSources[extra.key] ~= nil then
            table.insert(slots, { key = extra.key, entry = extraSources[extra.key] })
        end
    end
    for _, source in ipairs(slots) do
        for _, item in ipairs(source.entry.items or {}) do
            if #packages < MAX_RUN_PACKAGES then
                -- commit: only Flatpak items carry one; it is what their
                -- per-item rollback pins.
                table.insert(packages, { name = item.name, from = item.from, to = item.to, source = source.key, commit = item.commit })
            end
        end
    end
    return packages
end

-- ── Activity history (the panel's trend graph, opt-in) ───────────────────────

-- One { n, at, afterUpdate } entry per finished check: how many updates were
-- pending at that moment. The panel draws these as a small trend graph.
-- Distinct from the run history above: this tracks *checks* (including the
-- stretches when nothing was updated), not applied runs.
local function activityStatePath()
    local dir = noctalia.pluginDataDir()
    return dir ~= nil and (dir .. "/" .. ACTIVITY_FILE) or nil
end

local function loadActivityState()
    if activityLoaded then
        return
    end
    activityLoaded = true
    local path = activityStatePath()
    local encoded = path ~= nil and noctalia.readFile(path) or nil
    local ok, decoded = pcall(function()
        return encoded ~= nil and noctalia.json.decode(encoded) or nil
    end)
    if ok and type(decoded) == "table" then
        if type(decoded.history) == "table" then
            local entries = {}
            for _, entry in ipairs(decoded.history) do
                if type(entry) == "table" then
                    table.insert(entries, {
                        n = tonumber(entry.n) or 0,
                        at = tonumber(entry.at),
                        afterUpdate = entry.afterUpdate == true,
                    })
                end
            end
            activityHistory = entries
        end
        if type(decoded.lastUpdateAt) == "number" then
            activityLastUpdateAt = decoded.lastUpdateAt
        end
    end
end

local function saveActivityState()
    local path = activityStatePath()
    if path == nil then
        return
    end
    local encoded = noctalia.json.encode({ history = activityHistory, lastUpdateAt = activityLastUpdateAt })
    if encoded ~= nil then
        noctalia.writeFile(path, encoded)
    end
end

-- Appends the current total to the activity history, trimmed to the
-- configured length. A no-op when the graph is turned off, so disabling it
-- also stops collecting data, not just hides it.
local function recordCheck()
    local wasPostUpdate = checkIsPostUpdate
    checkIsPostUpdate = false
    if cfg("show_activity_graph") ~= true then
        return
    end
    loadActivityState()
    table.insert(activityHistory, { n = total, at = os.time(), afterUpdate = wasPostUpdate })
    local maxLen = math.max(3, math.min(30, tonumber(cfg("activity_history_length")) or 10))
    while #activityHistory > maxLen do
        table.remove(activityHistory, 1)
    end
    saveActivityState()
end

-- Marks the check that follows as the one that verifies an update run, so its
-- history entry can say "Updated" instead of just a pending count.
local function recordUpdateRun()
    checkIsPostUpdate = true
    if cfg("show_activity_graph") ~= true then
        return
    end
    loadActivityState()
    activityLastUpdateAt = os.time()
    saveActivityState()
end

-- ── Parsing ──────────────────────────────────────────────────────────────────

-- Flatpak has no "name oldver -> newver" line, so the query joins installed
-- and pending by application id (tab-separated name/from/to, plus the full
-- active commit as a fourth field — that is what a rollback pins).
local function parseTabLines(output, ignored)
    local items = {}
    local n = 0
    for line in (output or ""):gmatch("[^\n]+") do
        local fields = {}
        for field in (line .. "\t"):gmatch("([^\t]*)\t") do
            table.insert(fields, field)
        end
        local name = fields[1] or ""
        if name ~= "" then
            if ignored[name] then
                table.insert(ignoredPending, { name = name, from = fields[2] or "", to = fields[3] or "", source = "plugin" })
            else
                n += 1
                if #items < MAX_LISTED then
                    local item = { name = name, from = fields[2] or "", to = fields[3] or "" }
                    if fields[4] ~= nil and fields[4] ~= "" then
                        item.commit = fields[4]
                    end
                    table.insert(items, item)
                end
            end
        end
    end
    return n, items
end

-- ── Publishing ───────────────────────────────────────────────────────────────

local function publish()
    if cfg("show_activity_graph") == true then
        loadActivityState() -- no-op after the first call; keeps the graph populated right after a reload
    end
    stateNonce += 1
    noctalia.state.set(STATE_KEY, {
        nonce = stateNonce,
        phase = phase,
        step = step,
        total = total,
        pacman = sources.pacman,
        aur = sources.aur,
        flatpak = sources.flatpak,
        extras = (function()
            -- Ordered array for the panel: only the extras of the last check,
            -- each carrying its label key so the panel needs no table of its
            -- own. Entries with n == 0 are kept for the "Up to date" caption.
            local list = {}
            for _, extra in ipairs(EXTRAS) do
                local entry = extraSources[extra.key]
                if entry ~= nil then
                    table.insert(list, {
                        key = extra.key,
                        n = entry.n,
                        items = entry.items,
                        label = extra.labelKey,
                        updatable = extra.buildUpdateCommand ~= nil,
                    })
                end
            end
            return list
        end)(),
        downloadSizeMiB = downloadSizeMiB,
        rebootRecommended = rebootRecommended,
        newsUnread = newsUnread,
        newsLatestTitle = newsLatestTitle,
        err = errMsg,
        checkedAt = checkedAt,
        backend = backend.id,
        caps = backend.caps,
        nativeLabel = backend.nativeLabelKey,
        systemIgnoreLabel = backend.systemIgnoreLabelKey,
        systemIgnoreTip = backend.systemIgnoreTipKey,
        selfChecks = selfCheckState,
        ignoredCount = #ignoreList(),
        ignoredPending = ignoredPending,
        ignoredDynamic = dynamicIgnore or {},
        ignoredConfig = configIgnoreList(),
        polkitRule = polkitRuleInstalled,
        sourceRollback = SOURCE_ROLLBACK,
        nativeItemRollback = backend.rollbackItemCommand ~= nil,
        history = historyForState(),
        activity = activityHistory,
        lastUpdateAt = activityLastUpdateAt,
        runKind = runKind,
        runMode = runMode,
        probe = probeResult,
        flatpakEnabled = cfg("flatpak_enabled") == true and noctalia.commandExists("flatpak"),
        logTail = logTail,
        logPath = logPath(),
        runExit = runExit,
        progress = { done = runDone, total = runTotal },
    })
end

-- ── Checking pipeline: backend → AUR → Flatpak → extras → size → reboot ─────

local checkFlatpak
local checkExtras
local checkSize
local checkReboot
local finishCheck

local function failCheck(message)
    phase = "error"
    errMsg = message
    publish()
end

checkReboot = function()
    if cfg("check_reboot_needed") ~= true then
        rebootRecommended = false
        finishCheck()
        return
    end
    local started = noctalia.runAsync(
        backend.rebootCommand,
        function(result)
            rebootRecommended = trim(result.stdout or "") == "missing"
            finishCheck()
        end,
        FAST_TIMEOUT_MS
    )
    if not started then
        rebootRecommended = false
        finishCheck()
    end
end

checkSize = function()
    if cfg("show_download_size") ~= true or backend.caps.size ~= true or sources.pacman.n == 0 then
        downloadSizeMiB = nil
        checkReboot()
        return
    end
    local names = {}
    for _, item in ipairs(sources.pacman.items) do
        table.insert(names, shellQuote(item.name))
    end
    if #names == 0 then
        -- More pending than MAX_LISTED kept a name for, so the size would
        -- under-count. Left unknown instead of wrong.
        downloadSizeMiB = nil
        checkReboot()
        return
    end
    local started = noctalia.runAsync(backend.sizeCommand(names), function(result)
        local value = tonumber(trim(result.stdout or ""))
        downloadSizeMiB = (not result.timedOut and result.exitCode == 0 and value ~= nil) and value or nil
        checkReboot()
    end, SIZE_TIMEOUT_MS)
    if not started then
        downloadSizeMiB = nil
        checkReboot()
    end
end

-- One extra source at a time, so a slow mirror never stacks timeouts; a
-- failing query is logged and its source left unknown for this check (not
-- zero — "up to date" because a registry was down would be a lie).
checkExtras = function(ignored)
    local queue = enabledExtras()
    local function pump()
        local extra = table.remove(queue, 1)
        if extra == nil then
            checkSize()
            return
        end
        step = tr(extra.labelKey)
        publish()
        local started = noctalia.runAsync(extra.checkCommand, function(result)
            if result.timedOut or result.exitCode ~= 0 then
                noctalia.log("linux-updater: " .. extra.key .. " check failed (exit "
                    .. tostring(result.exitCode) .. (result.timedOut and ", timeout" or "") .. ")")
                extraSources[extra.key] = nil
            else
                local n, items = extra.parseCheck(result.stdout, ignored, ignoredPending)
                extraSources[extra.key] = { n = n, items = items }
            end
            pump()
        end, CHECK_TIMEOUT_MS)
        if not started then
            noctalia.log("linux-updater: could not run the " .. extra.key .. " check")
            pump()
        end
    end
    pump()
end

checkFlatpak = function(ignored)
    if cfg("flatpak_enabled") ~= true or not noctalia.commandExists("flatpak") then
        sources.flatpak = { n = 0, items = {} }
        checkExtras(ignored)
        return
    end
    step = tr("source.flatpak")
    publish()
    -- Flatpak tracks commits, so a version string often doesn't move across
    -- an update. Short commits stand in when it doesn't, joined by
    -- application id in one awk pass.
    -- Each call's own output and exit code are captured before piping into
    -- awk, so a real flatpak failure (e.g. no remote, network down) fails
    -- the whole command instead of awk quietly succeeding on empty input.
    -- The trailing loop appends each pending app's FULL active commit
    -- (flatpak info -c): the `active` list column truncates to 12 chars,
    -- and `update --commit=` rejects a prefix with a server 404 (verified
    -- in an Ubuntu container) — only the full 64-char commit can roll back.
    local cmd = [[
listOut=$(flatpak list --columns=application,version,active 2>/dev/null); listCode=$?
updOut=$(flatpak remote-ls --updates --columns=application,version,commit 2>/dev/null); updCode=$?
if [ "$listCode" -ne 0 ] || [ "$updCode" -ne 0 ]; then
  exit 1
fi
{ printf '%s\n' "$listOut" | sed 's/^/L /'
  printf '%s\n' "$updOut" | sed 's/^/R /'
} | awk -F'\t' '
{ tag=substr($1,1,1); app=substr($1,3) }
tag=="L" { v[app]=$2; c[app]=$3 }
tag=="R" { from=v[app]; to=$2
           if (from=="" || to=="" || from==to) { from=substr(c[app],1,7); to=substr($3,1,7) }
           print app"\t"from"\t"to }' | while IFS="$(printf '\t')" read -r app from to; do
    printf '%s\t%s\t%s\t%s\n' "$app" "$from" "$to" "$(flatpak info "$app" -c 2>/dev/null)"
done]]
    -- Like the AUR: a broken Flatpak check fails its own slot and the check
    -- moves on to the extras.
    local started = noctalia.runAsync(cmd, function(result)
        if result.timedOut then
            noctalia.log("linux-updater: flatpak check timed out")
            sources.flatpak = { n = 0, items = {}, failed = true }
            checkExtras(ignored)
            return
        end
        if result.exitCode ~= 0 then
            noctalia.log("linux-updater: flatpak check failed (exit " .. tostring(result.exitCode) .. ")")
            sources.flatpak = { n = 0, items = {}, failed = true }
            checkExtras(ignored)
            return
        end
        local n, items = parseTabLines(result.stdout, ignored)
        sources.flatpak = { n = n, items = items }
        checkExtras(ignored)
    end, CHECK_TIMEOUT_MS)
    if not started then
        noctalia.log("linux-updater: could not run the flatpak check")
        sources.flatpak = { n = 0, items = {}, failed = true }
        checkExtras(ignored)
    end
end

local function checkAur(ignored)
    if backend.caps.aur ~= true then
        sources.aur = { n = 0, items = {}, helper = "" }
        checkFlatpak(ignored)
        return
    end
    local helper = backend.resolveAurHelper()
    if helper == nil then
        sources.aur = { n = 0, items = {}, helper = "" }
        checkFlatpak(ignored)
        return
    end
    if helper ~= "custom" and not noctalia.commandExists(helper) then
        sources.aur = { n = 0, items = {}, helper = "" }
        checkFlatpak(ignored)
        return
    end
    local cmd = backend.aurCheckCommand(helper)
    if cmd == nil then
        sources.aur = { n = 0, items = {}, helper = "" }
        checkFlatpak(ignored)
        return
    end
    step = helper == "custom" and tr("source.aur") or tr("source.aur_named", { helper = helper })
    publish()
    -- An unreachable AUR (mirror down, RPC blocked) must not abort the whole
    -- check: the other sources are still checkable. The slot is marked failed
    -- so the panel reports it instead of claiming "up to date" — same idea as
    -- the unknown extras, which a broken registry leaves out of the state.
    local helperShown = helper == "custom" and "" or helper
    local started = noctalia.runAsync(cmd, function(result)
        if result.timedOut then
            noctalia.log("linux-updater: AUR check timed out")
            sources.aur = { n = 0, items = {}, helper = helperShown, failed = true }
            checkFlatpak(ignored)
            return
        end
        -- "-Qua" (like plain pacman -Qu) exits non-zero for "nothing to
        -- upgrade" too, so exit code alone can't tell that apart from a real
        -- failure. A real failure prints something to stderr; "no updates"
        -- doesn't.
        if result.exitCode ~= 0 and trim(result.stderr or "") ~= "" then
            noctalia.log("linux-updater: AUR check failed: " .. trim(result.stderr))
            sources.aur = { n = 0, items = {}, helper = helperShown, failed = true }
            checkFlatpak(ignored)
            return
        end
        local n, items = backend.parseCheck(result.stdout, ignored, ignoredPending)
        sources.aur = { n = n, items = items, helper = helperShown }
        checkFlatpak(ignored)
    end, CHECK_TIMEOUT_MS)
    if not started then
        noctalia.log("linux-updater: could not run the AUR check")
        sources.aur = { n = 0, items = {}, helper = helperShown, failed = true }
        checkFlatpak(ignored)
    end
end

startCheck = function()
    if phase == "checking" or phase == "running" then
        return
    end
    if not noctalia.commandExists(backend.checkTool) then
        phase = "missing"
        errMsg = tr(backend.missingToolKey)
        publish()
        return
    end

    phase = "checking"
    errMsg = nil
    sources = { pacman = { n = 0, items = {} }, aur = { n = 0, items = {}, helper = "" }, flatpak = { n = 0, items = {} } }
    extraSources = {}
    downloadSizeMiB = nil
    ignoredPending = {}
    step = tr("source.pacman")
    publish()

    local ignored = ignoreSet()
    local started = noctalia.runAsync(backend.checkCommand, function(result)
        if result.timedOut then
            failCheck(tr("err_check_timeout"))
            return
        end
        if result.exitCode ~= 0 then
            noctalia.log("linux-updater: " .. backend.checkTool .. " failed (exit " .. tostring(result.exitCode) .. ")")
            failCheck(tr("err_check_failed"))
            return
        end
        local n, items = backend.parseCheck(result.stdout, ignored, ignoredPending)
        sources.pacman = { n = n, items = items }
        checkAur(ignored)
    end, CHECK_TIMEOUT_MS)

    if not started then
        failCheck(tr("err_spawn"))
    end
end

local function pendingTotal()
    local sum = sources.pacman.n + sources.aur.n + sources.flatpak.n
    for _, entry in pairs(extraSources) do
        sum += entry.n
    end
    return sum
end

finishCheck = function()
    total = pendingTotal()
    step = ""
    phase = total > 0 and "ready" or "clean"
    checkedAt = noctalia.formatTime("%H:%M")
    sinceCheck = 0
    recordCheck()
    publish()
    if total > 0 and cfg("notify_on_updates") == true then
        noctalia.notify(tr("title"), noctalia.trp("notify_updates", total, { count = total }))
    end
end

-- ── Arch Linux news ──────────────────────────────────────────────────────────

local function newsStatePath()
    local dir, err = noctalia.pluginDataDir()
    if dir == nil then
        noctalia.log("linux-updater: cannot resolve plugin data dir: " .. tostring(err))
        return nil
    end
    return dir .. "/" .. NEWS_FILE
end

local function loadNewsState()
    if newsStateLoaded then
        return
    end
    newsStateLoaded = true
    local path = newsStatePath()
    local encoded = path ~= nil and noctalia.readFile(path) or nil
    local ok, decoded = pcall(function()
        return encoded ~= nil and noctalia.json.decode(encoded) or nil
    end)
    if ok and type(decoded) == "table" and type(decoded.lastSeenGuid) == "string" then
        newsLastSeenGuid = decoded.lastSeenGuid
    end
end

local function saveNewsState()
    local path = newsStatePath()
    if path == nil then
        return
    end
    local encoded = noctalia.json.encode({ lastSeenGuid = newsLastSeenGuid })
    if encoded ~= nil then
        noctalia.writeFile(path, encoded)
    end
end

local HTML_ENTITIES = {
    ["&lt;"] = "<",
    ["&gt;"] = ">",
    ["&quot;"] = '"',
    ["&#39;"] = "'",
    ["&apos;"] = "'",
    ["&amp;"] = "&",
}

local function unescapeHtml(text)
    return (text:gsub("&#?%w+;", HTML_ENTITIES))
end

-- Plain RSS 2.0, so a few gmatch patterns are enough, no XML library needed.
-- Wrapped in pcall: a feed change degrades to no news data, not a crash.
local function parseNewsFeed(xml)
    local items = {}
    for block in xml:gmatch("<item>(.-)</item>") do
        local title = block:match("<title>(.-)</title>")
        local link = block:match("<link>(.-)</link>")
        local guid = block:match("<guid[^>]*>(.-)</guid>")
        if title ~= nil and link ~= nil then
            table.insert(items, {
                title = unescapeHtml(trim(title)),
                link = trim(link),
                guid = guid ~= nil and trim(guid) or trim(link),
            })
        end
    end
    return items
end

local function applyNewsItems(items)
    newsItems = items
    if #items == 0 then
        newsUnread = 0
        newsLatestTitle = nil
        return
    end
    newsLatestTitle = items[1].title
    if newsLastSeenGuid == nil then
        -- First run: today's news is the baseline, not a backlog to alert on.
        newsLastSeenGuid = items[1].guid
        saveNewsState()
        newsUnread = 0
        return
    end
    local unread = 0
    for _, item in ipairs(items) do
        if item.guid == newsLastSeenGuid then
            break
        end
        unread += 1
    end
    newsUnread = unread
end

checkNews = function()
    if backend.caps.news ~= true or backend.news == nil or cfg("check_arch_news") ~= true then
        return
    end
    loadNewsState()
    local ok = noctalia.http({ url = backend.news.url }, function(res)
        if not res.ok or res.body == nil or res.body == "" then
            return
        end
        local parsed, items = pcall(parseNewsFeed, res.body)
        if parsed and type(items) == "table" then
            applyNewsItems(items)
            newsDirty = true
        end
    end)
    if not ok then
        noctalia.log("linux-updater: could not start the Arch news request")
    end
end

-- Opens the news page and marks everything fetched so far as read.
local function openNews()
    if #newsItems > 0 then
        newsLastSeenGuid = newsItems[1].guid
        saveNewsState()
        newsUnread = 0
        publish()
    end
    if backend.news ~= nil then
        noctalia.runAsync("xdg-open " .. shellQuote(backend.news.page) .. " >/dev/null 2>&1")
    end
end

-- ── Polkit rule ──────────────────────────────────────────────────────────────
-- The keep-authorization rule text lives in the backend (embedded because
-- the plugin directory is not exposed to Lua at this api level).

-- /etc/polkit-1/rules.d is 750 root:polkitd on Arch, so an unprivileged
-- `test -f` cannot see the rule. Three answers: file visible (yes),
-- directory readable without the file (no), directory opaque — then a
-- marker written on successful install is the best available memory. Worst
-- case is a missing hint, never a broken update.
local function polkitMarkerPath()
    local dir = noctalia.pluginDataDir()
    return dir ~= nil and (dir .. "/polkit_rule_installed") or nil
end

local function checkPolkitRule()
    if POLKIT_RULE_PATH == nil then
        return
    end
    local cmd = "if [ -f " .. POLKIT_RULE_PATH .. " ]; then echo yes;"
        .. " elif [ -r /etc/polkit-1/rules.d ]; then echo no;"
        .. " else echo opaque; fi"
    noctalia.runAsync(cmd, function(result)
        local answer = trim(result.stdout or "")
        if answer == "yes" then
            polkitRuleInstalled = true
        elseif answer == "no" then
            polkitRuleInstalled = false
            local marker = polkitMarkerPath()
            if marker ~= nil then
                noctalia.runAsync("rm -f " .. shellQuote(marker))
            end
        elseif answer == "opaque" then
            local marker = polkitMarkerPath()
            polkitRuleInstalled = marker ~= nil and noctalia.readFile(marker) ~= nil
        else
            return
        end
        publish()
    end, FAST_TIMEOUT_MS)
end

-- The rule text is staged in the data dir because pkexec needs a file
-- path; polkit picks up rules.d changes on the fly.
local function installPolkitRule()
    if POLKIT_RULE_PATH == nil or backend.polkitRule == nil then
        return
    end
    if polkitInstallBusy or not noctalia.commandExists("pkexec") then
        return
    end
    local dir = noctalia.pluginDataDir()
    if dir == nil then
        return
    end
    local staged = dir .. "/" .. backend.polkitRuleName
    noctalia.writeFile(staged, backend.polkitRule)
    polkitInstallBusy = true
    local cmd = "pkexec install -Dm644 -o root -g root " .. shellQuote(staged) .. " " .. POLKIT_RULE_PATH
    local started = noctalia.runAsync(cmd, function(result)
        polkitInstallBusy = false
        if result.exitCode == 0 then
            -- Recorded in the marker because rules.d is opaque to the user.
            local marker = polkitMarkerPath()
            if marker ~= nil then
                noctalia.writeFile(marker, "1")
            end
            polkitRuleInstalled = true
            publish()
            noctalia.notify(tr("title"), tr("notify_polkit_ok"))
        elseif result.exitCode ~= 126 then
            -- 126 = the polkit dialog was dismissed; anything else failed.
            noctalia.notifyError(tr("title"), tr("err_polkit_install"))
            checkPolkitRule()
        end
    end, 120000)
    if not started then
        polkitInstallBusy = false
    end
end

-- ── Updating (background) ────────────────────────────────────────────────────

-- The core upgrade command, fully non-interactive. pkexec raises the polkit
-- password dialog; --noconfirm answers every remaining question with its
-- default. AUR helpers run as the user and escalate through pkexec themselves
-- (--sudo pkexec), so no terminal and no sudo tty are ever needed.
-- Flatpak is cross-distro, so its update part belongs to the engine, not a
-- backend. Shared by both modes. Same ignore list as the native manager:
-- filter ignored refs out of the pending Flatpak list before updating, so
-- an app hidden from the panel's count can't still slip in through a bare
-- `flatpak update`. `flags` carries the mode's own switches
-- (non-interactive for the background run).
local function buildFlatpakPart(ignored, flags)
    if cfg("flatpak_enabled") ~= true or not noctalia.commandExists("flatpak") then
        return nil
    end
    if #ignored == 0 then
        return "flatpak update" .. flags
    end
    local skipList = shellQuote(table.concat(ignored, "\n"))
    return "{ flatpak_refs=$(flatpak remote-ls --updates --columns=application 2>/dev/null | awk -v ignore="
        .. skipList
        .. [=[ 'BEGIN { n = split(ignore, arr, "\n"); for (i = 1; i <= n; i++) skip[arr[i]] = 1 } !($0 in skip)'); ]=]
        .. [[if [ -n "$flatpak_refs" ]; then flatpak update]] .. flags .. [[ $flatpak_refs; fi; }]]
end

-- The extras' upgrade parts, shared by both modes (none of them prompt).
-- Plain "update everything" normally; with a plugin ignore list the pending
-- snapshot minus the ignored names is passed explicitly instead — the parse
-- already routed ignored names out of items. When the snapshot is truncated
-- (n > #items) the explicit list would silently drop packages, so it falls
-- back to update-all with a log line: an ignore miss beats a lost update.
local function buildExtrasParts(ignored)
    local parts = {}
    for _, extra in ipairs(enabledExtras()) do
        if extra.buildUpdateCommand ~= nil then
            local names = nil
            local entry = extraSources[extra.key]
            if #ignored > 0 and entry ~= nil then
                if entry.n == #entry.items then
                    if entry.n == 0 then
                        -- Everything this manager had pending (if anything)
                        -- is ignored; a plain update-all would grab it.
                        continue
                    end
                    names = {}
                    for _, item in ipairs(entry.items) do
                        table.insert(names, shellQuote(item.name))
                    end
                else
                    noctalia.log("linux-updater: " .. extra.key .. " pending list truncated, ignore list not applied")
                end
            end
            table.insert(parts, extra.buildUpdateCommand(names))
        end
    end
    return parts
end

-- For backends that cannot exclude per transaction (backend.ignoreByExplicitList,
-- PackageKit): with a non-empty ignore list the pending-minus-ignored snapshot
-- is passed as explicit (quoted) names, same policy as the extras. nil = no
-- filtering needed; {} = everything pending is ignored, skip the upgrade.
-- A truncated snapshot (n > #items) falls back to update-all with a log line:
-- an ignore miss beats a lost update.
local function nativePendingNames(ignored)
    if backend.ignoreByExplicitList ~= true or #ignored == 0 then
        return nil
    end
    if sources.pacman.n ~= #sources.pacman.items then
        noctalia.log("linux-updater: pending list truncated, ignore list not applied to " .. backend.id)
        return nil
    end
    local names = {}
    for _, item in ipairs(sources.pacman.items) do
        if validName(tostring(item.name or "")) then
            table.insert(names, shellQuote(item.name))
        end
    end
    return names
end

local function buildBackgroundCommand()
    local override = trim(cfg("update_cmd"))
    if override ~= "" then
        return override
    end
    local ignored = ignoreList()
    local parts = { backend.buildBackgroundCommand(nativeIgnoreNames(ignored), nativePendingNames(ignored)) }
    local flatpakPart = buildFlatpakPart(ignored, " -y --noninteractive")
    if flatpakPart ~= nil then
        table.insert(parts, flatpakPart)
    end
    for _, part in ipairs(buildExtrasParts(ignored)) do
        table.insert(parts, part)
    end
    return table.concat(parts, " && ")
end

-- Interactive variant, used when update_mode is "terminal" and as the retry
-- after a failed background run: no --noconfirm, prompts work as usual.
-- Output is tee'd into the same log so the engine still sees the "::EXIT"
-- marker and re-checks when the run ends.
local function buildTerminalCommand()
    local ignored = ignoreList()
    local parts = { backend.buildTerminalCommand(nativeIgnoreNames(ignored), nativePendingNames(ignored)) }
    local flatpakPart = buildFlatpakPart(ignored, "")
    if flatpakPart ~= nil then
        table.insert(parts, flatpakPart)
    end
    for _, part in ipairs(buildExtrasParts(ignored)) do
        table.insert(parts, part)
    end
    return table.concat(parts, " && ")
end

-- Uses Noctalia's terminal discovery ($TERMINAL, then the usual emulators)
-- unless a terminal is configured.
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

-- "Open full log": xdg-open is unreliable for plain text (text/plain often
-- maps to a terminal editor like vim, which cannot start without a tty and
-- dies silently), so the log opens in a terminal pager instead.
local function openLog()
    local path = logPath()
    if path == nil then
        return
    end
    if not launchTerminal("less +G -- " .. shellQuote(path)) then
        noctalia.notifyError(tr("title"), tr("err_no_terminal"))
    end
end

-- The current run's kind, package list and expected total live in memory,
-- which a hot reload or shell restart wipes; persisting them next to the
-- log lets a resumed engine keep the progress percent and still record the
-- run in the history when it finishes.
local function runMetaPath()
    local dir = noctalia.pluginDataDir()
    return dir ~= nil and (dir .. "/" .. RUN_META_FILE) or nil
end

local function saveRunMeta()
    local path = runMetaPath()
    if path == nil then
        return
    end
    local encoded = noctalia.json.encode({ kind = runKind, mode = runMode, failHint = runFailHintKey, total = runTotal, packages = runPackages })
    if encoded ~= nil then
        noctalia.writeFile(path, encoded)
    end
end

local function loadRunMeta()
    local path = runMetaPath()
    local encoded = path ~= nil and noctalia.readFile(path) or nil
    local ok, decoded = pcall(function()
        return encoded ~= nil and noctalia.json.decode(encoded) or nil
    end)
    if ok and type(decoded) == "table" then
        runKind = decoded.kind == "rollback" and "rollback" or "update"
        runMode = decoded.mode == "terminal" and "terminal" or "background"
        runFailHintKey = type(decoded.failHint) == "string" and decoded.failHint or nil
        runTotal = tonumber(decoded.total) or 0
        runPackages = type(decoded.packages) == "table" and decoded.packages or nil
    end
end

local function clearRunMeta()
    local path = runMetaPath()
    if path ~= nil then
        noctalia.runAsync("rm -f -- " .. shellQuote(path))
    end
end

local function beginRun(kind, expectTotal, mode)
    phase = "running"
    errMsg = nil
    step = ""
    runKind = kind or "update"
    runMode = mode or "background"
    runFailHintKey = nil
    runExit = nil
    runDone = 0
    runTotal = expectTotal or total
    runStaleS = 0
    runPollTicks = 0
    logTail = {}
    lastTailText = ""
    publish()
end

local function runUpdate()
    if phase == "running" or phase == "checking" then
        return
    end
    if not noctalia.commandExists(backend.checkTool) then
        phase = "missing"
        errMsg = tr(backend.missingToolKey)
        publish()
        return
    end
    -- Only backends escalating through pkexec need it; PackageKit brings
    -- its own polkit path.
    if backend.polkitRuleName ~= nil and not noctalia.commandExists("pkexec") then
        phase = "error"
        errMsg = tr("err_no_pkexec")
        publish()
        noctalia.notifyError(tr("title"), tr("err_no_pkexec"))
        return
    end
    local path = logPath()
    if path == nil then
        phase = "error"
        errMsg = tr("err_spawn")
        publish()
        return
    end

    -- "::START <epoch>" lets a restarted engine tell a live run from a stale
    -- log; "::EXIT <code>" is the completion marker the poller waits for.
    -- export LC_ALL=C: the progress patterns grep for English package-manager
    -- lines ("upgrading ...", "Unpacking ..."), which the managers translate.
    -- pkexec whitelists LC_* through its environment scrub, so the escalated
    -- manager inherits it. Terminal runs deliberately keep the user's locale
    -- (their window, their language) at the cost of the progress count there.
    local quoted = shellQuote(path)
    local script = "printf '::START %s\\n' \"$(date +%s)\" > " .. quoted
        .. "; { export LC_ALL=C; " .. buildBackgroundCommand() .. " ; } >> " .. quoted .. " 2>&1"
        .. "; printf '::EXIT %s\\n' \"$?\" >> " .. quoted

    if not noctalia.runAsync(script) then
        phase = "error"
        errMsg = tr("err_spawn")
        publish()
        return
    end
    runPackages = collectPendingPackages()
    beginRun("update")
    saveRunMeta()
end

local function runUpdateTerminal()
    if phase == "running" or phase == "checking" then
        return
    end
    local path = logPath()
    if path == nil then
        return
    end
    local quoted = shellQuote(path)
    local wrapped = "printf '::START %s\\n' \"$(date +%s)\" > " .. quoted
        .. "; { " .. buildTerminalCommand() .. "; printf '::EXIT %s\\n' \"$?\" ; } 2>&1 | tee -a " .. quoted
        .. "; echo; echo " .. shellQuote(tr("run.press_key")) .. "; read -n 1"
    if not launchTerminal(wrapped) then
        phase = "error"
        errMsg = tr("err_no_terminal")
        publish()
        noctalia.notifyError(tr("title"), tr("err_no_terminal"))
        return
    end
    runPackages = collectPendingPackages()
    beginRun("update", nil, "terminal")
    saveRunMeta()
end

-- The history entry trusts the pending-list snapshot taken at launch, but an
-- interactive terminal run lets the user decline packages along the way.
-- Before recording, the backend's installed-versions query weeds out entries
-- whose installed version never left `from`: they were not actually updated,
-- so a rollback segment offering to "undo" them would lie. Flatpak and
-- extra-source entries, and entries without a known old version, are kept
-- as-is (display only). Any failure to verify records the full snapshot,
-- like before.
local function verifyAndRecordRun(kind, packages, txId)
    local function fallback()
        recordRun(kind, packages, txId)
        publish()
    end
    if type(packages) ~= "table" or #packages == 0 then
        return
    end
    if backend.installedVersionsCommand == nil then
        fallback()
        return
    end
    local names = {}
    for _, item in ipairs(packages) do
        if nativeSource(item.source) and tostring(item.from or "") ~= "" and validName(tostring(item.name or "")) then
            table.insert(names, shellQuote(item.name))
        end
    end
    if #names == 0 then
        fallback()
        return
    end
    local started = noctalia.runAsync(backend.installedVersionsCommand(names), function(result)
        if result.timedOut then
            fallback()
            return
        end
        local installed = {}
        for line in (result.stdout or ""):gmatch("[^\n]+") do
            local name, version = line:match("^(%S+)%s+(%S+)$")
            if name ~= nil then
                installed[name] = version
            end
        end
        local applied = {}
        for _, item in ipairs(packages) do
            if not nativeSource(item.source) or tostring(item.from or "") == "" then
                table.insert(applied, item)
            elseif installed[item.name] ~= nil and installed[item.name] ~= item.from then
                table.insert(applied, item)
            end
        end
        recordRun(kind, applied, txId)
        publish()
    end, SIZE_TIMEOUT_MS)
    if not started then
        fallback()
    end
end

finishRun = function(code)
    runExit = code
    runStaleS = 0
    if code == 0 then
        if runKind == "rollback" then
            -- One atomic transaction: exit 0 means it all applied.
            recordRun(runKind, runPackages)
            noctalia.notify(tr("title"), tr("notify_rollback_ok"))
            if cfg("rollback_auto_ignore") == true and type(runPackages) == "table" then
                for _, item in ipairs(runPackages) do
                    addIgnoreName(item.name)
                end
            end
        else
            -- Native-rollback backends stamp the run with the package
            -- manager's own transaction id, fetched right after the run
            -- finishes; the history entry is then written asynchronously,
            -- verified against the installed versions where the backend can.
            local kind, packages = runKind, runPackages
            if backend.txIdCommand ~= nil and type(packages) == "table" then
                local started = noctalia.runAsync(backend.txIdCommand, function(result)
                    verifyAndRecordRun(kind, packages, backend.parseTxId(result.stdout))
                end, FAST_TIMEOUT_MS)
                if not started then
                    verifyAndRecordRun(kind, packages)
                end
            else
                verifyAndRecordRun(kind, packages)
            end
            noctalia.notify(tr("title"), tr("notify_run_ok"))
            recordUpdateRun() -- rollbacks don't count as "updated"
        end
        runPackages = nil
        clearRunMeta()
        phase = "clean"
        publish()
        startCheck() -- verify: phase becomes checking, then clean/ready
    else
        runPackages = nil
        clearRunMeta()
        phase = "error"
        -- A rollback with a backend-specific failure cause names it instead
        -- of the generic exit-code line; the log stays on screen either way.
        if runKind == "rollback" and runFailHintKey ~= nil then
            errMsg = tr(runFailHintKey, { code = tostring(code) })
        else
            errMsg = tr("err_run_failed", { code = tostring(code) })
        end
        publish()
        noctalia.notifyError(tr("title"), errMsg)
    end
end

local function stripAnsi(line)
    return (line:gsub("\27%[[%d;]*[A-Za-z]", ""):gsub("\r", ""))
end

-- One `tail` per poll: the last screenful for display plus a full-file
-- progress count, so the bar doesn't reset when early lines scroll out of
-- the tail window. The count matches the backend's package lines and
-- Flatpak's per-ref "Updating app/..." lines, so a run with pending
-- Flatpak updates can still reach 100%.
local function pollRunLog()
    local path = logPath()
    if path == nil then
        return
    end
    local keep = math.max(6, math.min(30, tonumber(cfg("log_lines")) or 14))
    local quoted = shellQuote(path)
    local countPattern = backend.progressPattern .. "|^(Updating|Installing) (app|runtime)/"
    local cmd = "tail -n " .. tostring(keep + 8) .. " " .. quoted .. " 2>/dev/null"
        .. "; printf '::COUNT %s\\n' \"$(grep -cE " .. shellQuote(countPattern) .. " " .. quoted .. " 2>/dev/null)\""
    local started = noctalia.runAsync(cmd, function(result)
        if phase ~= "running" then
            return
        end
        local text = result.stdout or ""
        if text == lastTailText then
            -- Staleness only means "stuck" for non-interactive runs. In a
            -- terminal the user may sit on a prompt for any amount of time;
            -- killing the tracking there would also offer a retry that
            -- clobbers the log under the live process.
            if runMode ~= "terminal" then
                runStaleS += RUN_POLL_SECONDS
                if runStaleS >= RUN_STALE_LIMIT_S then
                    finishRun(-1)
                end
            end
            return
        end
        lastTailText = text
        runStaleS = 0

        local lines = {}
        local exitCode = nil
        for line in text:gmatch("[^\n]+") do
            local exitMatch = line:match("^::EXIT (%-?%d+)")
            local countMatch = line:match("^::COUNT (%d+)")
            if exitMatch ~= nil then
                exitCode = tonumber(exitMatch)
            elseif countMatch ~= nil then
                runDone = tonumber(countMatch) or runDone
            elseif line:match("^::START ") == nil then
                line = stripAnsi(line)
                if trim(line) ~= "" then
                    table.insert(lines, line)
                end
            end
        end
        local tail = {}
        for i = math.max(1, #lines - keep + 1), #lines do
            table.insert(tail, lines[i])
        end
        logTail = tail

        if exitCode ~= nil then
            finishRun(exitCode)
        else
            publish()
        end
    end, FAST_TIMEOUT_MS)
    if not started then
        noctalia.log("linux-updater: could not poll the update log")
    end
end

-- A fresh engine (login, shell restart) re-attaches to an unfinished run:
-- the detached updater survives Noctalia, so an update.log with a recent
-- ::START and no ::EXIT means it is still going.
local function resumeRunIfActive()
    local path = logPath()
    if path == nil then
        resumeProbed = true
        return
    end
    local quoted = shellQuote(path)
    local cmd = "head -n 1 " .. quoted .. " 2>/dev/null; tail -n 3 " .. quoted .. " 2>/dev/null"
    local started = noctalia.runAsync(cmd, function(result)
        resumeProbed = true
        if phase ~= "idle" then
            return
        end
        local text = result.stdout or ""
        local startedAt = tonumber(text:match("::START (%d+)"))
        if startedAt == nil then
            return
        end
        if text:match("::EXIT %-?%d+") ~= nil then
            return
        end
        if os.time() - startedAt > RUN_RESUME_MAX_AGE_S then
            return
        end
        loadRunMeta()
        local hint = runFailHintKey -- beginRun clears it; restore the resumed run's own
        beginRun(runKind, runTotal > 0 and runTotal or nil, runMode)
        runFailHintKey = hint
    end, FAST_TIMEOUT_MS)
    if not started then
        resumeProbed = true
        noctalia.log("linux-updater: could not inspect the update log")
    end
end

-- ── Rollback ─────────────────────────────────────────────────────────────────

-- Rollback = `pkexec pacman -U` on the old package files still present in
-- the pacman cache (or the AUR helper's build cache). pacman installs the
-- chosen version directly, no need to step through intermediate upgrades.
-- --nodeps is never passed: a downgrade that would break another package's
-- versioned dependency (sonames included) makes pacman refuse the whole
-- transaction before anything changes.

local function versionOk(version)
    return version:match("^[%w:._+~-]+$") ~= nil
end

local function specArgs(specs)
    local args = {}
    for _, spec in ipairs(specs) do
        table.insert(args, shellQuote(spec.name) .. " " .. shellQuote(spec.version))
    end
    return table.concat(args, " ")
end

local function runRollback(specs, items)
    if backend.caps.rollback ~= "cache" then
        return
    end
    if phase == "running" or phase == "checking" or #specs == 0 then
        return
    end
    if not noctalia.commandExists("pkexec") then
        phase = "error"
        errMsg = tr("err_no_pkexec")
        publish()
        noctalia.notifyError(tr("title"), tr("err_no_pkexec"))
        return
    end
    local path = logPath()
    if path == nil then
        return
    end
    local body = "set -- " .. specArgs(specs) .. "\n" .. backend.findPkgSh .. [[

files=""
missing=""
while [ "$#" -ge 2 ]; do
    if f=$(find_pkg "$1" "$2"); then files="$files $f"; else missing="$missing $1"; fi
    shift 2
done
if [ -n "$missing" ]; then echo "missing in cache:$missing"; exit 3; fi
]] .. backend.rollbackInstall .. " $files"
    local quoted = shellQuote(path)
    local script = "printf '::START %s\\n' \"$(date +%s)\" > " .. quoted
        .. "; { " .. body .. "\n} >> " .. quoted .. " 2>&1"
        .. "; printf '::EXIT %s\\n' \"$?\" >> " .. quoted
    if not noctalia.runAsync(script) then
        phase = "error"
        errMsg = tr("err_spawn")
        publish()
        return
    end
    runPackages = items
    beginRun("rollback", #specs)
    saveRunMeta()
end

-- Reverses one run entry: rolling back a package means going from its
-- current `to` version back to `from`.
local function reversedItem(item)
    return { name = item.name, from = item.to, to = item.from, source = item.source }
end

-- Rollback of one Flatpak item: pin the full active commit recorded at
-- check time. The full 64-char checksum is required — the server rejects
-- a prefix with a 404. When the remote no longer serves that commit the
-- run fails honestly in the log, nothing changes.
local function flatpakRollbackCommand(item)
    local name = trim(tostring(item.name or ""))
    local commit = tostring(item.commit or "")
    if name:match("^[%w._-]+$") == nil or commit:match("^%x+$") == nil or #commit ~= 64 then
        return nil
    end
    return "flatpak update -y --noninteractive --commit=" .. commit .. " " .. shellQuote(name)
end

-- Shared detached runner for the single-command rollbacks (extras, Flatpak
-- commit pins, dnf per-package downgrade): same log, markers and poller as
-- everything else. failHintKey, when set, replaces the generic run-failure
-- message so the panel can say WHY (e.g. "the old version left the
-- repositories") instead of just an exit code.
local function runDetachedRollback(cmd, items, failHintKey)
    if phase == "running" or phase == "checking" then
        return
    end
    local path = logPath()
    if path == nil then
        return
    end
    local quoted = shellQuote(path)
    local script = "printf '::START %s\\n' \"$(date +%s)\" > " .. quoted
        .. "; { export LC_ALL=C; " .. cmd .. " ; } >> " .. quoted .. " 2>&1"
        .. "; printf '::EXIT %s\\n' \"$?\" >> " .. quoted
    if not noctalia.runAsync(script) then
        phase = "error"
        errMsg = tr("err_spawn")
        publish()
        return
    end
    runPackages = items
    beginRun("rollback", #items)
    runFailHintKey = failHintKey
    saveRunMeta()
end

-- Per-item rollback for the non-backend sources: the manager's own command
-- (npm/gem/cargo reinstall the recorded version, snap reverts, flatpak pins
-- a commit). No run-mate dependency resolution — each manager handles its
-- own.
local function startExtraRollback(item)
    local cmd
    if item.source == "flatpak" then
        cmd = flatpakRollbackCommand(item)
    else
        local extra = EXTRAS_BY_KEY[item.source]
        cmd = extra ~= nil and extra.buildRollbackCommand ~= nil and extra.buildRollbackCommand(item) or nil
    end
    if cmd == nil then
        return
    end
    runDetachedRollback(cmd, { reversedItem(item) })
end

-- Per-package rollback. Native packages go through the backend's cache path:
-- dependencies updated in the same run ride along in the same transaction
-- (pactree intersected with the run's package list), so a program and its
-- libraries move back together. Everything else routes to its source's own
-- rollback command.
local function startRollback(payload)
    if type(payload) ~= "table" then
        return
    end
    local run = findRun(payload.at)
    if run == nil then
        return
    end
    local name = trim(tostring(payload.pkg or ""))
    local target = nil
    for _, item in ipairs(run.packages) do
        if item.name == name then
            target = item
            break
        end
    end
    if target == nil then
        return
    end
    if not nativeSource(target.source) then
        startExtraRollback(target)
        return
    end
    -- Native backends without a package cache can still step one package
    -- back through their own manager (dnf downgrade) — with the backend's
    -- failure hint, since "the old version left the repositories" is the
    -- usual outcome worth naming.
    if backend.caps.rollback ~= "cache" then
        if backend.rollbackItemCommand ~= nil then
            local cmd = backend.rollbackItemCommand(target)
            if cmd ~= nil then
                runDetachedRollback(cmd, { reversedItem(target) }, backend.rollbackFailHintKey)
            end
        end
        return
    end
    if not validName(name) or not versionOk(tostring(target.from or "")) then
        return
    end
    local runMates = {}
    for _, item in ipairs(run.packages) do
        if nativeSource(item.source) and item.name ~= name and validName(item.name) and versionOk(tostring(item.from or "")) then
            runMates[item.name] = item
        end
    end
    local finish = function(depNames)
        local specs = { { name = name, version = target.from } }
        local items = { reversedItem(target) }
        for _, dep in ipairs(depNames) do
            local mate = runMates[dep]
            if mate ~= nil then
                table.insert(specs, { name = mate.name, version = mate.from })
                table.insert(items, reversedItem(mate))
                runMates[dep] = nil
            end
        end
        runRollback(specs, items)
    end
    local started = noctalia.runAsync(backend.depsListCommand(name), function(result)
        local deps = {}
        if not result.timedOut and result.exitCode == 0 then
            for line in (result.stdout or ""):gmatch("[^\n]+") do
                -- Dependency lists may carry raw depend strings: version
                -- pins ("libelf=0.196", "linux-api-headers>=4.10") and
                -- soname provides included. Strip the constraint so the
                -- name can match the run's package list.
                local dep = trim(line):match("^([^<>=]+)")
                if dep ~= nil and dep ~= "" then
                    table.insert(deps, dep)
                end
            end
        end
        finish(deps)
    end, SIZE_TIMEOUT_MS)
    if not started then
        finish({})
    end
end

-- Native whole-run rollback: the package manager reverses its own recorded
-- transaction (e.g. `dnf history undo <id>`), dependencies included. Runs
-- through the same detached runner and log as everything else.
local function runNativeRollback(run)
    if run.txId == nil or backend.rollbackNativeCommand == nil then
        return
    end
    if phase == "running" or phase == "checking" then
        return
    end
    local path = logPath()
    if path == nil then
        return
    end
    local items = {}
    for _, item in ipairs(run.packages) do
        if nativeSource(item.source) then
            table.insert(items, reversedItem(item))
        end
    end
    local quoted = shellQuote(path)
    local body = backend.rollbackNativeCommand(run.txId)
    local script = "printf '::START %s\\n' \"$(date +%s)\" > " .. quoted
        .. "; { " .. body .. " ; } >> " .. quoted .. " 2>&1"
        .. "; printf '::EXIT %s\\n' \"$?\" >> " .. quoted
    if not noctalia.runAsync(script) then
        phase = "error"
        errMsg = tr("err_spawn")
        publish()
        return
    end
    runPackages = items
    beginRun("rollback", #items)
    saveRunMeta()
end

local function startRollbackRun(payload)
    local run = findRun(type(payload) == "table" and payload.at or payload)
    if run == nil then
        return
    end
    if backend.caps.rollback == "native" then
        runNativeRollback(run)
        return
    end
    local specs = {}
    local items = {}
    for _, item in ipairs(run.packages) do
        if nativeSource(item.source) and validName(item.name) and versionOk(tostring(item.from or "")) then
            table.insert(specs, { name = item.name, version = item.from })
            table.insert(items, reversedItem(item))
        end
    end
    runRollback(specs, items)
end

-- Per-item rollback feasibility and reverse-dependency counts for one run,
-- fetched when the panel opens that run's package list: greys out packages
-- whose old version is gone — from the package cache (cache backends) or
-- from the repositories (backend.itemProbeSh, dnf) — so the reason appears
-- BEFORE a doomed attempt, and shows how many installed packages require
-- each one.
local function probeRun(payload)
    local probeBody
    if backend.caps.rollback == "cache" then
        probeBody = backend.findPkgSh .. [[

while [ "$#" -ge 2 ]; do
    if find_pkg "$1" "$2" >/dev/null; then c=ok; else c=miss; fi
    ]] .. backend.reverseDepsCountSh .. [[

    printf '%s|%s|%s\n' "$1" "$c" "$n"
    shift 2
done]]
    elseif backend.itemProbeSh ~= nil then
        probeBody = [[while [ "$#" -ge 2 ]; do
    ]] .. backend.itemProbeSh .. [[

    printf '%s|%s|0\n' "$1" "$c"
    shift 2
done]]
    else
        return
    end
    local run = findRun(type(payload) == "table" and payload.at or payload)
    if run == nil then
        return
    end
    local specs = {}
    for _, item in ipairs(run.packages) do
        if nativeSource(item.source) and validName(item.name) and versionOk(tostring(item.from or "")) then
            table.insert(specs, { name = item.name, version = item.from })
        end
    end
    if #specs == 0 then
        probeResult = { at = run.at, pkgs = {} }
        publish()
        return
    end
    local cmd = "set -- " .. specArgs(specs) .. "\n" .. probeBody
    noctalia.runAsync(cmd, function(result)
        if result.timedOut then
            return
        end
        local pkgs = {}
        for line in (result.stdout or ""):gmatch("[^\n]+") do
            local pkgName, cache, req = line:match("^(.-)|(%a+)|(%d+)$")
            if pkgName ~= nil then
                pkgs[pkgName] = { cache = cache == "ok", req = tonumber(req) or 0 }
            end
        end
        probeResult = { at = run.at, pkgs = pkgs }
        publish()
    end, SIZE_TIMEOUT_MS)
end

-- ── Backend self-checks ──────────────────────────────────────────────────────

-- "The plugin tells you and fixes it": each backend can declare environment
-- checks {id, testCommand (echo ok/fail), hintKey, actionKey, tipKey,
-- fixCommand}. Failing ones become panel hint rows with a fix button; the
-- fix runs one user-confirmed escalation, then the check re-runs. Nothing
-- is ever fixed silently.
local function runSelfChecks()
    if type(backend.selfChecks) ~= "table" then
        return
    end
    for _, check in ipairs(backend.selfChecks) do
        noctalia.runAsync(check.testCommand, function(result)
            local ok = trim(result.stdout or "") == "ok"
            local kept = {}
            for _, entry in ipairs(selfCheckState or {}) do
                if entry.id ~= check.id then
                    table.insert(kept, entry)
                end
            end
            if not ok then
                table.insert(kept, {
                    id = check.id,
                    hintKey = check.hintKey,
                    actionKey = check.actionKey,
                    tipKey = check.tipKey,
                })
            end
            selfCheckState = kept
            publish()
        end, FAST_TIMEOUT_MS)
    end
end

local function fixSelfCheck(payload)
    local id = type(payload) == "table" and payload.id or payload
    for _, check in ipairs(backend.selfChecks or {}) do
        if check.id == id and check.fixCommand ~= nil then
            noctalia.runAsync(check.fixCommand, function(_result)
                runSelfChecks()
            end, 120000)
            return
        end
    end
end

-- ── Requests, lifecycle ──────────────────────────────────────────────────────

-- Persists in IGNORE_FILE and takes effect immediately by moving the
-- package out of the current snapshot; n is only decremented when the
-- package was actually listed (entries beyond MAX_LISTED have no name).
local function payloadPkg(payload)
    return trim(tostring((type(payload) == "table" and payload.pkg or payload) or ""))
end

local function addIgnore(payload)
    local name = payloadPkg(payload)
    if not validIgnoreName(name) then
        return
    end
    addIgnoreName(name)
    local slots = { sources.pacman, sources.aur, sources.flatpak }
    for _, entry in pairs(extraSources) do
        table.insert(slots, entry)
    end
    for _, entry in ipairs(slots) do
        for index, item in ipairs(entry.items or {}) do
            if item.name == name then
                table.remove(entry.items, index)
                entry.n = math.max(0, (entry.n or 0) - 1)
                table.insert(ignoredPending, { name = item.name, from = item.from, to = item.to, source = "plugin" })
                break
            end
        end
    end
    total = pendingTotal()
    if phase == "ready" and total == 0 then
        phase = "clean"
    end
    publish()
end

-- Only the panel-managed list is editable here; settings entries and
-- pacman.conf's IgnorePkg are managed where they live.
local function removeIgnore(payload)
    local name = payloadPkg(payload)
    if name == "" then
        return
    end
    loadDynamicIgnore()
    local found = false
    for index, existing in ipairs(dynamicIgnore) do
        if existing == name then
            table.remove(dynamicIgnore, index)
            found = true
            break
        end
    end
    if not found then
        return
    end
    saveDynamicIgnore()
    -- A recheck brings the package's pending update (if any) back.
    if phase ~= "running" and phase ~= "checking" then
        startCheck()
    else
        publish()
    end
end

local function handle(action, payload)
    if action == "check" then
        startCheck()
    elseif action == "update" then
        -- Follows the update_mode setting; background is the default.
        if cfg("update_mode") == "terminal" then
            runUpdateTerminal()
        else
            runUpdate()
        end
    elseif action == "update_background" then
        runUpdate()
    elseif action == "update_terminal" then
        runUpdateTerminal()
    elseif action == "ignore" then
        addIgnore(payload)
    elseif action == "unignore" then
        removeIgnore(payload)
    elseif action == "rollback" then
        startRollback(payload)
    elseif action == "rollback_run" then
        startRollbackRun(payload)
    elseif action == "probe_run" then
        probeRun(payload)
    elseif action == "open_log" then
        openLog()
    elseif action == "polkit_install" then
        installPolkitRule()
    elseif action == "self_fix" then
        fixSelfCheck(payload)
    elseif action == "dismiss" then
        sources.pacman = { n = 0, items = {} }
        sources.aur = { n = 0, items = {}, helper = sources.aur.helper }
        sources.flatpak = { n = 0, items = {} }
        extraSources = {}
        total = 0
        downloadSizeMiB = nil
        runExit = nil
        logTail = {}
        phase = "clean"
        publish()
    elseif action == "open_news" then
        openNews()
    end
end

noctalia.state.watch(REQUEST_KEY, function(value)
    if type(value) ~= "table" then
        return
    end
    local nonce = tonumber(value.nonce) or 0
    if nonce <= lastRequestNonce then
        return
    end
    lastRequestNonce = nonce
    handle(value.action, value)
end)

-- Scriptable control:
--   noctalia msg plugin umedbazarov/linux-updater:service all check
--   noctalia msg plugin umedbazarov/linux-updater:service all update
--   noctalia msg plugin umedbazarov/linux-updater:service all update_background
--   noctalia msg plugin umedbazarov/linux-updater:service all update_terminal
--   noctalia msg plugin umedbazarov/linux-updater:service all dismiss
--   noctalia msg plugin umedbazarov/linux-updater:service all ignore:NAME
--   noctalia msg plugin umedbazarov/linux-updater:service all unignore:NAME
function onIpc(event, payload)
    local action, arg = tostring(event):match("^(%w+):(.+)$")
    if action ~= nil then
        handle(action, arg)
    else
        handle(event, payload)
    end
end

function update()
    local sig = checkSignature()
    if checkSig ~= nil and sig ~= checkSig then
        checkSig = sig
        -- Only settled phases are dropped: a run or a check in flight
        -- finishes under the settings it started with and re-publishes.
        if phase == "ready" or phase == "clean" or phase == "error" then
            phase = "idle"
            sources = { pacman = { n = 0, items = {} }, aur = { n = 0, items = {}, helper = "" }, flatpak = { n = 0, items = {} } }
            extraSources = {}
            total = 0
            downloadSizeMiB = nil
            ignoredPending = {}
            errMsg = nil
            runExit = nil
            checkedAt = ""
            publish()
        end
    elseif checkSig == nil then
        checkSig = sig
    end

    if phase == "running" then
        runPollTicks += 1
        if runPollTicks >= RUN_POLL_SECONDS then
            runPollTicks = 0
            pollRunLog()
        end
    elseif phase ~= "checking" then
        local hours = tonumber(cfg("auto_check_hours")) or 0
        if hours > 0 then
            if phase == "idle" then
                -- The startup auto-check waits for resumeRunIfActive's log
                -- probe: if a detached run is still going, starting a check
                -- first would flip phase to "checking" and the probe's
                -- callback would decline to re-attach.
                if resumeProbed then
                    startupTicks += 1
                end
                if startupTicks >= AUTO_CHECK_DELAY then
                    startCheck()
                end
            else
                sinceCheck += 1
                if sinceCheck >= hours * 3600 then
                    startCheck()
                end
            end
        end
    end

    if cfg("check_arch_news") == true then
        sinceNewsCheck += 1
        -- Fires once at startup (== AUTO_CHECK_DELAY), then every
        -- NEWS_RECHECK_HOURS. Resetting back to AUTO_CHECK_DELAY (not 0)
        -- keeps the "== AUTO_CHECK_DELAY" branch from re-firing every 10
        -- seconds.
        if sinceNewsCheck == AUTO_CHECK_DELAY or sinceNewsCheck >= NEWS_RECHECK_HOURS * 3600 + AUTO_CHECK_DELAY then
            if sinceNewsCheck > AUTO_CHECK_DELAY then
                sinceNewsCheck = AUTO_CHECK_DELAY
            end
            checkNews()
        end
    end

    if newsDirty then
        newsDirty = false
        publish()
    end
end

noctalia.setUpdateInterval(1000)
if not noctalia.commandExists(backend.checkTool) then
    phase = "missing"
    errMsg = tr(backend.missingToolKey)
end
publish()
resumeRunIfActive()
checkPolkitRule()
runSelfChecks()
