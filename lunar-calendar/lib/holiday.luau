--!nonstrict
-- Chinese statutory-holiday data (法定节假日 + 调休上班).
--
-- Source: https://github.com/NateScarlet/holiday-cn (MIT). One small JSON file
-- per year, generated from the State Council's annual holiday notice:
--
--   { "year": 2026, "days": [ { "name": "元旦", "date": "2026-01-01",
--                              "isOffDay": true }, ... ] }
--
-- `isOffDay = true`  -> a day off (放假)
-- `isOffDay = false` -> a make-up working day (调休上班)
--
-- The file is cached in the plugin data directory, so a machine that has been
-- online once keeps working offline.

local lunar = require("./lunar.luau")

local M = {}

-- The Noctalia host is reached through `host()`, which resolves the `noctalia`
-- global. `set_host` lets the offline test harness inject a stand-in, because
-- Luau's standalone module sandbox does not expose the calling script's globals
-- the way Noctalia's own loader does.
local injected_host

function M.set_host(value)
    injected_host = value
end

local function host()
    return injected_host or noctalia
end

-- Mirrors for the same upstream repository. `auto` tries the CDN first, which
-- is usually reachable from mainland China, then GitHub raw.
local MIRRORS = {
    jsdelivr = "https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/%d.json",
    github = "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/%d.json",
}
M.MIRRORS = MIRRORS

--- Ordered mirror list for a configured source name.
function M.mirrors_for(source)
    if source == "off" then
        return {}
    elseif source == "github" then
        return { MIRRORS.github }
    elseif source == "jsdelivr" then
        return { MIRRORS.jsdelivr }
    end
    -- "auto" and anything unrecognised: CDN first, then GitHub raw.
    return { MIRRORS.jsdelivr, MIRRORS.github }
end

function M.url_for(pattern, year)
    return string.format(pattern, year)
end

local function cache_file(year)
    local dir = host().pluginDataDir()
    if not dir then
        return nil
    end
    return string.format("%s/holiday-%d.json", dir, year)
end

M.cache_file = cache_file

--- Parse one holiday-cn JSON document into `{ ["YYYY-MM-DD"] = { name, off } }`.
---
--- Returns `nil, "empty"` when the document is well formed but carries no days
--- yet - holiday-cn publishes every year's file in advance and fills it in once
--- the State Council announces the schedule, so an empty `days` array means
--- "not announced yet" rather than "something went wrong".
function M.parse(body)
    if type(body) ~= "string" or body == "" then
        return nil, "empty body"
    end
    local root, err = host().json.decode(body)
    if type(root) ~= "table" then
        return nil, err or "invalid JSON"
    end
    if type(root.days) ~= "table" then
        return nil, "no days array"
    end
    local out = {}
    local count = 0
    for _, item in ipairs(root.days) do
        local date = item.date
        if type(date) == "string" and #date == 10 then
            out[date] = {
                name = (type(item.name) == "string" and item.name ~= "") and item.name or "假期",
                off = item.isOffDay == true,
            }
            count = count + 1
        end
    end
    if count == 0 then
        return nil, "empty"
    end
    return out
end

--- Read the cached copy for a year, if present. Returns map, raw.
function M.load_cached(year)
    local path = cache_file(year)
    if not path or not host().fileExists(path) then
        return nil
    end
    local raw = host().readFile(path)
    if not raw then
        return nil
    end
    local days = M.parse(raw)
    return days, raw
end

--- Download one year from the first mirror that answers.
--- `cb(days, detail)` where detail is a table describing how it went.
function M.fetch(source, year, cb)
    local mirrors = M.mirrors_for(source)
    if #mirrors == 0 then
        cb(nil, { reason = "disabled" })
        return
    end
    local index = 0
    local function attempt()
        index = index + 1
        local pattern = mirrors[index]
        if not pattern then
            cb(nil, { reason = "network" })
            return
        end
        local url = M.url_for(pattern, year)
        local accepted = host().http({
            url = url,
            method = "GET",
            follow_redirects = true,
            headers = { "Accept: application/json" },
        }, function(response)
            if response and response.ok and response.status == 200 then
                local days, err = M.parse(response.body)
                if days then
                    local path = cache_file(year)
                    if path then
                        host().writeFile(path, response.body)
                    end
                    cb(days, { reason = "ok", url = url })
                    return
                end
                if err == "empty" then
                    -- Well-formed but not announced yet: another mirror serves
                    -- the same file, so stop here instead of retrying.
                    cb(nil, { reason = "empty", url = url })
                    return
                end
                host().log(string.format("lunar-calendar: %s: bad payload (%s)", url, tostring(err)))
            else
                host().log(string.format(
                    "lunar-calendar: %s: HTTP %s",
                    url,
                    tostring(response and response.status or "?")
                ))
            end
            attempt()
        end)
        if not accepted then
            attempt()
        end
    end
    attempt()
end

--- Delete the cached files for the given years.
function M.clear_cache(years)
    local removed = 0
    for _, year in ipairs(years) do
        local path = cache_file(year)
        if path and host().fileExists(path) then
            if host().removeFile(path) then
                removed = removed + 1
            end
        end
    end
    return removed
end

-- ---------------------------------------------------------------------------
-- Queries over a merged day map
-- ---------------------------------------------------------------------------

local function key_to_days(key)
    local y, m, d = string.match(key, "^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not y then
        return nil
    end
    return lunar.days_from_civil(tonumber(y), tonumber(m), tonumber(d))
end

M.key_to_days = key_to_days

--- Holiday entry for one Gregorian date, or nil.
function M.on(days, year, month, day)
    if type(days) ~= "table" then
        return nil
    end
    return days[string.format("%04d-%02d-%02d", year, month, day)]
end

--- The nearest day off strictly after `from_number`, used for a countdown.
function M.next_off(days, from_number, max_days)
    if type(days) ~= "table" then
        return nil
    end
    max_days = max_days or 400
    local best
    for key, entry in pairs(days) do
        if entry.off then
            local number = key_to_days(key)
            if number and number > from_number then
                local delta = number - from_number
                if delta <= max_days and (not best or delta < best.in_days) then
                    best = { key = key, name = entry.name, in_days = delta, day_number = number }
                end
            end
        end
    end
    return best
end

--- Every day off or make-up work day in a Gregorian month, keyed by day number,
--- as `{ [day] = { name, off } }`. Used to decorate a month grid.
function M.for_month(days, year, month)
    local out = {}
    if type(days) ~= "table" then
        return out
    end
    local total = lunar.days_in_month(year, month)
    for day = 1, total do
        local entry = M.on(days, year, month, day)
        if entry then
            out[day] = entry
        end
    end
    return out
end

return M
