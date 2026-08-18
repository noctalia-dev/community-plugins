--!nonstrict
-- arch-updater singleton engine. Checks pacman, the AUR helper and Flatpak,
-- publishes the result as shared state, and runs the update in a terminal.
--
--   state    "arch_state"   = { nonce, phase, step, total, pacman, aur,
--                                flatpak, downloadSizeMiB, rebootRecommended,
--                                newsUnread, newsLatestTitle, err,
--                                checkedAt, ignoredCount, history, lastUpdateAt }
--   requests "arch_request" = { nonce, action }  -- check|update|dismiss
--
-- Checking runs pacman, then the AUR helper, then Flatpak, then (if pacman
-- has pending packages) a `pacman -Si` pass for the download size.
--
-- Update never runs in the background. runUpdate() opens a terminal so
-- pacman/the AUR helper can prompt and sudo can ask for a password, then
-- polls for the process to end and re-checks automatically.

local STATE_KEY = "arch_state"
local REQUEST_KEY = "arch_request"
local NEWS_FILE = "news_state.json"
local NEWS_URL = "https://archlinux.org/feeds/news/"
local NEWS_PAGE = "https://archlinux.org/news/"
local HISTORY_FILE = "history_state.json"

local CHECK_TIMEOUT_MS = 45000 -- pacman/AUR/flatpak checks: each may sync a mirror
local SIZE_TIMEOUT_MS = 20000 -- pacman -Si: local db, no mirror sync
local FAST_TIMEOUT_MS = 5000 -- reboot check: local filesystem only
local NEWS_RECHECK_HOURS = 6
local RUN_POLL_SECONDS = 2
local RUN_GRACE_SECONDS = 12
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

local runTicks = 0
local runSeen = false
local runPollTicks = 0
local updateProcessName = "pacman"
local sinceCheck = 0
local startupTicks = 0
local sinceNewsCheck = 0
local newsStateLoaded = false
local newsDirty = false
local history = {} -- { n, at, afterUpdate } per check, oldest first, trimmed to activity_history_length
local lastUpdateAt = nil -- os.time() of the last update run that finished
local historyStateLoaded = false
local checkIsPostUpdate = false -- next finished check followed an update run

local startCheck
local checkNews

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

-- Package names reach the command line (--ignore, pacman -Si), so only
-- pacman's own name grammar is accepted. Anything else is dropped with a log
-- line instead of being quoted.
local function ignoreList()
    local raw = cfg("ignore_packages")
    if type(raw) ~= "table" then
        return {}
    end
    local names = {}
    for _, entry in ipairs(raw) do
        local name = trim(tostring(entry))
        if name:match("^[a-zA-Z0-9._+-]+$") ~= nil then
            table.insert(names, name)
        elseif name ~= "" then
            noctalia.log("arch-updater: ignoring invalid package name '" .. name .. "'")
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

-- ── Parsing ──────────────────────────────────────────────────────────────────

-- One "name oldver -> newver" line per package: checkupdates' format, which
-- yay -Qua and paru -Qua also use.
local function parseVersionLines(output, ignored)
    local items = {}
    local n = 0
    for line in (output or ""):gmatch("[^\n]+") do
        local parts = {}
        for token in line:gmatch("%S+") do
            table.insert(parts, token)
        end
        if #parts >= 4 and not ignored[parts[1]] then
            n += 1
            if #items < MAX_LISTED then
                table.insert(items, { name = parts[1], from = parts[2], to = parts[4] })
            end
        end
    end
    return n, items
end

-- Flatpak has no "name oldver -> newver" line, so the query joins installed
-- and pending by application id (tab-separated name/from/to).
local function parseTabLines(output, ignored)
    local items = {}
    local n = 0
    for line in (output or ""):gmatch("[^\n]+") do
        local fields = {}
        for field in (line .. "\t"):gmatch("([^\t]*)\t") do
            table.insert(fields, field)
        end
        local name = fields[1] or ""
        if name ~= "" and not ignored[name] then
            n += 1
            if #items < MAX_LISTED then
                table.insert(items, { name = name, from = fields[2] or "", to = fields[3] or "" })
            end
        end
    end
    return n, items
end

-- ── AUR helper resolution ────────────────────────────────────────────────────

-- auto tries yay then paru. An explicit choice is trusted as-is and reported
-- missing instead of falling back to another helper.
local function resolveAurHelper()
    local choice = cfg("aur_helper")
    if choice == "off" then
        return nil
    end
    if choice == "custom" then
        return "custom"
    end
    if choice == "yay" or choice == "paru" then
        return choice
    end
    if noctalia.commandExists("yay") then
        return "yay"
    end
    if noctalia.commandExists("paru") then
        return "paru"
    end
    return nil
end

