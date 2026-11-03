--!nonstrict
-- Pure data helpers shared by the service, the bar widget and the panel.
--
-- Nothing in this module touches the host API, the filesystem or the network,
-- so tests/audit_test.luau can exercise it without Noctalia running. The only
-- host-independent dependency is os.time() in age(), which is standard Luau.

local M = {}

-- Ordered worst -> best. The order drives sorting, the bar colour and the
-- severity filter, so keep it in sync with the keys used in translations.
M.SEVERITIES = { "critical", "high", "medium", "low", "unknown" }

local SEVERITY_RANK = {
    critical = 5,
    high = 4,
    medium = 3,
    low = 2,
    unknown = 1,
}

local SEVERITY_COLOR = {
    critical = "error",
    high = "error",
    medium = "tertiary",
    low = "primary",
    unknown = "on_surface_variant",
}

-- The command users should run to pick up fixes. Arch does not support
-- partial upgrades, so we never suggest `pacman -S <package>` from the panel.
local UPGRADE_COMMAND = "sudo pacman -Syu"

function M.severity(value)
    local key = tostring(value or ""):lower()
    if SEVERITY_RANK[key] ~= nil then
        return key
    end
    return "unknown"
end

function M.rank(severity)
    return SEVERITY_RANK[M.severity(severity)] or 1
end

function M.severity_color(severity)
    return SEVERITY_COLOR[M.severity(severity)] or "on_surface_variant"
end

function M.severity_counts()
    local counts = {}
    for _, severity in ipairs(M.SEVERITIES) do
        counts[severity] = 0
    end
    return counts
end

-- `pacman -Q pkg...` prints "name version" per line. A missing package makes
-- pacman exit non-zero but still prints every package it did find, so callers
-- parse stdout and ignore the exit code.
function M.parse_installed(stdout)
    local installed = {}
    for line in tostring(stdout or ""):gmatch("[^\r\n]+") do
        local name, version = line:match("^(%S+)%s+(%S+)")
        if name ~= nil and version ~= nil then
            installed[name] = version
        end
    end
    return installed
end

-- Only link to IDs that look like tracker IDs, so a malformed JSON payload can
-- never smuggle an arbitrary URL into xdg-open.
function M.advisory_url(id)
    local name = tostring(id or "")
    if name:match("^[A-Z][A-Z0-9]*%-%d+$") == nil then
        return nil
    end
    return "https://security.archlinux.org/" .. name
end

local function non_empty_string(value)
    return type(value) == "string" and value ~= ""
end

local function string_array(value)
    local out = {}
    if type(value) == "table" then
        for _, entry in ipairs(value) do
            if non_empty_string(entry) then
                table.insert(out, entry)
            end
        end
    end
    return out
end

