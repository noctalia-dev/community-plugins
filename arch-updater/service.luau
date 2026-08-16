--!nonstrict
-- arch-updater singleton engine. Checks pacman, the AUR helper and Flatpak,
-- publishes the result as shared state, and runs the update in the
-- BACKGROUND: one click, pkexec (polkit) asks for the password, the run is
-- fully non-interactive (--noconfirm and friends) and its log streams into
-- the panel.
--
--   state    "arch_state"   = { nonce, phase, step, total, pacman, aur,
--                                flatpak, downloadSizeMiB, rebootRecommended,
--                                newsUnread, newsLatestTitle, err, checkedAt,
--                                ignoredCount, ignoredPending, ignoredDynamic,
--                                ignoredConfig, logTail, logPath, runExit,
--                                progress = { done, total } }
--   requests "arch_request" = { nonce, action, pkg }
--                              -- check|update|update_terminal|dismiss|open_news
--                              -- |ignore|unignore (pkg = package name)
--
-- The update run is spawned fully detached (double-fork + setsid), writing to
-- <plugin data dir>/update.log; it survives a shell restart. The engine polls
-- the log every RUN_POLL_SECONDS with `tail` and finishes when the runner's
-- "::EXIT <code>" marker appears. If a run cannot proceed non-interactively
-- it exits non-zero without touching the system, and the panel offers a
-- terminal fallback ("update_terminal") where prompts work normally.

local STATE_KEY = "arch_state"
local REQUEST_KEY = "arch_request"
local NEWS_FILE = "news_state.json"
local IGNORE_FILE = "ignore.json"
local NEWS_URL = "https://archlinux.org/feeds/news/"
local NEWS_PAGE = "https://archlinux.org/news/"
local LOG_FILE = "update.log"
local POLKIT_RULE_NAME = "49-arch-updater-pacman.rules"
local POLKIT_RULE_PATH = "/etc/polkit-1/rules.d/49-arch-updater-pacman.rules"

local CHECK_TIMEOUT_MS = 45000 -- pacman/AUR/flatpak checks: each may sync a mirror
local SIZE_TIMEOUT_MS = 20000 -- pacman -Si: local db, no mirror sync
local FAST_TIMEOUT_MS = 5000 -- log tail / reboot check: local filesystem only
local NEWS_RECHECK_HOURS = 6
local RUN_POLL_SECONDS = 2
local RUN_STALE_LIMIT_S = 1800 -- no log growth for this long = the run is stuck
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
local sinceNewsCheck = 0
local newsStateLoaded = false
local newsDirty = false
local ignoredPending = {} -- ignored packages that had a pending update in the last check
local dynamicIgnore = nil -- panel-managed ignore list, persisted in IGNORE_FILE
local polkitRuleInstalled = nil -- nil until the async check ran, then boolean
local polkitInstallBusy = false

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

local function logPath()
    local dir, err = noctalia.pluginDataDir()
    if dir == nil then
        noctalia.log("arch-updater: cannot resolve plugin data dir: " .. tostring(err))
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

-- Two plugin-side ignore sources: the "ignore_packages" setting and a
-- panel-managed list in IGNORE_FILE (the panel cannot write settings).
-- pacman.conf's IgnorePkg arrives from the checkers as "[ignored]" lines
-- and is displayed only, never managed here.
local function ignorePath()
    local dir, err = noctalia.pluginDataDir()
    if dir == nil then
        noctalia.log("arch-updater: cannot resolve plugin data dir: " .. tostring(err))
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
            if validName(name) then
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
        if validName(name) then
            table.insert(names, name)
        elseif name ~= "" then
            noctalia.log("arch-updater: ignoring invalid package name '" .. name .. "'")
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

-- ── Parsing ──────────────────────────────────────────────────────────────────