local function aurCheckCommand(helper)
    if helper == "custom" then
        local raw = trim(cfg("aur_check_cmd"))
        return raw ~= "" and raw or nil
    end
    -- No 2>/dev/null and no formatting pipe here: stderr is inspected below
    -- to tell a real failure from the "-Qua" family's usual no-updates exit
    -- code, and the raw output already matches checkupdates' own format.
    return helper .. " -Qua"
end

-- ── Publishing ───────────────────────────────────────────────────────────────

local function publish()
    stateNonce += 1
    noctalia.state.set(STATE_KEY, {
        nonce = stateNonce,
        phase = phase,
        step = step,
        total = total,
        pacman = sources.pacman,
        aur = sources.aur,
        flatpak = sources.flatpak,
        downloadSizeMiB = downloadSizeMiB,
        rebootRecommended = rebootRecommended,
        newsUnread = newsUnread,
        newsLatestTitle = newsLatestTitle,
        err = errMsg,
        checkedAt = checkedAt,
        ignoredCount = #ignoreList(),
        history = history,
        lastUpdateAt = lastUpdateAt,
        flatpakEnabled = cfg("flatpak_enabled") == true,
    })
end

-- ── Checking pipeline: pacman → AUR → Flatpak → size → reboot → done ────────

local checkFlatpak
local checkSize
local checkReboot
local finishCheck
local recordCheck

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
    -- A kernel upgrade replaces the whole /usr/lib/modules/<version> tree.
    -- Once the running kernel's own directory is gone, a reboot is what
    -- switches to the new one. Works for any kernel flavour since it checks
    -- against `uname -r` directly, without naming one.
    local started = noctalia.runAsync(
        [[test -d "/usr/lib/modules/$(uname -r)" && echo present || echo missing]],
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
    if cfg("show_download_size") ~= true or sources.pacman.n == 0 then
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
    local cmd = "LC_ALL=C pacman -Si " .. table.concat(names, " ") .. [[ 2>/dev/null | awk '
/^Name/ { name=$3 }
/^Download Size/ && !(name in done) {
    done[name]=1
    v=$4; u=$5
    gsub(",", ".", v)
    if (u == "GiB") v = v * 1024
    else if (u == "KiB") v = v / 1024
    else if (u == "B") v = v / 1024 / 1024
    sum += v
}
END { printf "%.2f", sum }']]
    local started = noctalia.runAsync(cmd, function(result)
        local value = tonumber(trim(result.stdout or ""))
        downloadSizeMiB = (not result.timedOut and result.exitCode == 0 and value ~= nil) and value or nil
        checkReboot()
    end, SIZE_TIMEOUT_MS)
    if not started then
        downloadSizeMiB = nil
        checkReboot()
    end
end

checkFlatpak = function(ignored)
    if cfg("flatpak_enabled") ~= true or not noctalia.commandExists("flatpak") then
        sources.flatpak = { n = 0, items = {} }
        checkSize()
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
           print app"\t"from"\t"to }']]
    local started = noctalia.runAsync(cmd, function(result)
        if result.timedOut then
            sources.flatpak = { n = 0, items = {} }
            checkSize()
            return
        end
        if result.exitCode ~= 0 then
            noctalia.log("arch-updater: flatpak check failed (exit " .. tostring(result.exitCode) .. ")")
            failCheck(tr("err_flatpak_failed"))
            return
        end
        local n, items = parseTabLines(result.stdout, ignored)
        sources.flatpak = { n = n, items = items }
        checkSize()
    end, CHECK_TIMEOUT_MS)
    if not started then
        sources.flatpak = { n = 0, items = {} }
        checkSize()
    end
end

local function checkAur(ignored)
    local helper = resolveAurHelper()
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
    local cmd = aurCheckCommand(helper)
    if cmd == nil then
        sources.aur = { n = 0, items = {}, helper = "" }
        checkFlatpak(ignored)
        return
    end
    step = helper == "custom" and tr("source.aur") or tr("source.aur_named", { helper = helper })
    publish()
    local started = noctalia.runAsync(cmd, function(result)
        if result.timedOut then
            sources.aur = { n = 0, items = {}, helper = "" }
            checkFlatpak(ignored)
            return
        end
        -- "-Qua" (like plain pacman -Qu) exits non-zero for "nothing to
        -- upgrade" too, so exit code alone can't tell that apart from a real
        -- failure. A real failure prints something to stderr; "no updates"
        -- doesn't.
        if result.exitCode ~= 0 and trim(result.stderr or "") ~= "" then
            noctalia.log("arch-updater: " .. helper .. " -Qua failed: " .. trim(result.stderr))
            failCheck(tr("err_aur_failed"))
            return
        end
        local n, items = parseVersionLines(result.stdout, ignored)
        sources.aur = { n = n, items = items, helper = helper == "custom" and "" or helper }
        checkFlatpak(ignored)
    end, CHECK_TIMEOUT_MS)
    if not started then
        sources.aur = { n = 0, items = {}, helper = "" }
        checkFlatpak(ignored)
    end
end

startCheck = function()
    if phase == "checking" then
        return
    end
    if not noctalia.commandExists("checkupdates") then
        phase = "missing"
        errMsg = tr("err_no_checkupdates")
        publish()
        return
    end

    phase = "checking"
    errMsg = nil
    sources = { pacman = { n = 0, items = {} }, aur = { n = 0, items = {}, helper = "" }, flatpak = { n = 0, items = {} } }
    downloadSizeMiB = nil
    step = tr("source.pacman")
    publish()

    local ignored = ignoreSet()
    -- checkupdates exits 2 for "no updates" (not an error), 1 for a real
    -- failure (mirror/db sync, etc). Normalize the former to 0 so only a
    -- genuine failure reaches result.exitCode below.
    local cmd = [[checkupdates 2>/dev/null; code=$?; if [ "$code" -eq 2 ]; then exit 0; fi; exit "$code"]]
    local started = noctalia.runAsync(cmd, function(result)
        if result.timedOut then
            failCheck(tr("err_check_timeout"))
            return
        end
        if result.exitCode ~= 0 then
            noctalia.log("arch-updater: checkupdates failed (exit " .. tostring(result.exitCode) .. ")")
            failCheck(tr("err_check_failed"))
            return
        end
        local n, items = parseVersionLines(result.stdout, ignored)
        sources.pacman = { n = n, items = items }
        checkAur(ignored)
    end, CHECK_TIMEOUT_MS)

    if not started then
        failCheck(tr("err_spawn"))
    end
end

finishCheck = function()
    total = sources.pacman.n + sources.aur.n + sources.flatpak.n
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
        noctalia.log("arch-updater: cannot resolve plugin data dir: " .. tostring(err))
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

-- ── Activity history ─────────────────────────────────────────────────────────

local function historyStatePath()
    local dir, err = noctalia.pluginDataDir()
    if dir == nil then
        noctalia.log("arch-updater: cannot resolve plugin data dir: " .. tostring(err))
        return nil
    end
    return dir .. "/" .. HISTORY_FILE
end

local function loadHistoryState()
    if historyStateLoaded then
        return
    end
    historyStateLoaded = true
    local path = historyStatePath()
    local encoded = path ~= nil and noctalia.readFile(path) or nil
    local ok, decoded = pcall(function()
        return encoded ~= nil and noctalia.json.decode(encoded) or nil
    end)
    if ok and type(decoded) == "table" then
        if type(decoded.history) == "table" then
            -- Migrates the old format (a plain array of counts) to entries with
            -- a timestamp and an afterUpdate flag, both unknown for old data.
            local migrated = {}
            for _, entry in ipairs(decoded.history) do
                if type(entry) == "table" then
                    table.insert(migrated, {
                        n = tonumber(entry.n) or 0,
                        at = tonumber(entry.at),
                        afterUpdate = entry.afterUpdate == true,
                    })
                elseif type(entry) == "number" then
                    table.insert(migrated, { n = entry, at = nil, afterUpdate = false })
                end
            end
            history = migrated
        end
        if type(decoded.lastUpdateAt) == "number" then
            lastUpdateAt = decoded.lastUpdateAt
        end
    end
end

local function saveHistoryState()
    local path = historyStatePath()
    if path == nil then
        return
    end
    local encoded = noctalia.json.encode({ history = history, lastUpdateAt = lastUpdateAt })
    if encoded ~= nil then
        noctalia.writeFile(path, encoded)
    end
end

-- Appends the current total to the activity history, trimmed to the
-- configured length. A no-op when the graph is turned off, so disabling it
-- also stops collecting data, not just hides it.
recordCheck = function()
    local wasPostUpdate = checkIsPostUpdate
    checkIsPostUpdate = false
    if cfg("show_activity_graph") ~= true then
        return
    end
    loadHistoryState()
    table.insert(history, { n = total, at = os.time(), afterUpdate = wasPostUpdate })
    local maxLen = math.max(3, math.min(30, tonumber(cfg("activity_history_length")) or 10))
    while #history > maxLen do
        table.remove(history, 1)
    end
    saveHistoryState()
end

-- Marks the check that follows as the one that verifies an update run, so its
-- history entry can say "Updated" instead of just a pending count.
local function recordUpdateRun()
    checkIsPostUpdate = true
    if cfg("show_activity_graph") ~= true then
        return
    end
    loadHistoryState()
    lastUpdateAt = os.time()
    saveHistoryState()
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
    if cfg("check_arch_news") ~= true then
        return
    end
    loadNewsState()
    local ok = noctalia.http({ url = NEWS_URL }, function(res)
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
        noctalia.log("arch-updater: could not start the Arch news request")
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
    noctalia.runAsync("xdg-open " .. shellQuote(NEWS_PAGE) .. " >/dev/null 2>&1")
end

-- ── Updating ─────────────────────────────────────────────────────────────────

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

-- Builds the update command from the AUR helper, ignore list and Flatpak
-- settings. "update_cmd" overrides it outright, for cases the built default
-- doesn't cover.
local function buildUpdateCommand()
    local override = trim(cfg("update_cmd"))
    if override ~= "" then
        updateProcessName = "pacman"
        return override
    end

    local ignored = ignoreList()
    local ignoreFlag = #ignored > 0 and (" --ignore " .. table.concat(ignored, ",")) or ""
    local yesFlag = cfg("assume_yes") == true and " --noconfirm" or ""

    local helper = resolveAurHelper()
    local parts = {}
    if helper ~= nil and helper ~= "custom" and noctalia.commandExists(helper) then
        table.insert(parts, helper .. " -Syu" .. yesFlag .. ignoreFlag)
        updateProcessName = helper
    else
        table.insert(parts, "sudo pacman -Syu" .. yesFlag .. ignoreFlag)
        updateProcessName = "pacman"
    end

    if cfg("flatpak_enabled") == true and noctalia.commandExists("flatpak") then
        local flatpakYes = cfg("assume_yes") == true and " -y" or ""
        if #ignored > 0 then
            -- Same ignore list as pacman/AUR: filter ignored refs out of the
            -- pending Flatpak list before updating, so an app hidden from the
            -- panel's count can't still slip in through a bare `flatpak update`.
            local skipList = shellQuote(table.concat(ignored, "\n"))
            table.insert(
                parts,
                "flatpak_refs=$(flatpak remote-ls --updates --columns=application 2>/dev/null | awk -v ignore="
                    .. skipList
                    .. [=[ 'BEGIN { n = split(ignore, arr, "\n"); for (i = 1; i <= n; i++) skip[arr[i]] = 1 } !($0 in skip)'); ]=]
                    .. [[if [ -n "$flatpak_refs" ]; then flatpak update]]
                    .. flatpakYes
                    .. [[ $flatpak_refs; fi]]
            )
        else
            table.insert(parts, "flatpak update" .. flatpakYes)
        end
    end

    table.insert(parts, "echo; echo " .. shellQuote(tr("run.press_key")) .. "; read -n 1")
    return table.concat(parts, "; ")
end

local function runUpdate()
    if phase == "running" or phase == "checking" then
        return
    end
    if not noctalia.commandExists("checkupdates") then
        phase = "missing"
        errMsg = tr("err_no_checkupdates")
        publish()
        return
    end
    if not launchTerminal(buildUpdateCommand()) then
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

-- Polls for the update process. Seeing it then losing it means the run
-- ended, and triggers a re-check. Never seeing it within the grace period
-- re-checks anyway instead of sitting in "running" forever.
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
            recordUpdateRun()
            startCheck()
        end
    end, updateProcessName)
end

-- ── Requests, lifecycle ──────────────────────────────────────────────────────

local function handle(action)
    if action == "check" then
        -- Also works as a manual unstick: if the process-poll heuristic in
        -- pollRun() ever misses the update finishing, this forces a re-check
        -- instead of leaving the UI stuck on "running".
        startCheck()
    elseif action == "update" then
        runUpdate()
    elseif action == "dismiss" then
        sources.pacman = { n = 0, items = {} }
        sources.aur = { n = 0, items = {}, helper = sources.aur.helper }
        sources.flatpak = { n = 0, items = {} }
        total = 0
        downloadSizeMiB = nil
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
    handle(value.action)
end)

-- Scriptable control:
--   noctalia msg plugin yuuto/arch-updater:service all check
--   noctalia msg plugin yuuto/arch-updater:service all update
--   noctalia msg plugin yuuto/arch-updater:service all dismiss
function onIpc(event, _payload)
    handle(event)
end

function update()
    if phase == "running" then
        runTicks += 1
        pollRun()
    elseif phase ~= "checking" then
        local hours = tonumber(cfg("auto_check_hours")) or 0
        if hours > 0 then
            if phase == "idle" then
                startupTicks += 1
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
        if sinceNewsCheck >= NEWS_RECHECK_HOURS * 3600 or sinceNewsCheck == AUTO_CHECK_DELAY then
            sinceNewsCheck = 0
            checkNews()
        end
    end

    if newsDirty then
        newsDirty = false
        publish()
    end
end

noctalia.setUpdateInterval(1000)
if not noctalia.commandExists("checkupdates") then
    phase = "missing"
    errMsg = tr("err_no_checkupdates")
end
loadHistoryState() -- so the graph shows prior sessions' data before the first check runs
publish()
