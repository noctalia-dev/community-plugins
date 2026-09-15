--!nonstrict
-- Theme grid panel: browse saved themes in a scrollable grid and apply one
-- immediately by clicking its card (Enter/Space on a focused card works too).
-- Opens the editor from each card's pencil button.

local themes = require("./themes.luau")
local applyMod = require("./apply.luau")

-- Forward declaration so the async apply callback (defined above `render`) captures
-- this upvalue instead of a nil global. Assigned by `render = function ...`.
local render

local EDITOR_PANEL = "theblackdon/theme-switcher:editor"
local COLUMNS = 4

local isOpen = false
local applying = false

local function tr(key, subst)
	return noctalia.tr(key, subst)
end

local function imagePath(theme)
	if theme.screenshotPath ~= nil and theme.screenshotPath ~= "" then
		return theme.screenshotPath
	end
	return themes.currentWallpaper(theme)
end

local function paletteSummary(theme)
	local source = theme.source or "builtin"
	local value = theme.palette or ""
	if source == "wallpaper" then
		value = theme.wallpaperScheme or "m3-content"
	end
	local label = tr("source." .. source)
	if value ~= "" then
		label = label .. " — " .. value
	end
	return label
end

local function applyTheme(id)
	if applying then
		return
	end
	local theme = themes.byId(id)
	if theme == nil then
		return
	end
	applying = true
	applyMod.apply(theme, function(ok)
		applying = false
		-- Switching is silent: succeed or fail without a notification.
		if ok then
			themes.setLastApplied(id)
		end
		render()
	end)
end

local function editTheme(id)
	noctalia.state.set("editThemeId", id)
	noctalia.togglePanel(EDITOR_PANEL)
end

local function deleteTheme(id)
	local theme = themes.byId(id)
	if theme == nil then
		return
	end
	themes.remove(id)
	noctalia.notify(tr("editor.deleted"), tr("editor.deleted_body", { title = theme.title }))
	render()
end

local function addTheme()
	noctalia.state.set("editThemeId", "")
	noctalia.togglePanel(EDITOR_PANEL)
end

local function card(theme, active)
	local children = {
		ui.row({ align = "center", justify = "space_between", gap = 4 }, {
			ui.label({
				text = theme.title,
				fontSize = 14,
				fontWeight = "bold",
				flexGrow = 1,
				maxLines = 1,
			}),
			ui.button({ glyph = "pencil", variant = "ghost", controlSize = "sm", onClick = function() editTheme(theme.id) end }),
			ui.button({ glyph = "trash", variant = "ghost", controlSize = "sm", onClick = function() deleteTheme(theme.id) end }),
		}),
	}

	local img = imagePath(theme)
	if img ~= "" then
		table.insert(children, ui.image({ path = img, width = 190, height = 116, radius = 8, fit = "cover" }))
	else
		table.insert(children, ui.column({
			width = 190,
			height = 116,
			radius = 8,
			fill = "surface_variant",
			align = "center",
			justify = "center",
		}, { ui.glyph({ name = "palette", size = 32, color = "on_surface_variant" }) }))
	end

	table.insert(children, ui.label({ text = paletteSummary(theme), fontSize = 11, color = "on_surface_variant", maxLines = 2 }))

	return ui.column({
		key = "card-" .. theme.id,
		width = 210,
		height = 250,
		radius = 12,
		padding = 10,
		gap = 6,
		borderWidth = active and 2 or 0,
		onClick = function()
			applyTheme(theme.id)
		end,
	}, children)
end

render = function()
	local list = themes.list()
	local total = #list

	local root = {
		ui.row({ align = "center", gap = 8 }, {
			ui.label({ text = tr("carousel.title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
			ui.button({ glyph = "plus", variant = "primary", tooltip = tr("carousel.add"), onClick = addTheme }),
			ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
		}),
		ui.separator({}),
	}

	if total == 0 then
		table.insert(root, ui.label({ text = tr("carousel.empty") }))
	else
		local currentId = themes.lastAppliedId()
		local rows = {}
		local row = {}
		for _, theme in ipairs(list) do
			table.insert(row, card(theme, theme.id == currentId))
			if #row == COLUMNS then
				table.insert(rows, ui.row({ gap = 10, align = "start" }, row))
				row = {}
			end
		end
		if #row > 0 then
			table.insert(rows, ui.row({ gap = 10, align = "start" }, row))
		end

		table.insert(root, ui.scroll({ flexGrow = 1, gap = 10, padding = 4 }, {
			ui.column({ gap = 10, align = "stretch" }, rows),
		}))
	end

	panel.render(ui.column({ gap = 10, padding = 12 }, root))
end

function onOpen(_context)
	isOpen = true
	render()
end

function onClose()
	isOpen = false
end

function onCloseClicked()
	panel.close()
end


noctalia.state.watch("themes", function()
	if isOpen then
		render()
	end
end)
noctalia.state.watch("lastAppliedId", function()
	if isOpen then
		render()
	end
end)
