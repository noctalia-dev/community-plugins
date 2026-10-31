--!nonstrict
-- Bar widget: glyph plus the number of pending updates (package changes,
-- Flatpak updates and flake inputs with new commits). Left-click opens the
-- panel through the manifest action.

local RESULT_KEY = "nixos_updates"

local result = noctalia.state.get(RESULT_KEY) or {}

local function config(key, fallback)
	local value = noctalia.getConfig(key)
	if value == nil then
		return fallback
	end
	return value
end

local function tooltip()
	local rows = {}
	if result.running then
		table.insert(rows, { key = noctalia.tr("widget.title"), value = noctalia.tr("panel.checking") })
	end
	for _, e in ipairs(result.errors or {}) do
		table.insert(rows, { key = noctalia.tr("widget.error"), value = e.message })
	end
	if result.checkedAt == nil then
		if #rows == 0 then
			table.insert(rows, { key = noctalia.tr("widget.title"), value = noctalia.tr("panel.never_checked") })
		end
		return rows
	end
	if type(result.packages) == "table" then
		table.insert(rows, { key = noctalia.tr("widget.packages"), value = tostring(#result.packages) })
	end
	if type(result.inputs) == "table" then
		table.insert(rows, { key = noctalia.tr("widget.inputs"), value = tostring(#result.inputs) })
	end
	if type(result.flatpak) == "table" then
		table.insert(rows, { key = noctalia.tr("widget.flatpak"), value = tostring(#result.flatpak) })
	end
	table.insert(rows, {
		key = noctalia.tr("widget.checked"),
		value = noctalia.formatTime("{:%Y-%m-%d %H:%M}", result.checkedAt),
	})
	return rows
end

local function render()
	local n = tonumber(result.count) or 0
	local hasErrors = #(result.errors or {}) > 0
	barWidget.setVisible(n > 0 or hasErrors or result.running or config("hide_when_up_to_date", false) ~= true)

	local name = tostring(config("glyph", "package"))
	if name == "" then
		name = "package"
	end
	local text = ""
	if config("show_count", true) == true and (n > 0 or config("show_zero", false) == true) then
		text = tostring(n)
	end

	-- Pending updates or an error: a filled badge. Accent colors of a wallpaper
	-- theme are too alike for a mere text color to stand out in the bar.
	local fill = nil
	if hasErrors then
		fill = "error"
	elseif n > 0 then
		fill = config("highlight_color", "tertiary")
	end
	local foreground = fill ~= nil and "surface" or nil
	-- The error color can be close to the update color in a wallpaper theme, so
	-- an error also changes the glyph. A custom glyph has no crossed-out form.
	if hasErrors then
		name = name == "package" and "package-off" or "alert-triangle"
	end

	-- Separate keys: a dropped prop does not reset on a retained node, so badge
	-- and plain state must not share nodes.
	local state = fill ~= nil and "badge" or "plain"
	local parts = { ui.glyph({ key = state .. "-glyph", name = name, color = foreground }) }
	if text ~= "" then
		table.insert(parts, ui.label({ key = state .. "-label", text = text, color = foreground, fontWeight = fill ~= nil and "bold" or nil }))
	end
	local container = barWidget.isVertical() and ui.column or ui.row
	barWidget.render(container({
		key = state,
		gap = 4,
		align = "center",
		fill = fill,
		radius = fill ~= nil and 8 or nil,
		paddingH = fill ~= nil and 7 or nil,
		paddingV = fill ~= nil and 2 or nil,
	}, parts))
	barWidget.setTooltip(tooltip())
end

noctalia.state.watch(RESULT_KEY, function(value)
	if type(value) == "table" then
		result = value
		render()
	end
end)

render()
