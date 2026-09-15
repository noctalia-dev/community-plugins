--!nonstrict
-- Wallpaper panel: browse the wallpapers that belong to the currently applied
-- theme in a 2-column scroll grid, switch between them, and add new ones from a
-- browse dropdown (without re-applying the palette).

local themes = require("./themes.luau")
local tr = noctalia.tr

local COLUMNS = 2
local IMAGE_EXTS = { "png", "jpg", "jpeg", "webp", "bmp", "gif" }

local isOpen = false
local showBrowse = false
local browseDir = ""
local browseFiles = {}

-- Forward declaration so closures defined below capture the assigned upvalue.
local render

local function appliedTheme()
	return themes.byId(themes.lastAppliedId())
end

local function switchWallpaper(index)
	local theme = appliedTheme()
	if theme == nil then
		return
	end
	local wps = themes.wallpapersOf(theme)
	if index < 0 or index >= #wps then
		return
	end
	theme.wallpaperIndex = index
	themes.upsert(theme)
	local wp = themes.currentWallpaper(theme)
	if wp ~= "" then
		noctalia.setWallpaper(wp)
	end
	render()
end

local function addWallpaper(path)
	local theme = appliedTheme()
	if theme == nil or path == "" then
		return
	end
	if type(theme.wallpapers) ~= "table" then
		theme.wallpapers = {}
	end
	table.insert(theme.wallpapers, path)
	if #theme.wallpapers == 1 then
		theme.wallpaperIndex = 0
	end
	themes.upsert(theme)
end

local function nextWallpaper()
	local theme = appliedTheme()
	if theme == nil then
		return
	end
	local wps = themes.wallpapersOf(theme)
	if #wps == 0 then
		return
	end
	local idx = (theme.wallpaperIndex or 0) + 1
	if idx >= #wps then
		idx = 0
	end
	switchWallpaper(idx)
end

local function listImages(dir)
	local files = {}
	if dir ~= nil and dir ~= "" then
		local entries = noctalia.listDir(dir)
		if entries ~= nil then
			for _, name in ipairs(entries) do
				local ext = name:match("%.([^.]+)$")
				if ext ~= nil then
					local lower = string.lower(ext)
					for _, e in ipairs(IMAGE_EXTS) do
						if lower == e then
							table.insert(files, name)
							break
						end
					end
				end
			end
		end
	end
	table.sort(files)
	return files
end

local function cardLabel(wp, selected)
	local row = { ui.label({ text = wp, fontSize = 11, maxLines = 1, flexGrow = 1 }) }
	if selected then
		table.insert(row, ui.glyph({ name = "check", size = 16, color = "primary" }))
	end
	return ui.row({ gap = 6, align = "center" }, row)
end

render = function()
	local theme = appliedTheme()
	local active = -1
	local wps = {}
	if theme ~= nil then
		wps = themes.wallpapersOf(theme)
		active = theme.wallpaperIndex or 0
		if active < 0 or active >= #wps then
			active = 0
		end
	end

	local children = {
		ui.row({ align = "center", gap = 8 }, {
			ui.label({ text = tr("wallpapers.title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
			ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
		}),
		ui.separator({}),
	}

	if theme == nil then
		table.insert(children, ui.label({ text = tr("wallpapers.none_applied") }))
	elseif #wps == 0 and not showBrowse then
		table.insert(children, ui.label({ text = tr("wallpapers.no_wallpapers", { title = theme.title }) }))
	elseif #wps > 0 then
		local rows = {}
		local row = {}
		for i, wp in ipairs(wps) do
			local selected = (i - 1) == active
			local card = ui.column({
				key = "wp-" .. i,
				width = 335,
				height = 222,
				radius = 10,
				padding = 8,
				gap = 6,
				borderWidth = selected and 2 or 0,
				onClick = function()
					switchWallpaper(i - 1)
				end,
			}, {
				ui.image({ path = wp, width = 319, height = 178, radius = 8, fit = "cover" }),
				cardLabel(wp, selected),
			})
			table.insert(row, card)
			if #row == COLUMNS then
				table.insert(rows, ui.row({ gap = 10, align = "start" }, row))
				row = {}
			end
		end
		if #row > 0 then
			table.insert(rows, ui.row({ gap = 10, align = "start" }, row))
		end

		table.insert(children, ui.scroll({ flexGrow = 1, gap = 10, padding = 4 }, {
			ui.column({ gap = 10, align = "stretch" }, rows),
		}))
	end

	table.insert(children, ui.row({ gap = 8, align = "center" }, {
		ui.spacer({ flexGrow = 1 }),
		ui.button({ text = tr("wallpapers.add"), variant = "outline", onClick = "onBrowse" }),
	}))

	if showBrowse then
		local body
		if #browseFiles == 0 then
			body = ui.label({ text = tr("wallpapers.no_images_found") })
		else
			body = ui.select({ key = "wp-browse", options = browseFiles, selectedIndex = 0, onChange = "onBrowsePick" })
		end
		table.insert(children, ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = tr("wallpapers.browse_title"), fontSize = 12, flexGrow = 1 }),
			body,
			ui.button({ glyph = "close", variant = "ghost", onClick = "onBrowseCancel" }),
		}))
	end

	panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 12, align = "stretch" }, children))
end

function onOpen(_context)
	isOpen = true
	showBrowse = false
	render()
end

function onClose()
	isOpen = false
end

-- IPC entry point for keyboard bindings:
--   noctalia msg plugin theblackdon/theme-switcher:wallpapers all random
--   noctalia msg plugin theblackdon/theme-switcher:wallpapers all next
function onIpc(event)
	if event == "random" then
		themes.randomizeWallpaper()
	elseif event == "next" then
		nextWallpaper()
	end
	if isOpen then
		render()
	end
end

function onCloseClicked()
	panel.close()
end

function onBrowse()
	if showBrowse then
		showBrowse = false
		render()
		return
	end
	local dir = noctalia.wallpaperDirectory()
	if type(dir) ~= "string" or dir == "" then
		dir = noctalia.expandPath("~/Pictures/Wallpapers")
	end
	browseDir = dir
	browseFiles = listImages(dir)
	showBrowse = true
	render()
end

function onBrowsePick(index)
	local idx = tonumber(index) or 0
	local name = browseFiles[idx + 1]
	if name ~= nil then
		addWallpaper(browseDir .. "/" .. name)
	end
	showBrowse = false
	render()
end

function onBrowseCancel()
	showBrowse = false
	render()
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
