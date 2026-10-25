-- Shared presentation only: network and persistence belong to the service.
local policy = require("./presentation.luau")
local Time = require("./time.luau")
local Providers = require("./providers.luau")
local M = {}
local statuses = { ok = true, disabled = true, notConfigured = true, unauthorized = true,
    rateLimited = true, sourceRateLimited = true, unavailable = true, error = true }
local errors = { invalid_url = true, credentials_unreadable = true, credentials_invalid = true,
    unauthorized = true, network = true, http = true, invalid_response = true,
    too_large = true, request_rejected = true, processing_error = true }
local brandFont, fontLoaded = nil, false
local function providerEntry(id, adapterId)
    if id == "thirdparty" and Providers.adapters[adapterId] then return Providers.adapters[adapterId] end
    return Providers.entries[Providers.aliases[id] or id]
end

function M.dashboard(value)
    if type(value) == "table" then return value end
    return { status = "loading", providers = {}, lastSuccess = 0 }
end

function M.providerName(id)
    local entry = providerEntry(id)
    return entry and entry.name or id
end
function M.providerIcon(id, size, color, adapterId)
    local entry = providerEntry(id, adapterId)
    if not entry or not entry.codepoint then
        return ui.glyph({ key = "provider-icon-" .. tostring(id), name = entry and entry.glyph or "cloud", size = size, color = color })
    end
    if not fontLoaded then
        brandFont = noctalia.loadFont(Providers.font)
        fontLoaded = true
        if not brandFont then noctalia.log("Token Monitor: provider icon font could not be loaded") end
    end
    return ui.label({ key = "provider-icon-" .. id,
        text = brandFont and utf8.char(entry.codepoint) or entry.initials,
        fontFamily = brandFont, fontWeight = "normal", fontSize = brandFont and size or size * 0.55,
        width = size, height = size, textAlign = "center", baseline = "inkCentered",
        color = color, maxLines = 1 })
end

function M.fieldKey(value)
    return (value:gsub("%u", function(letter) return "_" .. letter:lower() end))
end

function M.status(provider)
    local status = provider.status
    return noctalia.tr("provider_status." .. M.fieldKey(statuses[status] and status or "unknown"))
end

function M.error(value)
    local suffix = string.gsub(tostring(value or ""), "^error%.", "")
    return noctalia.tr("error." .. (errors[suffix] and suffix or "invalid_response"))
end

function M.number(value)
    if not policy.finite(value) then return noctalia.tr("common.unavailable") end
    return (string.gsub(string.gsub(string.format("%.2f", value), "0+$", ""), "%.$", ""))
end

function M.value(window, mode)
    if not window or not policy.finite(window.value) then return noctalia.tr("common.unavailable") end
    local percentage = policy.percentage(window, mode)
    if percentage ~= nil then return M.number(percentage) .. "%" end
    return M.number(window.value) .. (window.unit and window.unit ~= "" and " " .. window.unit or "")
end

function M.metricLabel(window, mode)
    if window and window.metric == "percent" then
        return noctalia.tr(mode == "used" and "quota.used" or "quota.remaining")
    elseif window and window.metric == "balance" then
        return noctalia.tr("quota.balance")
    end
    return noctalia.tr("quota.unavailable")
end

function M.quotaText(window, mode)
    local text = M.value(window, mode)
    if policy.remaining(window) ~= nil then
        return text .. " " .. noctalia.tr(mode == "used" and "quota.used_short" or "quota.remaining_short")
    end
    return text
end

function M.windowLabel(window)
    if type(window.label) == "string" and window.label ~= "" then return window.label end
    local kind = window.kind
    if kind ~= "weekly" and kind ~= "session" and kind ~= "billing" then kind = "other" end
    return noctalia.tr("window." .. kind)
end

function M.received(timestamp)
    if type(timestamp) ~= "number" or timestamp <= 0 then return noctalia.tr("common.never") end
    return noctalia.formatTime("%m-%d %H:%M", timestamp)
end

function M.timestamp(value)
    local epoch = Time.parse(value)
    return epoch and noctalia.formatTime("%m-%d %H:%M", epoch) or noctalia.tr("common.unavailable")
end

function M.age(value)
    local result = Time.age(value, os.time())
    return noctalia.tr(result.key, result.values)
end

function M.reset(value)
    local result = Time.countdown(value, os.time())
    return noctalia.tr(result.key, result.values)
end

function M.compact(value)
    if not policy.finite(value) then return noctalia.tr("common.unavailable") end
    if math.abs(value) >= 1000000000 then return M.number(value / 1000000000) .. "B" end
    if math.abs(value) >= 1000000 then return M.number(value / 1000000) .. "M" end
    if math.abs(value) >= 1000 then return M.number(value / 1000) .. "K" end
    return M.number(value)
end

function M.money(value)
    if not policy.finite(value) then return noctalia.tr("common.unavailable") end
    if value ~= 0 and math.abs(value) < 0.01 then return string.format("$%.4f", value) end
    return string.format("$%.2f", value)
end

function M.duration(milliseconds)
    if not policy.finite(milliseconds) or milliseconds < 0 then return noctalia.tr("common.unavailable") end
    local minutes = math.floor(milliseconds / 60000)
    return noctalia.tr("time.duration", { hours = math.floor(minutes / 60), minutes = minutes % 60 })
end

return M
