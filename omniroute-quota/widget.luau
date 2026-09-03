local DATA_KEY = "omniroute_quota.data"
local STATUS_KEY = "omniroute_quota.status"
local ERROR_KEY = "omniroute_quota.error"

local data = nil
local status = "loading"
local error_message = ""

local function color_for(remaining)
    if remaining == nil then return "on_surface_variant" end
    if remaining <= 10 then return "error" end
    if remaining <= 30 then return "secondary" end
    return "primary"
end

local function tooltip_rows()
    if error_message ~= "" then
        return { { key = noctalia.tr("widget.error"), value = error_message } }
    end
    if type(data) ~= "table" or type(data.accounts) ~= "table" then
        return { { key = noctalia.tr("widget.title"), value = noctalia.tr("widget.loading") } }
    end

    local rows = {}
    for _, account in ipairs(data.accounts) do
        if type(account) == "table" then
            local title = tostring(account.name or "Codex")
            if account.error then
                rows[#rows + 1] = { key = title, value = tostring(account.error) }
            else
                for _, window in ipairs(account.windows or {}) do
                    rows[#rows + 1] = {
                        key = title .. " · " .. tostring(window.label or window.key),
                        value = string.format("%d%% %s", math.floor((tonumber(window.remainingPercent) or 0) + 0.5), noctalia.tr("widget.remaining")),
                    }
                end
            end
        end
    end
    if #rows == 0 then
        rows[1] = { key = noctalia.tr("widget.title"), value = noctalia.tr("widget.no_accounts") }
    end
    return rows
end

local function render()
    local summary = type(data) == "table" and data.summary or nil
    local remaining = type(summary) == "table" and tonumber(summary.worstRemainingPercent) or nil
    local show_value = noctalia.getConfig("show_value") ~= false

    local children = {
        ui.glyph({
            name = status == "error" and "alert-circle" or "route",
            size = 13,
            color = status == "error" and "error" or color_for(remaining),
        }),
    }
    if show_value and remaining ~= nil then
        children[#children + 1] = ui.label({
            text = string.format("%d%%", math.floor(remaining + 0.5)),
            fontSize = 11,
            fontWeight = "semibold",
            color = color_for(remaining),
            width = 30,
            textAlign = "end",
        })
    end
    barWidget.render(ui.row({ gap = 5, align = "center" }, children))
    barWidget.setTooltip(tooltip_rows())
end

function onClick()
    noctalia.togglePanel("teagar/omniroute-quota:panel")
end

noctalia.state.watch(DATA_KEY, function(value)
    data = value
    render()
end)

noctalia.state.watch(STATUS_KEY, function(value)
    status = tostring(value or "loading")
    render()
end)

noctalia.state.watch(ERROR_KEY, function(value)
    error_message = tostring(value or "")
    render()
end)

data = noctalia.state.get(DATA_KEY)
status = tostring(noctalia.state.get(STATUS_KEY) or "loading")
error_message = tostring(noctalia.state.get(ERROR_KEY) or "")
render()
