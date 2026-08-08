--!nonstrict
-- OpenCode Go Usage panel: Go plan usage-limit cards with progress bars and
-- reset countdowns, plus local token/cost stats (today, 7-day graph, and a
-- per-model breakdown).

local EMPTY = {
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

local snapshot = noctalia.state.get("opencode_usage.snapshot") or EMPTY

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

local function formatCost(value)
	value = tonumber(value) or 0
	if value <= 0 then
		return "$0"
	end
	return string.format("$%.2f", value)
end

local function todayRow()
	for _, day in ipairs(snapshot.localData.days or {}) do
		if day.label == os.date("%Y-%m-%d") then
			return day
		end
	end
	return nil
end

local function resetLabel(resetAt)
	if type(resetAt) ~= "number" or resetAt <= 0 then
		return ""
	end
	local remaining = resetAt - os.time()
	if remaining <= 0 then
		return noctalia.tr("panel.resets_now")
	end
	if remaining < 3600 then
		return noctalia.tr("panel.resets_in_m", {
			m = math.max(1, math.floor(remaining / 60)),
		})
	end
	if remaining < 86400 then
		return noctalia.tr("panel.resets_in_hm", {
			h = math.floor(remaining / 3600),
			m = math.floor((remaining % 3600) / 60),
		})
	end
	return noctalia.tr("panel.resets_in_dh", {
		d = math.floor(remaining / 86400),
		h = math.floor((remaining % 86400) / 3600),
	})
end

local function progressBar(percentUsed, color)
	local ok, node = pcall(function()
		return ui.progress({
			progress = math.clamp(percentUsed / 100, 0, 1),
			fill = color,
			track = "surface_variant/0.5",
			radius = 4,
			height = 8,
		})
	end)
	if ok and type(node) == "table" then
		return node
	end
	return ui.label({
		text = string.format("%.0f%%", percentUsed),
		fontSize = 11,
		color = "on_surface_variant",
	})
end

local function windowCard(entry)
	local used = math.round(entry.percentUsed)
	return ui.column(
		{ gap = 6, padding = 10, fill = "surface_variant/0.35", radius = 10 },
		{
			ui.row({ gap = 8, align = "center" }, {
				ui.label({ text = entry.name, fontWeight = "bold", flexGrow = 1 }),
				ui.label({
					text = tostring(used) .. "%",
					fontSize = 18,
					fontWeight = "heavy",
				}),
			}),
			progressBar(entry.percentUsed, "primary"),
			ui.row({ gap = 8, justify = "space_between", align = "center" }, {
				ui.label({
					text = noctalia.tr("panel.used", {
						used = tostring(used),
						remaining = tostring(math.max(0, 100 - used)),
					}),
					fontSize = 11,
					color = "on_surface_variant",
				}),
				ui.label({
					text = resetLabel(entry.resetAt),
					fontSize = 11,
					color = "on_surface_variant",
				}),
			}),
		})
end

local function goSection()
	local go = snapshot.go or {}
	local status = go.status or "idle"
	if status == "ok" then
		local cards = {}
		for _, entry in ipairs(go.entries or {}) do
			table.insert(cards, windowCard(entry))
		end
		return ui.column({ gap = 8 }, {
			ui.label({
				text = noctalia.tr("panel.limits_title"),
				fontSize = 13,
				fontWeight = "bold",
			}),
			ui.label({
				text = go.error or "",
				fontSize = 11,
				color = "on_surface_variant",
			}),
			ui.column({ gap = 8 }, cards),
		})
	end
	if status == "disabled" then
		return nil
	end
	local isConfigIssue = status == "unconfigured" or status == "auth_expired"
	local glyphName = isConfigIssue and "settings" or "alert-circle"
	local glyphColor = isConfigIssue and "warning" or "error"
	local message = go.error
	if type(message) ~= "string" or message == "" then
		message = noctalia.tr("status." .. tostring(status))
	end
	return ui.column(
		{ gap = 8, padding = 10, fill = "surface_variant/0.35", radius = 10 },
		{
			ui.row({ gap = 8, align = "center" }, {
				ui.glyph({ name = glyphName, color = glyphColor, size = 16 }),
				ui.label({
					text = noctalia.tr("panel.limits_title"),
					fontWeight = "bold",
					flexGrow = 1,
				}),
			}),
			ui.label({ text = message, fontSize = 12, color = "on_surface_variant" }),
			ui.button({
				text = noctalia.tr("panel.open_settings"),
				variant = "outline",
				controlSize = "sm",
				onClick = "onOpenSettings",
			}),
		})
end

local function usageRow(label, value)
	return ui.row({ gap = 8, justify = "space_between", align = "center" }, {
		ui.label({ text = label, fontSize = 12, color = "on_surface_variant" }),
		ui.label({ text = value, fontSize = 12, fontWeight = "bold" }),
	})
end

local function dayGraph()
	local days = snapshot.localData.days or {}
	if #days == 0 then
		return nil
	end
	local max = 0
	local recent = {}
	local limit = math.min(7, #days)
	for index = 1, limit do
		local tokens = (days[index].tin or 0) + (days[index].tout or 0)
		table.insert(recent, tokens)
		if tokens > max then
			max = tokens
		end
	end
	local values = {}
	for _, tokens in ipairs(recent) do
		table.insert(values, max > 0 and tokens / max or 0)
	end
	local ok, node = pcall(function()
		return ui.graph({
			values = values,
			color = "primary",
			fillOpacity = 0.25,
			height = 64,
		})
	end)
	if not ok or type(node) ~= "table" then
		return nil
	end
	return ui.column(
		{ gap = 4, padding = 10, fill = "surface_variant/0.35", radius = 10 },
		{
			ui.label({
				text = noctalia.tr("panel.week_tokens"),
				fontSize = 11,
				color = "on_surface_variant",
			}),
			node,
		})
end

local function modelsSection()
	local models = snapshot.localData.models or {}
	if #models == 0 then
		return nil
	end
	local sorted = {}
	for index, model in ipairs(models) do
		sorted[index] = model
	end
	table.sort(sorted, function(a, b)
		return (a.tin or 0) > (b.tin or 0)
	end)
	local rows = {}
	for _, model in ipairs(sorted) do
		table.insert(rows, ui.row(
			{ gap = 8, justify = "space_between", align = "center" },
			{
				ui.label({ text = model.name, fontSize = 12, maxLines = 1, flexGrow = 1 }),
				ui.label({
					text = compactNumber((model.tin or 0) + (model.tout or 0))
						.. " · " .. tostring(model.sessions or 0) .. "s",
					fontSize = 12,
					color = "on_surface_variant",
				}),
			}
		))
	end
	return ui.column(
		{ gap = 4, padding = 10, fill = "surface_variant/0.35", radius = 10 },
		{
			ui.label({
				text = noctalia.tr("panel.models_title"),
				fontSize = 11,
				color = "on_surface_variant",
			}),
			ui.column({ gap = 2 }, rows),
		})
end

local function usageSection()
	local loc = snapshot.localData or {}
	local status = loc.status or "idle"
	if status == "disabled" then
		return nil
	end
	if status ~= "ok" then
		local message = loc.error
		if type(message) ~= "string" or message == "" then
			message = noctalia.tr("status." .. tostring(status))
		end
		return ui.column({ gap = 8 }, {
			ui.label({
				text = noctalia.tr("panel.usage_title"),
				fontSize = 13,
				fontWeight = "bold",
			}),
			ui.row(
				{
					gap = 8,
					fill = "error/0.15",
					radius = 8,
					padding = 10,
					align = "center",
				},
				{
					ui.glyph({ name = "alert-circle", color = "error", size = 16 }),
					ui.label({ text = message, fontSize = 12, color = "error", flexGrow = 1 }),
				}
			),
		})
	end

	local nodes = {
		ui.label({
			text = noctalia.tr("panel.usage_title"),
			fontSize = 13,
			fontWeight = "bold",
		}),
	}

	local today = todayRow()
	local totals = snapshot.localData.totals or {}
	if today ~= nil then
		table.insert(nodes, ui.column(
			{ gap = 4, padding = 10, fill = "surface_variant/0.35", radius = 10 },
			{
				ui.label({
					text = noctalia.tr("panel.today_title"),
					fontSize = 11,
					color = "on_surface_variant",
				}),
				usageRow(noctalia.tr("panel.input_tokens"), compactNumber(today.tin)),
				usageRow(noctalia.tr("panel.output_tokens"), compactNumber(today.tout)),
				usageRow(noctalia.tr("panel.cache_read"), compactNumber(today.tcr)),
				usageRow(noctalia.tr("panel.cost"), formatCost(today.cost)),
				usageRow(noctalia.tr("panel.sessions"), tostring(today.sessions or 0)),
			}
		))
	elseif type(totals) == "table" then
		table.insert(nodes, ui.column(
			{ gap = 4, padding = 10, fill = "surface_variant/0.35", radius = 10 },
			{
				ui.label({
					text = noctalia.tr("panel.all_time_title"),
					fontSize = 11,
					color = "on_surface_variant",
				}),
				usageRow(noctalia.tr("panel.input_tokens"), compactNumber(totals.tin)),
				usageRow(noctalia.tr("panel.output_tokens"), compactNumber(totals.tout)),
				usageRow(noctalia.tr("panel.cache_read"), compactNumber(totals.tcr)),
				usageRow(noctalia.tr("panel.cost"), formatCost(totals.cost)),
				usageRow(noctalia.tr("panel.sessions"), tostring(totals.sessions or 0)),
			}
		))
	end

	local graph = dayGraph()
	if graph ~= nil then
		table.insert(nodes, graph)
	end
	local models = modelsSection()
	if models ~= nil then
		table.insert(nodes, models)
	end
	return ui.column({ gap = 8 }, nodes)
end

local function render()
	local bodyItems = {}
	local go = goSection()
	if go ~= nil then
		table.insert(bodyItems, go)
	end
	local usage = usageSection()
	if usage ~= nil then
		table.insert(bodyItems, usage)
	end
	if #bodyItems == 0 then
		table.insert(bodyItems, ui.label({
			text = noctalia.tr("panel.no_data"),
			color = "on_surface_variant",
			textAlign = "center",
			padding = 12,
		}))
	end

	panel.render(ui.column({ flexGrow = 1, gap = 10, padding = 12 }, {
		ui.row({ align = "center", gap = 8 }, {
			ui.glyph({ name = "activity", size = 18, color = "primary" }),
			ui.label({
				text = noctalia.tr("title"),
				fontSize = 16,
				fontWeight = "bold",
				flexGrow = 1,
			}),
			ui.button({
				glyph = "refresh",
				variant = "ghost",
				tooltip = noctalia.tr("panel.refresh_tooltip"),
				onClick = "onRefresh",
			}),
			ui.button({
				glyph = "close",
				variant = "ghost",
				onClick = "onCloseClicked",
			}),
		}),
		ui.scroll({ flexGrow = 1, gap = 10 }, bodyItems),
		ui.row({ justify = "space_between", align = "center" }, {
			ui.label({
				text = snapshot.capturedAt > 0
					and noctalia.tr("panel.updated_at", {
						time = noctalia.formatTime("%H:%M:%S", snapshot.capturedAt),
					})
					or "",
				fontSize = 10,
				color = "on_surface_variant",
			}),
		}),
	}))
end

noctalia.state.watch("opencode_usage.snapshot", function(value)
	if type(value) == "table" then
		snapshot = value
		render()
	end
end)

panel.setWantsSecondTicks(true)

function onOpen(_context)
	snapshot = noctalia.state.get("opencode_usage.snapshot") or snapshot
	render()
end

function update()
	local go = snapshot.go or {}
	if go.status == "ok" then
		render()
	end
end

function onRefresh()
	noctalia.state.set("opencode_usage.refresh_requested", true)
end

function onOpenSettings()
	noctalia.openSettings()
end

function onCloseClicked()
	panel.close()
end

render()
