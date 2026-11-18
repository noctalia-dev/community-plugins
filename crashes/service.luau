--!nonstrict
-- Crashes engine. Polls systemd-coredump (coredumpctl --json=short) on a
-- timer, keeps the recent-crash list as shared state, notifies about new
-- crashes of this user's processes, and owns the persisted files (last seen
-- timestamp, per-program mutes). The panel is a pure renderer that talks
-- back through "crashes_request".
--
--   state    "crashes_state"   = { nonce, crashes, mutes, journal, checkedAt, err }
--                                -- crashes: newest first: { pid, timeUsec,
--                                --   timeLabel, sigName, exe, name, core,
--                                --   muted }
--                                -- journal: { level, entries } -- newest first:
--                                --   { prio, prioName, name, timeLabel, msg }
--   requests "crashes_request" = { nonce, action, name, level }
--                                -- refresh|mute|unmute|journal
--
-- CPU budget care (25 ms per tick): listing and filtering happen in
-- jq/coredumpctl outside the runtime; the callback parses at most MAX_ROWS
-- short TSV lines. Notifications are fire-and-forget notify-send (no
-- blocking actions) — diagnosis lives in the panel.

local STATE_KEY = "crashes_state"
local REQUEST_KEY = "crashes_request"

local MAX_ROWS = 30
local NOTIFY_DEDUPE_SECONDS = 60
local STARTUP_DELAY_TICKS = 10 -- let the shell settle first

local SIG_NAMES = {
    [1] = "SIGHUP", [2] = "SIGINT", [3] = "SIGQUIT", [4] = "SIGILL",
    [5] = "SIGTRAP", [6] = "SIGABRT", [7] = "SIGBUS", [8] = "SIGFPE",
    [11] = "SIGSEGV", [13] = "SIGPIPE", [24] = "SIGXCPU", [25] = "SIGXFSZ",
    [31] = "SIGSYS",
}

-- syslog/journald priorities (see syslog(3)); the panel offers 0..3.
local PRIO_NAMES = {
    [0] = "EMERG", [1] = "ALERT", [2] = "CRIT", [3] = "ERR",
    [4] = "WARN", [5] = "NOTICE", [6] = "INFO", [7] = "DEBUG",
}

local myUid = nil -- resolved once via the shell; polling waits for it

local crashes = {}
local journal = nil -- { level, entries }; filled on the panel's request
local journalPolling = false
local mutes = {} -- name -> true
local checkedAt = ""
local errMsg = nil
local stateNonce = 0
local lastRequestNonce = 0

local polling = false
local sincePoll = 0
local startupTicks = 0
local started = false

-- Only the newest crash already announced (or present before the first
-- poll) — everything newer than this notifies. Persisted so a shell restart
-- does not re-announce old crashes.
local seenUsec = 0
local seenLoaded = false

local lastNotified = {} -- name -> epoch seconds

local function cfg(key, fallback)
    -- getConfig returns nil until the setting is materialized in
    -- settings.toml; the manifest default is NOT substituted by the runtime.
    -- An empty string is a real value (an intentionally empty terminal_cmd).
    local value = noctalia.getConfig(key)
    if value == nil then
        return fallback
    end
    return value
end

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function dataPath(file)
    local dir = noctalia.pluginDataDir()
    if dir == nil then
        return nil
    end
    return dir .. "/" .. file
end

local function publish()
    stateNonce += 1
    noctalia.state.set(STATE_KEY, {
        nonce = stateNonce,
        crashes = crashes,
        mutes = mutes,
        journal = journal,
        checkedAt = checkedAt,
        err = errMsg,
    })
end

-- ── Persisted files ─────────────────────────────────────────────────────────

local function loadPersisted()
    local path = dataPath("seen.json")
    if path ~= nil and noctalia.fileExists(path) then
        local ok, parsed = pcall(noctalia.json.decode, noctalia.readFile(path))
        if ok and type(parsed) == "table" then
            seenUsec = tonumber(parsed.seenUsec) or 0
        end
    end
    local mpath = dataPath("mutes.json")
    if mpath ~= nil and noctalia.fileExists(mpath) then
        local ok, parsed = pcall(noctalia.json.decode, noctalia.readFile(mpath))
        if ok and type(parsed) == "table" then
            mutes = parsed
        end
    end
    seenLoaded = true
end

local function saveSeen()
    local path = dataPath("seen.json")
    if path ~= nil then
        noctalia.writeFile(path, noctalia.json.encode({ seenUsec = seenUsec }))
    end
end

local function saveMutes()
    local path = dataPath("mutes.json")
    if path ~= nil then
        noctalia.writeFile(path, noctalia.json.encode(mutes))
    end
end

-- ── Polling ─────────────────────────────────────────────────────────────────

local function notifyNew(entry)
    if cfg("notify", true) ~= true then
        return
    end
    local now = os.time()
    if (now - (lastNotified[entry.name] or 0)) < NOTIFY_DEDUPE_SECONDS then
        return
    end
    lastNotified[entry.name] = now
    -- Fire-and-forget: no blocking action button; the panel is the
    -- diagnosis surface. Crash details ride as discrete argv words.
    noctalia.runAsync("notify-send --urgency critical --app-name crashes "
        .. shellQuote(tr("notify_title", { name = entry.name })) .. " "
        .. shellQuote(tr("notify_body", { signal = entry.sigName, pid = entry.pid })), function() end)
end