-- Turns the `arch-audit --json` array into the shape the rest of the plugin
-- uses. Invalid entries are dropped instead of failing the whole check, so a
-- future tracker field change degrades to fewer rows rather than a blank panel.
function M.normalize(raw, installed)
    installed = type(installed) == "table" and installed or {}

    local items = {}
    local seen_ids = {}
    local counts = M.severity_counts()

    if type(raw) ~= "table" then
        return { items = items, counts = counts, total = 0 }
    end

    for _, entry in ipairs(raw) do
        if type(entry) == "table" and non_empty_string(entry.name) and not seen_ids[entry.name] then
            local packages = string_array(entry.packages)
            if #packages > 0 then
                local installed_packages = {}
                for _, name in ipairs(packages) do
                    local version = installed[name]
                    table.insert(installed_packages, {
                        name = name,
                        version = non_empty_string(version) and version or nil,
                    })
                end

                local severity = M.severity(entry.severity)
                local item = {
                    id = entry.name,
                    packages = packages,
                    installed = installed_packages,
                    severity = severity,
                    status = non_empty_string(entry.status) and entry.status or "Unknown",
                    type = non_empty_string(entry.type) and entry.type or "unknown",
                    fixed = non_empty_string(entry.fixed) and entry.fixed or nil,
                    issues = string_array(entry.issues),
                    url = M.advisory_url(entry.name),
                }

                seen_ids[item.id] = true
                table.insert(items, item)
                counts[severity] = counts[severity] + 1
            end
        end
    end

    table.sort(items, function(a, b)
        local rank_a, rank_b = M.rank(a.severity), M.rank(b.severity)
        if rank_a ~= rank_b then
            return rank_a > rank_b
        end
        local name_a = a.packages[1] or a.id
        local name_b = b.packages[1] or b.id
        if name_a ~= name_b then
            return name_a < name_b
        end
        return a.id < b.id
    end)

    return { items = items, counts = counts, total = #items }
end

function M.ignore_set(list)
    local set = {}
    if type(list) == "table" then
        for _, name in ipairs(list) do
            if type(name) == "string" then
                local trimmed = name:gsub("^%s+", ""):gsub("%s+$", "")
                if trimmed ~= "" then
                    set[trimmed] = true
                end
            end
        end
    end
    return set
end

-- Removes ignored packages from each advisory. An advisory only disappears
-- when *every* package it covers is ignored; otherwise the remaining packages
-- still need to be shown.
function M.apply_ignore(items, ignored)
    local kept_items = {}
    local counts = M.severity_counts()
    local dropped = 0

    for _, item in ipairs(items or {}) do
        local packages = {}
        for _, name in ipairs(item.packages or {}) do
            if not ignored[name] then
                table.insert(packages, name)
            end
        end

        if #packages == 0 then
            dropped = dropped + 1
        else
            local installed = {}
            for _, entry in ipairs(item.installed or {}) do
                if not ignored[entry.name] then
                    table.insert(installed, entry)
                end
            end
            table.insert(kept_items, {
                id = item.id,
                packages = packages,
                installed = installed,
                severity = item.severity,
                status = item.status,
                type = item.type,
                fixed = item.fixed,
                issues = item.issues,
                url = item.url,
            })
            counts[item.severity] = counts[item.severity] + 1
        end
    end

    return {
        items = kept_items,
        counts = counts,
        total = #kept_items,
        dropped = dropped,
    }
end

function M.ids(items)
    local set = {}
    for _, item in ipairs(items or {}) do
        set[item.id] = true
    end
    return set
end

function M.new_items(items, seen)
    local fresh = {}
    if type(seen) ~= "table" then
        return fresh
    end
    for _, item in ipairs(items or {}) do
        if not seen[item.id] then
            table.insert(fresh, item)
        end
    end
    return fresh
end

function M.filter(items, severity, fix_only)
    local out = {}
    for _, item in ipairs(items or {}) do
        local severity_ok = severity == nil or severity == "all" or item.severity == severity
        local fix_ok = fix_only ~= true or item.fixed ~= nil
        if severity_ok and fix_ok then
            table.insert(out, item)
        end
    end
    return out
end

function M.max_severity(counts)
    for _, severity in ipairs(M.SEVERITIES) do
        if (counts[severity] or 0) > 0 then
            return severity
        end
    end
    return nil
end

-- Returns a translation key plus the count to use with trp(). Callers render
-- "just now" with tr() when count is zero and plural forms otherwise.
function M.age(checked_at_ms)
    if type(checked_at_ms) ~= "number" or checked_at_ms <= 0 then
        return "time.never", 0
    end

    local seconds = os.time() - math.floor(checked_at_ms / 1000)
    if seconds < 0 then
        seconds = 0
    end

    if seconds < 60 then
        return "time.just_now", 0
    elseif seconds < 3600 then
        return "time.minutes_ago", math.floor(seconds / 60)
    elseif seconds < 86400 then
        return "time.hours_ago", math.floor(seconds / 3600)
    end
    return "time.days_ago", math.floor(seconds / 86400)
end

function M.age_text(checked_at_ms, translate, translate_plural)
    local key, count = M.age(checked_at_ms)
    if count > 0 then
        return translate_plural(key, count)
    end
    return translate(key)
end

function M.upgrade_command()
    return UPGRADE_COMMAND
end

return M
