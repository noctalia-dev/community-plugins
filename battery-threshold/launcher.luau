--!nonstrict
-- Battery threshold launcher provider, under the `/batt` prefix.
--
-- Empty (or non-numeric) query offers to open the panel. A single number sets
-- the charge threshold directly, clamped to the 40-100 range the service and
-- panel slider both enforce.

local common = require("./common.luau")

local OPEN_RESULT_ID = "open-panel"
local SET_RESULT_PREFIX = "set:"

local function openResult()
    local threshold = noctalia.state.get(common.STATE.CURRENT_THRESHOLD) or 0

    return {
        id = OPEN_RESULT_ID,
        title = noctalia.tr("launcher.open-title"),
        subtitle = noctalia.tr("launcher.open-subtitle", { threshold = threshold }),
        glyph = "battery-eco",
    }
end

local function setResult(num: number)
    local rounded = math.floor(num + 0.5)
    local clamped = common.clamp(rounded)
    if noctalia.state.get(common.STATE.IS_WRITABLE) ~= true then
        return {
            id = OPEN_RESULT_ID,
            title = noctalia.tr("launcher.no-permissions"),
            subtitle = noctalia.tr("launcher.open-panel-hint"),
            glyph = "battery-eco",
        }
    end

    local title = noctalia.tr("launcher.set-title", { value = clamped })
    local subtitle = if clamped ~= rounded
        then noctalia.tr("launcher.set-subtitle-clamped", { min = common.MIN_THRESHOLD, max = common.MAX_THRESHOLD })
        else noctalia.tr("launcher.set-subtitle")

    return {
        id = SET_RESULT_PREFIX .. tostring(clamped),
        title = title,
        subtitle = subtitle,
        glyph = "battery-eco",
    }
end

function onQuery(query)
    local trimmed = noctalia.string.trim(tostring(query or ""))
    local num = tonumber(trimmed)

    if num ~= nil then
        launcher.setResults(query, { setResult(num) })
        return
    end

    launcher.setResults(query, { openResult() })
end

function onActivate(id)
    if id == OPEN_RESULT_ID then
        noctalia.togglePanel(common.PANEL_ID)
        return
    end

    local valueStr = id:match("^" .. SET_RESULT_PREFIX .. "(%d+)$")
    if valueStr then
        local value = tonumber(valueStr)
        if value then
            common.requestThreshold(value)
            noctalia.notify(noctalia.tr("launcher.open-title"), noctalia.tr("launcher.set-notify", { value = value }))
        end
    end
end
