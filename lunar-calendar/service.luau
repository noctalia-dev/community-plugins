--!nonstrict
-- [[service]] holiday-sync
--
-- Keeps the plugin's statutory-holiday data (中国法定节假日 + 调休) up to date and
-- publishes it on the plugin state channel as "holidays", where the bar widget
-- and the panel both read it:
--
--   { days = { ["2026-10-01"] = { name = "国庆节", off = true }, ... },
--     status = "ok" | "cached" | "offline" | "disabled" | "loading",
--     years = { 2026, 2027 }, updated = <unix seconds>, source = "auto" }
--
-- Strategy: publish the on-disk cache immediately so the UI has data even
-- offline, then refresh from the network in the background. Retries are
-- throttled, and a successful fetch is only repeated every 6 hours.

local holiday = require("./lib/holiday.luau")
local lunar = require("./lib/lunar.luau")

local SOURCE = noctalia.getConfig("holiday_source") or "auto"

local REFRESH_MS = 6 * 60 * 60 * 1000 -- re-check a healthy dataset
local RETRY_MS = 10 * 60 * 1000 -- retry after a failure
local TICK_MS = 5 * 60 * 1000

local days = {} -- merged map across the years we track
local years = {}
local status = "loading"
local last_ok = 0
local last_attempt = 0
local current_year = tonumber(noctalia.formatTime("%Y")) or 1970

local function tracked_years()
    local out = { current_year }
    if current_year + 1 <= lunar.MAX_YEAR then
        out[#out + 1] = current_year + 1
    end
    return out
end

local function publish()
    noctalia.state.set("holidays", {
        days = days,
        status = status,
        years = years,
        updated = os.time(),
        source = SOURCE,
    })
end

--- Seed `days` from the on-disk cache for the tracked years.
local function load_cache()
    local found = 0
    for _, year in ipairs(tracked_years()) do
        local cached = holiday.load_cached(year)
        if cached then
            for key, value in pairs(cached) do
                days[key] = value
            end
            found = found + 1
        end
    end
    return found
end

local function refresh()
    years = tracked_years()
    last_attempt = os.time()
    if #years == 0 then
        status = "disabled"
        publish()
        return
    end
    local remaining = #years
    local any_ok = false
    local any_empty = false
    local any_failed = false
    local disabled = false
    for _, year in ipairs(years) do
        holiday.fetch(SOURCE, year, function(map, detail)
            remaining = remaining - 1
            if map then
                for key, value in pairs(map) do
                    days[key] = value
                end
                any_ok = true
            elseif detail and detail.reason == "disabled" then
                disabled = true
            elseif detail and detail.reason == "empty" then
                -- Online, but the State Council has not announced that year yet.
                any_empty = true
            else
                any_failed = true
            end
            if remaining <= 0 then
                if any_ok then
                    status = "ok"
                    last_ok = os.time()
                elseif disabled then
                    status = "disabled"
                elseif any_empty and not any_failed then
                    status = "nodata"
                else
                    status = next(days) and "cached" or "offline"
                end
                publish()
                noctalia.log(string.format(
                    "lunar-calendar: holiday sync %s (%s, %d days cached)",
                    status,
                    SOURCE,
                    (function()
                        local n = 0
                        for _ in pairs(days) do
                            n = n + 1
                        end
                        return n
                    end)()
                ))
            end
        end)
    end
end

local function tick()
    local year = tonumber(noctalia.formatTime("%Y"))
    if year and year ~= current_year then
        -- Crossed into a new year: pick up its cache and fetch the next one.
        current_year = year
        load_cache()
        refresh()
        return
    end
    local now = os.time()
    if status == "ok" then
        if now - last_ok >= REFRESH_MS / 1000 then
            refresh()
        end
    elseif now - last_attempt >= RETRY_MS / 1000 then
        refresh()
    end
end

-- Initial state: cache first (available offline), network second.
years = tracked_years()
if load_cache() > 0 then
    status = "cached"
end
publish()
refresh()

-- The bar widget asks for a refresh over the state channel; `noctalia msg
-- plugin ... refresh` on the widget reaches this handler.
noctalia.state.watch("holiday-command", function(payload)
    if type(payload) == "table" and payload.action == "refresh" then
        load_cache()
        publish()
        refresh()
    end
end)

noctalia.setUpdateInterval(TICK_MS)
function update()
    tick()
end

function onIpc(event, _payload)
    if event == "refresh" then
        load_cache()
        publish()
        refresh()
    elseif event == "clear-cache" then
        holiday.clear_cache(tracked_years())
        days = {}
        load_cache()
        publish()
        noctalia.notify(noctalia.tr("notify.title"), noctalia.tr("service.cache_cleared"))
    end
end

function onExit(_signal, _reason)
    -- Nothing to release: HTTP requests are owned by the host runtime.
end