-- One "name oldver -> newver" line per package: checkupdates' format, which
-- yay -Qua and paru -Qua also use. A trailing "[ignored]" is pacman.conf's
-- IgnorePkg: the run skips those, so they go to ignoredPending instead of
-- the pending count.
local function parseVersionLines(output, ignored)
    local items = {}
    local n = 0
    for line in (output or ""):gmatch("[^\n]+") do
        local parts = {}
        for token in line:gmatch("%S+") do
            table.insert(parts, token)
        end
        if #parts >= 4 then
            local name, from, to = parts[1], parts[2], parts[4]
            if parts[#parts] == "[ignored]" then
                table.insert(ignoredPending, { name = name, from = from, to = to, source = "system" })
            elseif ignored[name] then
                table.insert(ignoredPending, { name = name, from = from, to = to, source = "plugin" })
            else
                n += 1
                if #items < MAX_LISTED then
                    table.insert(items, { name = name, from = from, to = to })
                end
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
        if name ~= "" then
            if ignored[name] then
                table.insert(ignoredPending, { name = name, from = fields[2] or "", to = fields[3] or "", source = "plugin" })
            else
                n += 1
                if #items < MAX_LISTED then
                    table.insert(items, { name = name, from = fields[2] or "", to = fields[3] or "" })
                end
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
        ignoredPending = ignoredPending,
        ignoredDynamic = dynamicIgnore or {},
        ignoredConfig = configIgnoreList(),
        polkitRule = polkitRuleInstalled,
        flatpakEnabled = cfg("flatpak_enabled") == true and noctalia.commandExists("flatpak"),
        logTail = logTail,
        logPath = logPath(),
        runExit = runExit,
        progress = { done = runDone, total = runTotal },
    })
end

-- ── Checking pipeline: pacman → AUR → Flatpak → size → reboot → done ────────

local checkFlatpak
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
    if phase == "checking" or phase == "running" then
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
    ignoredPending = {}
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

-- ── Polkit rule ──────────────────────────────────────────────────────────────

-- Without this rule pkexec re-authenticates every pacman transaction of a
-- run (db sync + each install batch = several password dialogs); with it
-- one password covers the whole run. Embedded because the plugin's own
-- directory is not exposed to Lua; keep in sync with polkit/*.rules.
local POLKIT_RULE = [=[/* Installed by the arch-updater Noctalia plugin (one password per update
 * run instead of one per pacman transaction). Authentication is kept for
 * ~5 minutes, like sudo's timestamp. Scope: only pkexec launching
 * /usr/bin/pacman, only for an active local session of a wheel member.
 * Remove: sudo rm /etc/polkit-1/rules.d/49-arch-updater-pacman.rules
 */
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec" &&
        action.lookup("program") == "/usr/bin/pacman" &&
        subject.active && subject.local &&
        subject.isInGroup("wheel")) {
        return polkit.Result.AUTH_ADMIN_KEEP;
    }
});
]=]

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
    if polkitInstallBusy or not noctalia.commandExists("pkexec") then
        return
    end
    local dir = noctalia.pluginDataDir()
    if dir == nil then
        return
    end
    local staged = dir .. "/" .. POLKIT_RULE_NAME
    noctalia.writeFile(staged, POLKIT_RULE)
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
local function buildBackgroundCommand()
    local override = trim(cfg("update_cmd"))
    if override ~= "" then
        return override
    end

    local ignored = ignoreList()
    local ignoreFlag = #ignored > 0 and (" --ignore " .. table.concat(ignored, ",")) or ""
    local quietFlags = " --noconfirm --noprogressbar --color never"

    local helper = resolveAurHelper()
    local parts = {}
    if helper ~= nil and helper ~= "custom" and noctalia.commandExists(helper) then
        local autoAnswers = helper == "paru" and " --skipreview"
            or " --answerdiff None --answerclean None --answeredit None"
        table.insert(parts, helper .. " -Syu --sudo pkexec" .. autoAnswers .. quietFlags .. ignoreFlag)
    else
        table.insert(parts, "pkexec pacman -Syu" .. quietFlags .. ignoreFlag)
    end

    if cfg("flatpak_enabled") == true and noctalia.commandExists("flatpak") then
        if #ignored > 0 then
            -- Same ignore list as pacman/AUR: filter ignored refs out of the
            -- pending Flatpak list before updating, so an app hidden from the
            -- panel's count can't still slip in through a bare `flatpak update`.
            local skipList = shellQuote(table.concat(ignored, "\n"))
            table.insert(
                parts,
                "{ flatpak_refs=$(flatpak remote-ls --updates --columns=application 2>/dev/null | awk -v ignore="
                    .. skipList
                    .. [=[ 'BEGIN { n = split(ignore, arr, "\n"); for (i = 1; i <= n; i++) skip[arr[i]] = 1 } !($0 in skip)'); ]=]
                    .. [[if [ -n "$flatpak_refs" ]; then flatpak update -y --noninteractive $flatpak_refs; fi; }]]
            )
        else
            table.insert(parts, "flatpak update -y --noninteractive")
        end
    end

    return table.concat(parts, " && ")
