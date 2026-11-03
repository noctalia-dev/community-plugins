--!nonstrict
-- Panel: pending updates like `apt list --upgradable` - changed flake inputs
-- with their revisions, the package versions that change with them, and
-- Flatpak updates - plus buttons to check again and to run the update command.
-- All sections together show at most PREVIEW rows, then one button opens
-- the details window with everything.

local diff = require("./lib/diff.luau")
local view = require("./lib/view.luau")

local PREVIEW = 8

local result = noctalia.state.get(view.RESULT_KEY) or {}
local expanded = { inputs = true, packages = true, flatpak = true }

local function openDetails()
	panel.close()
	noctalia.togglePanel(view.DETAILS_ID)
end

local function row(key, title, meta, right, onClick, tooltip)
	return ui.row({
		key = key,
		align = "center",
		gap = 10,
		paddingH = 8,
		paddingV = 5,
		radius = 8,
		tooltip = tooltip,
		onClick = onClick,
	}, {
		ui.column({ flexGrow = 1, gap = 1 }, {
			ui.label({ text = title, fontSize = 13, fontWeight = "medium", color = "on_surface", maxLines = 1 }),
			meta ~= "" and ui.label({ text = meta, fontSize = 11, color = "on_surface_variant", maxLines = 1 }) or nil,
		}),
		right ~= "" and ui.label({ text = right, fontSize = 12, color = "on_surface", textAlign = "end", maxLines = 1 }) or nil,
	})
end

-- Name on its own line, revisions and source below, dates on the right.
local function inputRow(input)
	local meta = input.oldRev .. "  →  " .. input.newRev
	if input.source ~= "" then
		meta = meta .. "  ·  " .. input.source
	end
	local dates = ""
	if view.date(input.oldDate) ~= "" and view.date(input.newDate) ~= "" then
		dates = view.date(input.oldDate) .. "  →  " .. view.date(input.newDate)
	end
	local onClick = nil
	local tooltip = nil
	if input.url ~= nil then
		onClick = function()
			view.openUrl(input.url)
		end
		tooltip = noctalia.tr("panel.open_compare")
	end
	return row("input-" .. input.name, input.name, meta, dates, onClick, tooltip)
end

local function packageRow(pkg)
	local onClick = pkg.changes ~= nil and function()
		view.openUrl(pkg.changes)
	end or nil
	return row("pkg-" .. pkg.name, pkg.name, "", view.change(pkg.old, pkg.new), onClick, pkg.changes)
end

local function flatpakRow(fp)
	local meta = fp.app .. " · " .. fp.branch .. " · " .. fp.installation
	local onClick = fp.changes ~= nil and function()
		view.openUrl(fp.changes)
	end or nil
	return row("fp-" .. fp.installation .. fp.app .. fp.branch, fp.name, meta, view.flatpakChange(fp), onClick, fp.changes)
end

local function moreButton(text)
	return ui.button({
		text = text,
		glyph = "list-details",
		fontSize = 12,
		glyphSize = 12,
		variant = "outline",
		controlSize = "sm",
		onClick = openDetails,
	})
end

-- Collapsible section; nil when the check did not cover it. Shows at most
-- `budget` rows; `more(hidden)` gives the button that replaces the rest, or
-- nil to leave it out. Returns the node and the number of rows shown.
local function section(id, glyph, labelKey, rows, makeRow, budget, more)
	if type(rows) ~= "table" then
		return nil, 0
	end
	local shown = expanded[id] and math.min(#rows, budget) or 0
	local children = {
		ui.row({ align = "center", gap = 6 }, {
			ui.glyph({ name = glyph, size = 16, color = "primary" }),
			ui.button({
				text = noctalia.tr(labelKey, { count = #rows }),
				glyph = #rows == 0 and "check" or (shown > 0 and "chevron-up" or "chevron-down"),
				fontSize = 12,
				glyphSize = 12,
				variant = "ghost",
				controlSize = "sm",
				contentAlign = "start",
				onClick = function()
					expanded[id] = not expanded[id]
					render()
				end,
			}),
		}),
	}
	local list = {}
	for i = 1, shown do
		table.insert(list, makeRow(rows[i]))
	end
	if expanded[id] and shown < #rows then
		local button = more(#rows - shown)
		if button ~= nil then
			table.insert(list, button)
		end
	end
	if #list > 0 then
		table.insert(children, ui.column({ gap = 2 }, list))
	end
	return ui.column({ gap = 4 }, children), shown
end

function render()
	local body = {}
	for _, e in ipairs(result.errors or {}) do
		table.insert(body, ui.label({ text = e.message, fontSize = 12, color = "error", maxLines = 4 }))
	end

	-- Nothing pending at all: one line instead of three empty sections.
	local empty = result.checkedAt ~= nil and not result.running and #(result.errors or {}) == 0 and diff.pendingCount(result) == 0
	if empty then
		table.insert(body, ui.row({ align = "center", gap = 8 }, {
			ui.glyph({ name = "circle-check", size = 18, color = "primary" }),
			ui.label({ text = view.status(result), fontSize = 13, color = "on_surface", flexGrow = 1 }),
		}))
	else
		table.insert(body, ui.label({ text = view.status(result), fontSize = 12, color = "on_surface_variant" }))
	end

	if result.checkedAt ~= nil and not empty then
		local kinds = {
			{ "packages", "package", "panel.packages", result.packages, packageRow },
			{ "flatpak", "box", "panel.flatpak", result.flatpak, flatpakRow },
			{ "inputs", "snowflake", "panel.inputs", result.inputs, inputRow },
		}
		local count = tonumber(result.count) or 0
		local budget = PREVIEW
		local shownTotal = 0
		local buttonPlaced = false
		for _, k in ipairs(kinds) do
			-- One button where the list is cut first; every row counts, so the
			-- numbers add up to the count above.
			local function more(_hidden)
				if buttonPlaced then
					return nil
				end
				buttonPlaced = true
				local hidden = count - shownTotal - math.min(#k[4], budget)
				return moreButton(noctalia.tr("panel.more_updates", { hidden = hidden, count = count }))
			end
			local node, shown = section(k[1], k[2], k[3], k[4], k[5], budget, more)
			if node ~= nil then
				table.insert(body, node)
				budget -= shown
				shownTotal += shown
			end
		end
		if type(result.inputs) == "table" and type(result.packages) ~= "table" and #result.inputs > 0 then
			table.insert(body, ui.label({ text = noctalia.tr("panel.no_package_list"), fontSize = 11, color = "on_surface_variant", maxLines = 3 }))
		end
	end

	-- No scroll area and no flexGrow: at most PREVIEW rows fit anyway, and the
	-- panel (height = "content") then takes only the height it needs.
	panel.render(ui.column({ gap = 12 }, {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.glyph({ name = "snowflake", size = 20, color = "primary" }),
			ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.button({ glyph = "arrows-maximize", variant = "ghost", tooltip = noctalia.tr("panel.open_details"), onClick = openDetails }),
			ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
		}),
		ui.column({ gap = 10 }, body),
		ui.row({ align = "center", gap = 8 }, view.actions(result, function()
			panel.close()
		end)),
	}))
end

noctalia.state.watch(view.RESULT_KEY, function(value)
	if type(value) == "table" then
		result = value
		render()
	end
end)

function onOpen(_context)
	render()
end

function onCloseClicked()
	panel.close()
end

render()
