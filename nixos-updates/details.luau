--!nonstrict
-- Details window: every pending update in one table (name, installed, new,
-- where to read the changes), with a search field and a filter by kind. Opened from the compact
-- panel when the list gets long.

local view = require("./lib/view.luau")

local NAME_WIDTH = 230
local OLD_WIDTH = 190
local NEW_WIDTH = 190

local result = noctalia.state.get(view.RESULT_KEY) or {}
local query = ""
local filter = "all"

local function matches(...)
	if query == "" then
		return true
	end
	for i = 1, select("#", ...) do
		local text = select(i, ...)
		if text ~= nil and tostring(text):lower():find(query, 1, true) ~= nil then
			return true
		end
	end
	return false
end

-- Labels size to their text; the fixed-width row around them keeps the
-- columns aligned. Without a width the cell takes the remaining space.
local function cell(text, width, color, weight, size)
	if text == "" then
		text = "–"
	end
	return ui.row({ width = width, minWidth = width, flexGrow = width == nil and 1 or nil, align = "center" }, {
		ui.label({
			text = text,
			flexGrow = 1,
			fontSize = size or 12,
			fontWeight = weight,
			color = color or "on_surface",
			maxLines = 1,
		}),
	})
end

-- The changes column: a link (glyph plus what it leads to) or a muted note
-- that there is none.
local function changesCell(url, labelKey, noneKey)
	if url == nil then
		return cell(noctalia.tr(noneKey), nil, "on_surface_variant/0.6")
	end
	return ui.row({ flexGrow = 1, gap = 6, align = "center" }, {
		ui.glyph({ name = "external-link", size = 13, color = "secondary" }),
		ui.label({ text = noctalia.tr(labelKey), flexGrow = 1, fontSize = 12, color = "secondary", maxLines = 1 }),
	})
end

-- A click anywhere on a row opens its changes link; the tooltip shows where.
local function tableRow(key, index, name, old, new, url, labelKey, noneKey)
	return ui.row({
		key = key,
		align = "center",
		gap = 12,
		paddingH = 10,
		paddingV = 6,
		radius = 6,
		fill = index % 2 == 0 and "on_surface/0.04" or nil,
		tooltip = url,
		onClick = url ~= nil and function()
			view.openUrl(url)
		end or nil,
	}, {
		cell(name, NAME_WIDTH, "on_surface", "medium", 13),
		cell(old, OLD_WIDTH, "on_surface_variant"),
		cell(new, NEW_WIDTH, "primary", "medium"),
		changesCell(url, labelKey, noneKey),
	})
end

local function header()
	local function head(key, width)
		local label = ui.label({ text = noctalia.tr(key), flexGrow = 1, fontSize = 11, fontWeight = "bold", color = "on_surface_variant" })
		if width == nil then
			return ui.row({ flexGrow = 1 }, { label })
		end
		return ui.row({ width = width, minWidth = width }, { label })
	end
	return ui.row({ gap = 12, paddingH = 10 }, {
		head("details.name", NAME_WIDTH),
		head("details.installed", OLD_WIDTH),
		head("details.new", NEW_WIDTH),
		head("details.changes", nil),
	})
end

local function withDate(rev, unixSeconds)
	local d = view.date(unixSeconds)
	return d ~= "" and (rev .. "  (" .. d .. ")") or rev
end

-- Rows of one kind that match the search, as table rows.
local function inputRows()
	local rows = {}
	for _, input in ipairs(result.inputs or {}) do
		if matches(input.name, input.source) then
			table.insert(rows, tableRow(
				"input-" .. input.name,
				#rows + 1,
				input.name,
				withDate(input.oldRev, input.oldDate),
				withDate(input.newRev, input.newDate),
				input.url,
				"details.link_commits",
				"details.no_compare"
			))
		end
	end
	return rows
end