end

-- Interactive variant for the terminal fallback: no --noconfirm, prompts and
-- the PKGBUILD review work as usual. Output is tee'd into the same log so the
-- engine still sees the "::EXIT" marker and re-checks when the run ends.
local function buildTerminalCommand()
    local ignored = ignoreList()
    local ignoreFlag = #ignored > 0 and (" --ignore " .. table.concat(ignored, ",")) or ""

    local helper = resolveAurHelper()
    local parts = {}
    if helper ~= nil and helper ~= "custom" and noctalia.commandExists(helper) then
        table.insert(parts, helper .. " -Syu" .. ignoreFlag)
    else
        table.insert(parts, "sudo pacman -Syu" .. ignoreFlag)
    end
    if cfg("flatpak_enabled") == true and noctalia.commandExists("flatpak") then
        table.insert(parts, "flatpak update")
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

local function beginRun()
    phase = "running"
    errMsg = nil
    step = ""
    runExit = nil
    runDone = 0
    runTotal = total
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
    if not noctalia.commandExists("checkupdates") then
        phase = "missing"
        errMsg = tr("err_no_checkupdates")
        publish()
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
        phase = "error"
        errMsg = tr("err_spawn")
        publish()
        return
    end

    -- "::START <epoch>" lets a restarted engine tell a live run from a stale
    -- log; "::EXIT <code>" is the completion marker the poller waits for.
    local quoted = shellQuote(path)
    local script = "printf '::START %s\\n' \"$(date +%s)\" > " .. quoted
        .. "; { " .. buildBackgroundCommand() .. " ; } >> " .. quoted .. " 2>&1"
        .. "; printf '::EXIT %s\\n' \"$?\" >> " .. quoted

    if not noctalia.runAsync(script) then
        phase = "error"
        errMsg = tr("err_spawn")
        publish()
        return
    end
    beginRun()
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
    beginRun()
end

finishRun = function(code)
    runExit = code
    runStaleS = 0
    if code == 0 then
        noctalia.notify(tr("title"), tr("notify_run_ok"))
        phase = "clean"
        publish()
        startCheck() -- verify: phase becomes checking, then clean/ready
    else
        phase = "error"
        errMsg = tr("err_run_failed", { code = tostring(code) })
        publish()
        noctalia.notifyError(tr("title"), errMsg)
    end
end

local function stripAnsi(line)
    return (line:gsub("\27%[[%d;]*[A-Za-z]", ""):gsub("\r", ""))
end

local function isProgressLine(line)
    return line:match("^upgrading ") ~= nil
        or line:match("^installing ") ~= nil
        or line:match("^reinstalling ") ~= nil
        or line:match("^downgrading ") ~= nil
end

