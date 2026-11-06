--!nonstrict
-- Arch Audit singleton engine.
--
-- The service owns every side effect: it runs `arch-audit --json`, asks pacman
-- for the installed versions of the affected packages, normalises the result,
-- persists a snapshot, and publishes shared state for the widget and panel.
--
--   state    "arch_audit_state"   = {
--     phase, total, counts, items, severity, checkedAtMs, newCount,
--     ignoredCount, binaryMissing, err
--   }
--   requests "arch_audit_request" = { nonce, action }  -- check
--
-- Design constraints:
--   * read-only: no root, no package manager mutations, no downloads except
--     the JSON that arch-audit itself fetches from security.archlinux.org;
--   * the tracker payload is parsed by arch-audit, so Luau only ever handles
--     the small array of advisories relevant to this machine;
--   * the last successful snapshot is cached in pluginDataDir so a shell
--     restart shows results immediately instead of hitting the network.

local audit = require("./lib/audit.luau")

local STATE_KEY = "arch_audit_state"
local REQUEST_KEY = "arch_audit_request"

local SNAPSHOT_FILE = "snapshot.json"
local SNAPSHOT_VERSION = 1

local CHECK_TIMEOUT_MS = 60000
local PACMAN_TIMEOUT_MS = 15000
local RETRY_SECONDS = 15 * 60
local BINARY_RECHECK_SECONDS = 10 * 60
local STARTUP_DELAY_SECONDS = 10
local DUE_TICKS = 2
local MAX_QUERY_PACKAGES = 250
local MAX_ERROR_CHARS = 180
local DEFAULT_HOURS = 6

local phase = "idle"
local items = {}
local counts = audit.severity_counts()
local total = 0
local checked_at_ms = nil
local new_count = 0
local ignored_count = 0
local binary_missing = false
local err_msg = nil
local checking = false

local cached_raw = nil
local cached_installed = {}

local initialized = false
local seen = {}

local loaded_at = os.time()
local binary_recheck_at = loaded_at + BINARY_RECHECK_SECONDS
local retry_after = nil
local due_ticks = 0
local last_request_nonce = 0

local function tr(key, subst)
    return noctalia.tr(key, subst)
end

local function cfg(key)
    return noctalia.getConfig(key)
end

local function trim(value)
    return noctalia.string.trim(tostring(value or ""))
end

local function snapshot_path()
    local dir = noctalia.pluginDataDir()
    if dir == nil then
        return nil
    end
    return dir .. "/" .. SNAPSHOT_FILE
end

local function publish()
    local pkgset = {}
    for i = 1, #items do
        local pkgs = items[i].packages
        if type(pkgs) == "table" then
            for j = 1, #pkgs do
                local nm = pkgs[j]
                if type(nm) == "string" and nm ~= "" then
                    pkgset[nm] = true
                end
            end
        end
    end
    local pkgcount = 0
    for _ in pairs(pkgset) do
        pkgcount = pkgcount + 1
    end
    noctalia.state.set(STATE_KEY, {
        phase = phase,
        total = total,
        packageCount = pkgcount,
        counts = counts,
        items = items,
        severity = audit.max_severity(counts),
        checkedAtMs = checked_at_ms,
        newCount = new_count,
        ignoredCount = ignored_count,
        binaryMissing = binary_missing,
        err = err_msg,
    })
end

local function resolve_phase()
    if checking then
        phase = "checking"
    elseif binary_missing and total == 0 then
        phase = "missing"
    elseif err_msg ~= nil and total == 0 then
        phase = "error"
    elseif total > 0 then
        phase = "ready"
    elseif checked_at_ms ~= nil then
        phase = "clean"
    else
        phase = "idle"
    end
end

-- Recomputes the displayed items from the cached tracker payload. Called after
-- a check and whenever the ignore list changes, so settings apply immediately
-- without another network round trip.
local function rebuild(publish_state)
    local normalized = audit.normalize(cached_raw or {}, cached_installed or {})
    local ignored = audit.ignore_set(cfg("ignore_packages"))
    local filtered = audit.apply_ignore(normalized.items, ignored)

    items = filtered.items
    counts = filtered.counts
    total = filtered.total
    ignored_count = filtered.dropped

    resolve_phase()
    if publish_state ~= false then
        publish()
    end