local function poll()
    if polling or myUid == nil then
        return
    end
    polling = true
    errMsg = nil

    -- jq keeps only this user's newest rows and emits short TSV; everything
    -- heavy stays outside the runtime.
    local cmd = "coredumpctl list --json=short --no-pager 2>/dev/null | jq -r --argjson uid " .. myUid
        .. " '[.[] | select(.uid == $uid)][-" .. MAX_ROWS .. ":][] "
        .. "| [.time, .pid, .sig, (.corefile // \"-\"), (.exe // \"-\")] | @tsv'"

    noctalia.runAsync(cmd, function(result)
        polling = false
        if result.timedOut or (result.exitCode or 1) ~= 0 then
            -- No coredumps at all also exits non-zero; treat empty output
            -- as an empty list rather than an error.
            if (result.stdout or "") ~= "" and result.timedOut then
                errMsg = tr("err_poll")
            end
        end

        local list = {}
        local newestUsec = seenUsec
        for line in (result.stdout or ""):gmatch("[^\n]+") do
            local timeUsec, pid, sig, core, exe = line:match("^(%d+)\t(%d+)\t(%d+)\t([^\t]*)\t([^\t]*)$")
            if timeUsec ~= nil then
                timeUsec = tonumber(timeUsec)
                local name = exe:match("([^/]+)$") or "unknown"
                if name == "" or name == "-" or name == "." or name == ".." then
                    name = "unknown"
                end
                local entry = {
                    pid = pid,
                    timeUsec = timeUsec,
                    timeLabel = os.date("%d.%m %H:%M", math.floor(timeUsec / 1000000)),
                    sigName = SIG_NAMES[tonumber(sig)] or ("signal " .. sig),
                    exe = exe,
                    name = name,
                    core = core == "present",
                    muted = mutes[name] == true,
                }
                -- Newest first for the panel.
                table.insert(list, 1, entry)
                if timeUsec > seenUsec and mutes[name] ~= true then
                    notifyNew(entry)
                end
                if timeUsec > newestUsec then
                    newestUsec = timeUsec
                end
            end
        end

        crashes = list
        if newestUsec > seenUsec then
            seenUsec = newestUsec
            saveSeen()
        end
        checkedAt = os.date("%H:%M:%S")
        publish()
    end)
end

-- Journal errors from the current boot at `level` and stricter (0=emerg..3=err).
-- Only on request: polling the journal continuously would be noise and
-- background work nobody asked for.
local function pollJournal(level)
    if journalPolling then
        return
    end
    journalPolling = true
    level = math.max(0, math.min(3, tonumber(level) or 3))

    -- @tsv escapes tabs and newlines inside MESSAGE; the gsub flattens them
    -- first so every row stays a single short line.
    local cmd = "journalctl -b -p " .. level .. " -n 40 -o json --no-pager 2>/dev/null | jq -r "
        .. shellQuote('[(.PRIORITY // "-"), ((.SYSLOG_IDENTIFIER // ._COMM // "-") | tostring),'
            .. ' (.__REALTIME_TIMESTAMP // "0"),'
            .. ' ((.MESSAGE // "") | tostring | gsub("[\\n\\t]"; " ") | .[0:200])] | @tsv')

    noctalia.runAsync(cmd, function(result)
        journalPolling = false
        local entries = {}
        for line in (result.stdout or ""):gmatch("[^\n]+") do
            local prio, name, timeUsec, msg = line:match("^([^\t]*)\t([^\t]*)\t(%d+)\t(.*)$")
            if prio ~= nil then
                -- Newest first.
                local secs = math.floor((tonumber(timeUsec) or 0) / 1000000)
                table.insert(entries, 1, {
                    prio = tonumber(prio) or 7,
                    prioName = PRIO_NAMES[tonumber(prio)] or ("P" .. prio),
                    name = name ~= "" and name or "-",
                    timeLabel = os.date("%d.%m %H:%M", secs),
                    -- Exact timestamp, for journalctl --since/--until in a diagnosis.
                    timeIso = os.date("%Y-%m-%d %H:%M:%S", secs),
                    msg = msg,
                })
            end
        end
        journal = { level = level, entries = entries }
        publish()
    end)
end

-- ── Requests from the panel ─────────────────────────────────────────────────

local function handleRequest(request)
    if type(request) ~= "table" then
        return
    end
    local nonce = tonumber(request.nonce) or 0
    if nonce <= lastRequestNonce then
        return
    end
    lastRequestNonce = nonce

    local action = request.action
    if action == "refresh" then
        poll()
    elseif action == "journal" then
        pollJournal(request.level)
    elseif action == "mute" and type(request.name) == "string" and request.name ~= "" then
        mutes[request.name] = true
        saveMutes()
        for _, entry in ipairs(crashes) do
            if entry.name == request.name then
                entry.muted = true
            end
        end
        publish()
    elseif action == "unmute" and type(request.name) == "string" then
        mutes[request.name] = nil
        saveMutes()
        for _, entry in ipairs(crashes) do
            if entry.name == request.name then
                entry.muted = false
            end
        end
        publish()
    end
end

noctalia.state.watch(REQUEST_KEY, handleRequest)

-- ── Tick ────────────────────────────────────────────────────────────────────

function update()
    if not started then
        startupTicks += 1
        if startupTicks < STARTUP_DELAY_TICKS then
            return
        end
        started = true
        loadPersisted()
        -- The uid gates everything: crashes of other users are the
        -- sysadmin's problem, not a desktop notification.
        noctalia.runAsync("id -u", function(result)
            local uid = tonumber((result.stdout or ""):match("%d+"))
            if uid ~= nil then
                myUid = uid
                poll()
            else
                errMsg = tr("err_uid")
                publish()
            end
        end)
        return
    end

    sincePoll += 1
    local every = tonumber(cfg("poll_seconds", 20)) or 20
    if sincePoll >= every then
        sincePoll = 0
        poll()
    end
end
