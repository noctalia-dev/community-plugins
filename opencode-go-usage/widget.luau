--!nonstrict
-- OpenCode Go Usage bar widget.
--
-- Shows the pinned usage-limit percentage (or today's token usage when the
-- dashboard is unavailable). The tooltip
-- lists every usage window plus today's tokens and cost. Click opens the
-- detail panel, right-click requests an immediate refresh.

local PANEL_ID = "elrondforwin/opencode-go-usage:panel"
local DEFAULT_PIN = "rolling"

local WINDOW_BY_PIN = {
	rolling = "Rolling (5h)",
	weekly = "Weekly",
	monthly = "Monthly",
}

local snapshot = noctalia.state.get("opencode_usage.snapshot") or {
	capturedAt = 0,
	isFetching = false,
	go = { status = "idle", entries = {}, error = "" },
	localData = {
		status = "idle",
		days = {},
		models = {},
		totals = { tin = 0, tout = 0, tcr = 0, tcw = 0, cost = 0, sessions = 0 },
		error = "",
	},
}

local function configString(key, fallback)
	local value = noctalia.getConfig(key)
	if type(value) == "string" and value ~= "" then
		return value
	end
	return fallback
end

local function compactNumber(value)
	value = tonumber(value) or 0
	if value >= 1e9 then
		return string.format("%.2fB", value / 1e9)
	end
	if value >= 1e6 then
		return string.format("%.2fM", value / 1e6)
	end
	if value >= 1e3 then
		return string.format("%.1fK", value / 1e3)
	end
	return tostring(math.floor(value))
end

local function countdown(seconds)
	seconds = math.max(0, math.floor(seconds))
	if seconds < 60 then
		return noctalia.tr("widget.seconds", { s = seconds })
	end
	if seconds < 3600 then
		return noctalia.tr("widget.minutes", { m = math.floor(seconds / 60) })
	end
	if seconds < 86400 then
		return noctalia.tr("widget.hours", {
			h = math.floor(seconds / 3600),
			m = math.floor((seconds % 3600) / 60),
		})
	end
	return noctalia.tr("widget.days", {
		d = math.floor(seconds / 86400),
		h = math.floor((seconds % 86400) / 3600),
	})
end

local function entryByName(name)
	for _, entry in ipairs(snapshot.go.entries or {}) do
		if entry.name == name then
			return entry
		end
	end
	return nil
end

local function pinnedEntry()
	local name = WINDOW_BY_PIN[configString("pin_window", DEFAULT_PIN)]
		or WINDOW_BY_PIN[DEFAULT_PIN]
	return entryByName(name)
end

local function shownPercent(entry)
	if configString("display_mode", "remaining") == "used" then
		return math.round(entry.percentUsed)
	end
	return math.round(100 - entry.percentUsed)
end

local function todayRow()
	for _, day in ipairs(snapshot.localData.days or {}) do
		if day.label == os.date("%Y-%m-%d") then
			return day
		end
	end
	return nil
end

local function formatCost(value)
	value = tonumber(value) or 0
	if value <= 0 then
		return "$0"
	end
	return string.format("$%.2f", value)
end

local function tooltipRows()
	local rows = {}
	local go = snapshot.go or {}

	if go.status == "ok" then
		for _, entry in ipairs(go.entries or {}) do
			local reset = ""
			if type(entry.resetAt) == "number" and entry.resetAt > 0 then
				reset = " · " .. noctalia.tr("widget.resets", {
					time = countdown(entry.resetAt - os.time()),
				})
			end
			table.insert(rows, {
				key = entry.name,
				value = string.format("%.0f%%", entry.percentUsed) .. reset,
			})
		end
	elseif go.status ~= "idle" and go.status ~= "disabled" then
		table.insert(rows, {
			key = noctalia.tr("widget.status"),
			value = noctalia.tr("status." .. tostring(go.status)),
		})
		if type(go.error) == "string" and go.error ~= "" then
			table.insert(rows, { key = noctalia.tr("widget.detail"), value = go.error })
		end
	end

	local loc = snapshot.localData or {}
	if loc.status == "ok" then
		local today = todayRow()
		if today ~= nil then
			local tokens = (today.tin or 0) + (today.tout or 0)
			local cached = today.tcr or 0
			table.insert(rows, {
				key = noctalia.tr("widget.today_tokens"),
				value = compactNumber(tokens)
					.. " ("
					.. compactNumber(cached) .. " " .. noctalia.tr("widget.cached") .. ")",
			})
			table.insert(rows, {
				key = noctalia.tr("widget.today_cost"),
				value = formatCost(today.cost),
			})
		end
	end

	if snapshot.capturedAt > 0 then
		table.insert(rows, {
			key = noctalia.tr("widget.updated"),
			value = noctalia.formatTime("%H:%M:%S", snapshot.capturedAt),
		})
	end
	return rows
end

local function render()
	local goStatus = snapshot.go.status or "idle"
	local pinned = pinnedEntry()
	local text = ""
	local color = "on_surface"
	local isPercentage = false

	if goStatus == "ok" and pinned ~= nil then
		text = tostring(shownPercent(pinned)) .. "%"
		isPercentage = true
	elseif (snapshot.localData.status or "idle") == "ok" and todayRow() ~= nil then
		local today = todayRow()
		text = compactNumber((today.tin or 0) + (today.tout or 0))
	elseif goStatus == "unconfigured" or goStatus == "auth_expired" then
		text = "—"
		color = "on_surface_variant"
	end

	local children = {
		ui.glyph({
			name = configString("glyph", "activity"),
			size = 16,
			color = "primary",
		}),
	}
	local showText = text ~= "" and not barWidget.isVertical()
	if isPercentage and noctalia.getConfig("show_percentage_label") == false then
		showText = false
	end
	if showText then
		table.insert(children, ui.label({
			text = text,
			fontWeight = "bold",
			color = color,
		}))
	end

	local container = barWidget.isVertical() and ui.column or ui.row
	barWidget.render(container({ gap = 6, align = "center" }, children))
	barWidget.setTooltip(tooltipRows())
end

noctalia.state.watch("opencode_usage.snapshot", function(value)
	if type(value) == "table" then
		snapshot = value
		render()
	end
end)

noctalia.setUpdateInterval(60000)

function update()
	render()
end

function onClick()
	noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
	noctalia.state.set("opencode_usage.refresh_requested", true)
	noctalia.notify(noctalia.tr("title"), noctalia.tr("widget.refresh_requested"))
end

render()