local function packageRows()
	local rows = {}
	for _, pkg in ipairs(result.packages or {}) do
		if matches(pkg.name, pkg.old, pkg.new) then
			local labelKey = pkg.changesKind == "releases" and "details.link_releases" or "details.link_changelog"
			local old = pkg.kind == "added" and noctalia.tr("details.not_installed") or pkg.old
			local new = pkg.kind == "removed" and noctalia.tr("details.removed") or pkg.new
			table.insert(rows, tableRow("pkg-" .. pkg.name, #rows + 1, pkg.name, old, new, pkg.changes, labelKey, "details.no_changelog"))
		end
	end
	return rows
end

local function flatpakRows()
	local rows = {}
	for _, fp in ipairs(result.flatpak or {}) do
		if matches(fp.name, fp.app) then
			local new = fp.new ~= "" and fp.new or noctalia.tr("panel.new_commit")
			table.insert(rows, tableRow(
				"fp-" .. fp.installation .. fp.app .. fp.branch,
				#rows + 1,
				fp.name,
				fp.old,
				new,
				fp.changes,
				"details.link_flathub",
				"details.no_changelog"
			))
		end
	end
	return rows
end

-- Same order as the compact panel.
local KINDS = {
	{ id = "packages", glyph = "package", label = "details.packages", field = "packages", rows = packageRows },
	{ id = "flatpak", glyph = "box", label = "details.flatpak", field = "flatpak", rows = flatpakRows },
	{ id = "inputs", glyph = "snowflake", label = "details.inputs", field = "inputs", rows = inputRows },
}

local function filterButton(id, text)
	return ui.button({
		key = "filter-" .. id,
		text = text,
		variant = filter == id and "secondary" or "ghost",
		selected = filter == id,
		controlSize = "sm",
		fontSize = 12,
		onClick = function()
			filter = id
			render()
		end,
	})
end

function render()
	local filters = { filterButton("all", noctalia.tr("details.all", { count = tonumber(result.count) or 0 })) }
	for _, kind in ipairs(KINDS) do
		local list = result[kind.field]
		if type(list) == "table" then
			table.insert(filters, filterButton(kind.id, noctalia.tr(kind.label, { count = #list })))
		end
	end

	local body = {}
	for _, e in ipairs(result.errors or {}) do
		table.insert(body, ui.label({ text = e.message, fontSize = 12, color = "error", maxLines = 4 }))
	end
	local shown = 0
	for _, kind in ipairs(KINDS) do
		if (filter == "all" or filter == kind.id) and type(result[kind.field]) == "table" then
			local rows = kind.rows()
			if #rows > 0 then
				shown += #rows
				table.insert(body, ui.row({ align = "center", gap = 8, paddingH = 4 }, {
					ui.glyph({ name = kind.glyph, size = 16, color = "primary" }),
					ui.label({ text = noctalia.tr(kind.label, { count = #rows }), fontSize = 13, fontWeight = "bold", color = "on_surface" }),
				}))
				table.insert(body, header())
				table.insert(body, ui.column({ gap = 0 }, rows))
			end
		end
	end
	if shown == 0 and result.checkedAt ~= nil then
		local key = query ~= "" and "details.no_match" or (view.incomplete(result) and "details.incomplete" or "details.nothing")
		table.insert(body, ui.label({ text = noctalia.tr(key), fontSize = 13, color = "on_surface_variant" }))
	end

	panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
		ui.row({ align = "center", gap = 10 }, {
			ui.glyph({ name = "snowflake", size = 22, color = "primary" }),
			ui.column({ flexGrow = 1, gap = 2 }, {
				ui.label({ text = noctalia.tr("panel.title"), fontSize = 17, fontWeight = "bold", color = "on_surface" }),
				ui.label({ text = view.status(result), fontSize = 12, color = "on_surface_variant" }),
			}),
			ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
		}),
		ui.row({ align = "center", gap = 8 }, {
			ui.input({
				key = "search",
				value = query,
				placeholder = noctalia.tr("details.search"),
				controlSize = "sm",
				flexGrow = 1,
				focus = true,
				onChange = function(text)
					query = noctalia.string.trim(tostring(text or "")):lower()
					render()
				end,
			}),
			ui.row({ gap = 4 }, filters),
		}),
		ui.scroll({ flexGrow = 1, gap = 8 }, body),
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

-- Every opening starts with an empty search and all kinds shown.
function onOpen(_context)
	query = ""
	filter = "all"
	render()
end

function onCloseClicked()
	panel.close()
end

render()