end

local function save_snapshot()
    local path = snapshot_path()
    if path == nil then
        return
    end

    local encoded = noctalia.json.encode({
        version = SNAPSHOT_VERSION,
        checkedAtMs = checked_at_ms,
        raw = cached_raw,
        installed = cached_installed,
        seen = seen,
        initialized = initialized,
    })
    if encoded == nil then
        noctalia.log("arch-audit: could not encode snapshot")
        return
    end

    local ok, write_err = noctalia.writeFile(path, encoded)
    if not ok then
        noctalia.log("arch-audit: could not write snapshot: " .. tostring(write_err))
    end
end

local function load_snapshot()
    local path = snapshot_path()
    if path == nil then
        return
    end

    local raw = noctalia.readFile(path)
    if raw == nil or raw == "" then
        return
    end

    local data = noctalia.json.decode(raw)
    if type(data) ~= "table" or data.version ~= SNAPSHOT_VERSION then
        return
    end
    if type(data.raw) ~= "table" or type(data.installed) ~= "table" then
        return
    end

    cached_raw = data.raw
    cached_installed = data.installed
    checked_at_ms = tonumber(data.checkedAtMs)
    initialized = data.initialized == true

    seen = {}
    if type(data.seen) == "table" then
        for id, value in pairs(data.seen) do
            if type(id) == "string" and value == true then
                seen[id] = true
            end
        end
    end

    rebuild(false)
end

local function fail(message)
    checking = false
    err_msg = message
    retry_after = os.time() + RETRY_SECONDS
    resolve_phase()
    publish()
    noctalia.log("arch-audit: " .. message)
end