-- One `tail` per poll: the last screenful for display plus a full-file
-- progress count, so the bar doesn't reset when early lines scroll out of
-- the tail window.
local function pollRunLog()
    local path = logPath()
    if path == nil then
        return
    end
    local keep = math.max(6, math.min(30, tonumber(cfg("log_lines")) or 14))
    local quoted = shellQuote(path)
    local cmd = "tail -n " .. tostring(keep + 8) .. " " .. quoted .. " 2>/dev/null"
        .. "; printf '::COUNT %s\\n' \"$(grep -cE '^(upgrading|installing|reinstalling|downgrading) ' " .. quoted .. " 2>/dev/null)\""
    local started = noctalia.runAsync(cmd, function(result)
        if phase ~= "running" then
            return
        end
        local text = result.stdout or ""
        if text == lastTailText then
            runStaleS += RUN_POLL_SECONDS
            if runStaleS >= RUN_STALE_LIMIT_S then
                finishRun(-1)
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
        noctalia.log("arch-updater: could not poll the update log")
    end
end

-- A fresh engine (login, shell restart) re-attaches to an unfinished run:
-- the detached updater survives Noctalia, so an update.log with a recent
-- ::START and no ::EXIT means it is still going.
local function resumeRunIfActive()
    local path = logPath()
    if path == nil then
        return
    end
    local quoted = shellQuote(path)
    local cmd = "head -n 1 " .. quoted .. " 2>/dev/null; tail -n 3 " .. quoted .. " 2>/dev/null"
    local started = noctalia.runAsync(cmd, function(result)
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
        beginRun()
    end, FAST_TIMEOUT_MS)
    if not started then
        noctalia.log("arch-updater: could not inspect the update log")
    end
end

-- ── Requests, lifecycle ──────────────────────────────────────────────────────

-- Persists in IGNORE_FILE and takes effect immediately by moving the
-- package out of the current snapshot; n is only decremented when the
-- package was actually listed (entries beyond MAX_LISTED have no name).
local function addIgnore(pkg)
    local name = trim(tostring(pkg or ""))
    if not validName(name) then
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
    for _, entry in ipairs({ sources.pacman, sources.aur, sources.flatpak }) do
        for index, item in ipairs(entry.items or {}) do
            if item.name == name then
                table.remove(entry.items, index)
                entry.n = math.max(0, (entry.n or 0) - 1)
                table.insert(ignoredPending, { name = item.name, from = item.from, to = item.to, source = "plugin" })
                break
            end
        end
    end
    total = sources.pacman.n + sources.aur.n + sources.flatpak.n
    if phase == "ready" and total == 0 then
        phase = "clean"
    end
    publish()
end

-- Only the panel-managed list is editable here; settings entries and
-- pacman.conf's IgnorePkg are managed where they live.
local function removeIgnore(pkg)
    local name = trim(tostring(pkg or ""))
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

local function handle(action, pkg)
    if action == "check" then
        startCheck()
    elseif action == "update" then
        runUpdate()
    elseif action == "update_terminal" then
        runUpdateTerminal()
    elseif action == "ignore" then
        addIgnore(pkg)
    elseif action == "unignore" then
        removeIgnore(pkg)
    elseif action == "polkit_install" then
        installPolkitRule()
    elseif action == "dismiss" then
        sources.pacman = { n = 0, items = {} }
        sources.aur = { n = 0, items = {}, helper = sources.aur.helper }
        sources.flatpak = { n = 0, items = {} }
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
    handle(value.action, value.pkg)
end)

-- Scriptable control:
--   noctalia msg plugin yuuto/arch-updater:service all check
--   noctalia msg plugin yuuto/arch-updater:service all update
--   noctalia msg plugin yuuto/arch-updater:service all update_terminal
--   noctalia msg plugin yuuto/arch-updater:service all dismiss
--   noctalia msg plugin yuuto/arch-updater:service all ignore:NAME
--   noctalia msg plugin yuuto/arch-updater:service all unignore:NAME
function onIpc(event, payload)
    local action, arg = tostring(event):match("^(%w+):(.+)$")
    if action ~= nil then
        handle(action, arg)
    else
        handle(event, payload)
    end
end

function update()
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
if not noctalia.commandExists("checkupdates") then
    phase = "missing"
    errMsg = tr("err_no_checkupdates")
end
publish()
resumeRunIfActive()
checkPolkitRule()