local function notify_new_advisories(fresh)
    if #fresh == 0 or cfg("notify_new") == false then
        return
    end

    local threshold = audit.rank(cfg("notify_min_severity") or "high")
    local notifiable = {}
    for _, item in ipairs(fresh) do
        if audit.rank(item.severity) >= threshold then
            table.insert(notifiable, item)
        end
    end
    if #notifiable == 0 then
        return
    end

    local packages = {}
    local package_seen = {}
    for _, item in ipairs(notifiable) do
        for _, name in ipairs(item.packages) do
            if not package_seen[name] then
                package_seen[name] = true
                table.insert(packages, name)
            end
        end
    end
    table.sort(packages)

    local shown = {}
    for index = 1, math.min(#packages, 3) do
        shown[index] = packages[index]
    end
    local packages_text = tr("notify.some_packages")
    if #shown > 0 then
        packages_text = table.concat(shown, ", ")
        if #packages > #shown then
            packages_text = packages_text .. " +" .. (#packages - #shown)
        end
    end

    noctalia.notify(
        tr("notify.title"),
        noctalia.trp("notify.body", #notifiable, { packages = packages_text })
    )
end

local function complete_check(raw, installed)
    local normalized = audit.normalize(raw, installed)
    local fresh = {}
    if initialized then
        fresh = audit.new_items(normalized.items, seen)
    end

    -- The seen set covers advisories before the ignore filter, so ignoring a
    -- package and later un-ignoring it does not look like a brand new finding.
    seen = audit.ids(normalized.items)
    initialized = true
    cached_raw = raw
    cached_installed = installed
    checked_at_ms = os.time() * 1000
    binary_missing = false
    checking = false
    err_msg = nil
    retry_after = nil
    new_count = #fresh

    rebuild(false)
    notify_new_advisories(fresh)
    save_snapshot()
    publish()
end

local function load_installed(names, on_done)
    if #names == 0 then
        on_done({})
        return
    end

    local argv = { "pacman", "-Q" }
    for index = 1, math.min(#names, MAX_QUERY_PACKAGES) do
        argv[#argv + 1] = names[index]
    end

    local started = noctalia.runAsync(argv, function(result)
        local installed = {}
        if type(result) == "table" and not result.timedOut then
            installed = audit.parse_installed(result.stdout)
        end
        on_done(installed)
    end, PACMAN_TIMEOUT_MS)

    if not started then
        on_done({})
    end
end

local function finish_check(result)
    if type(result) ~= "table" then
        fail(tr("service.error.launch"))
        return
    end

    if result.timedOut then
        fail(tr("service.error.timeout"))
        return
    end

    if result.exitCode ~= 0 then
        local detail = trim(result.stderr)
        if detail == "" then
            detail = trim(result.stdout)
        end
        if #detail > MAX_ERROR_CHARS then
            detail = detail:sub(1, MAX_ERROR_CHARS - 3) .. "..."
        end
        if detail == "" then
            fail(tr("service.error.exit", { detail = tr("service.error.no_detail") }))
        else
            fail(tr("service.error.exit", { detail = detail }))
        end
        return
    end

    local raw = noctalia.json.decode(tostring(result.stdout or ""))
    if type(raw) ~= "table" then
        fail(tr("service.error.json"))
        return
    end

    local wanted = {}
    local wanted_seen = {}
    for _, entry in ipairs(raw) do
        if type(entry) == "table" and type(entry.packages) == "table" then
            for _, name in ipairs(entry.packages) do
                if type(name) == "string" and name ~= "" and not wanted_seen[name] then
                    wanted_seen[name] = true
                    table.insert(wanted, name)
                end
            end
        end
    end

    load_installed(wanted, function(installed)
        complete_check(raw, installed)
    end)
end

local function start_check()
    if checking then
        return
    end

    new_count = 0
    err_msg = nil
    retry_after = nil
    checking = true
    binary_missing = not noctalia.commandExists("arch-audit")
    resolve_phase()
    publish()

    if binary_missing then
        checking = false
        err_msg = tr("service.error.missing")
        binary_recheck_at = os.time() + BINARY_RECHECK_SECONDS
        resolve_phase()
        publish()
        return
    end

    local started = noctalia.runAsync({ "arch-audit", "--json" }, function(result)
        finish_check(result)
    end, CHECK_TIMEOUT_MS)

    if not started then
        checking = false
        err_msg = tr("service.error.launch")
        retry_after = os.time() + RETRY_SECONDS
        resolve_phase()
        publish()
    end
end

function update()
    if checking then
        return
    end

    local now = os.time()

    -- Recover automatically if the user installs arch-audit after the plugin
    -- started. Right-clicking the widget or running the IPC command is faster.
    if binary_missing then
        if now >= binary_recheck_at then
            binary_recheck_at = now + BINARY_RECHECK_SECONDS
            if noctalia.commandExists("arch-audit") then
                binary_missing = false
                err_msg = nil
                resolve_phase()
                publish()
                start_check()
            end
        end
        return
    end

    if retry_after ~= nil and now < retry_after then
        return
    end

    local hours = tonumber(cfg("check_hours")) or DEFAULT_HOURS
    if hours <= 0 then
        return
    end

    local due
    if checked_at_ms ~= nil then
        due = math.floor(checked_at_ms / 1000) + hours * 3600
    else
        due = loaded_at + STARTUP_DELAY_SECONDS
    end

    if now >= due then
        due_ticks = due_ticks + 1
        if due_ticks >= DUE_TICKS then
            due_ticks = 0
            start_check()
        end
    else
        due_ticks = 0
    end
end

function onConfigChanged()
    rebuild()
end

function onIpc(event, payload)
    local action = tostring(event or "")
    if action == "check" or action == "refresh" then
        start_check()
    elseif action == "open-settings" then
        noctalia.openSettings()
    end
end

noctalia.state.watch(REQUEST_KEY, function(value)
    if type(value) ~= "table" then
        return
    end
    local nonce = tonumber(value.nonce) or 0
    if nonce <= last_request_nonce then
        return
    end
    last_request_nonce = nonce
    if value.action == "check" then
        start_check()
    end
end)

load_snapshot()

if not noctalia.commandExists("arch-audit") then
    binary_missing = true
    if err_msg == nil then
        err_msg = tr("service.error.missing")
    end
end

resolve_phase()
publish()

noctalia.setUpdateInterval(1000)
