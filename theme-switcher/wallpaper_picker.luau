--!nonstrict
-- Multi-select wallpaper picker panel. Opened from the theme editor's
-- "Browse" button or the wallpapers panel's "Add wallpaper" button. The
-- invoking panel leaves its id and target in noctalia.state; picked image
-- paths are appended to the editor draft (target "editor") or to the
-- currently applied theme (target "applied") before the panel is reopened.
--
-- Two host constraints shape this file:
--   1. ui.image decodes its file synchronously while a panel renders, so
--      feeding it full-size wallpapers locks up the shell. We render small
--      thumbnails generated in the background instead.
--   2. A script callback has a ~25ms CPU budget and every fileInfo/fileExists
--      is metered against it. So we never call those per file: the directory
--      is read with a single listDir and cache checks cover only the page on
--      screen.

local themes = require("./themes.luau")

local tr = noctalia.tr
local trp = noctalia.trp

local IMAGE_EXTS = { "png", "jpg", "jpeg", "webp", "bmp", "gif" }

local COLUMNS = 4
local PANEL_WIDTH = 920
local PANEL_PADDING = 28 -- Style::panelPadding * 2 on the host surface
local COLUMN_GAP = 12
local PAGE_SIZE = 24 -- 6 rows of 4
local MAX_JOBS = 4 -- concurrent thumbnail processes

local CARD_W = math.floor((PANEL_WIDTH - PANEL_PADDING - COLUMN_GAP * (COLUMNS - 1)) / COLUMNS)
local CARD_H = math.floor(CARD_W * 9 / 16)
local THUMB_W = 360
local THUMB_H = 203

local dir = ""
local filter = ""
local page = 0
local isOpen = false
local images = {}
local selected = {} -- ordered full paths
local selectedSet = {}
local thumbs = {} -- source path -> cached thumbnail path
local thumbQueue = {}
local thumbPending = {}
local thumbFailed = {}
local thumbActive = 0
local tool = nil
local toolChecked = false
-- Forward declaration so closures defined below capture the assigned upvalue.
local render

local function isImageFile(name)
	local ext = name:match("%.([^.]+)$")
	if ext == nil then
		return false
	end
	local lower = string.lower(ext)
	for _, e in ipairs(IMAGE_EXTS) do
		if lower == e then
			return true
		end
	end
	return false
end

local function defaultDir()
	local wd = noctalia.wallpaperDirectory()
	if type(wd) == "string" and wd ~= "" then
		return wd
	end
	return noctalia.expandPath("~/Pictures/Wallpapers")
end

-- ImageMagick 7/6 first (best thumbnailing), then libvips, then ffmpeg.
local function detectTool()
	if toolChecked then
		return tool
	end
	toolChecked = true
	if noctalia.commandExists("magick") then
		tool = "magick"
	elseif noctalia.commandExists("convert") then
		tool = "convert"
	elseif noctalia.commandExists("vipsthumbnail") then
		tool = "vipsthumbnail"
	elseif noctalia.commandExists("ffmpeg") then
		tool = "ffmpeg"
	else
		tool = nil
	end
	return tool
end

local function thumbDir()
	local d = noctalia.pluginDataDir()
	if d == nil or d == "" then
		return nil
	end
	return d .. "/thumbs"
end

-- djb2 mod 2^32.
local function hashKey(s)
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + s:byte(i)) % 4294967296
	end
	return string.format("%08x", h)
end

local function thumbPathFor(src)
	local d = thumbDir()
	if d == nil then
		return nil
	end
	return d .. "/" .. hashKey(src) .. ".jpg"
end

local function thumbArgv(src, dest)
	local size = THUMB_W .. "x" .. THUMB_H
	if tool == "magick" or tool == "convert" then
		return {
			tool,
			src,
			"-auto-orient",
			"-thumbnail",
			size .. "^",
			"-gravity",
			"center",
			"-extent",
			size,
			"-quality",
			"82",
			dest,
		}
	elseif tool == "vipsthumbnail" then
		return { "vipsthumbnail", src, "-s", size, "-o", dest }
	elseif tool == "ffmpeg" then
		return {
			"ffmpeg",
			"-y",
			"-loglevel",
			"error",
			"-i",
			src,
			"-vf",
			"scale=" .. THUMB_W .. ":" .. THUMB_H .. ":force_original_aspect_ratio=increase,crop=" .. THUMB_W .. ":" .. THUMB_H,
			"-frames:v",
			"1",
			dest,
		}
	end
	return nil
end

local function visibleImages()
	if filter == "" then
		return images
	end
	local needle = filter:lower()
	local out = {}
	for _, img in ipairs(images) do
		if img.name:lower():find(needle, 1, true) ~= nil then
			table.insert(out, img)
		end
	end
	return out
end

local function pageItems(visible)
	local first = page * PAGE_SIZE + 1
	local last = math.min(#visible, first + PAGE_SIZE - 1)
	local out = {}
	for i = first, last do
		out[#out + 1] = visible[i]
	end
	return out
end

local function pageCount()
	local n = #visibleImages()
	return math.max(1, math.ceil(n / PAGE_SIZE))
end

local function pumpThumbs()
	if tool == nil then
		return
	end
	while thumbActive < MAX_JOBS and #thumbQueue > 0 do
		local item = table.remove(thumbQueue, 1)
		local dest = item.thumb
		if thumbs[item.path] == nil and dest ~= nil and not thumbPending[item.path] and not thumbFailed[item.path] then
			thumbPending[item.path] = true
			thumbActive = thumbActive + 1
			local src = item.path
			local argv = thumbArgv(src, dest)
			if argv == nil then
				thumbActive = thumbActive - 1
				thumbPending[src] = nil
				thumbFailed[src] = true
			else
				noctalia.runAsync(argv, function(res)
					thumbActive = thumbActive - 1
					thumbPending[src] = nil
					if res ~= nil and res.exitCode == 0 and noctalia.fileExists(dest) then
						thumbs[src] = dest
					else
						thumbFailed[src] = true
					end
					render()
					pumpThumbs()
				end, 30000)
			end
		end
	end
end

-- Only the page on screen is checked/queued, so the per-callback fileExists
-- count stays tiny (24 at most).
local function ensurePageThumbs()
	if tool == nil then
		return
	end
	for _, item in ipairs(pageItems(visibleImages())) do
		if thumbs[item.path] == nil and not thumbPending[item.path] and not thumbFailed[item.path] then
			local thumb = thumbPathFor(item.path)
			item.thumb = thumb
			if thumb ~= nil and noctalia.fileExists(thumb) then
				thumbs[item.path] = thumb
			else
				table.insert(thumbQueue, item)
			end
		end
	end
	pumpThumbs()
end

local function refresh()
	images = {}
	page = 0
	thumbQueue = {}
	local d = thumbDir()
	if d ~= nil then
		noctalia.mkdirAll(d)
	end
	local names = noctalia.listDir(dir)
	if names == nil then
		return
	end
	for _, name in ipairs(names) do
		if name:sub(1, 1) ~= "." and isImageFile(name) then
			table.insert(images, { name = name, path = dir .. "/" .. name })
		end
	end
	table.sort(images, function(a, b)
		return a.name:lower() < b.name:lower()
	end)
end

local function toggle(path)
	if selectedSet[path] then
		selectedSet[path] = nil
		for i, p in ipairs(selected) do
			if p == path then
				table.remove(selected, i)
				break
			end
		end
	else
		selectedSet[path] = true
		table.insert(selected, path)
	end
	render()
end

local function appendUnique(list, items)
	local seen = {}
	for _, p in ipairs(list) do
		seen[p] = true
	end
	for _, p in ipairs(items) do
		if not seen[p] then
			seen[p] = true
			table.insert(list, p)
		end
	end
end

local function applySelection()
	if #selected == 0 then
		return
	end
	if noctalia.state.get("pickerTarget") == "editor" then
		local draft = noctalia.state.get("editorDraft")
		if type(draft) == "table" then
			if type(draft.wallpapers) ~= "table" then
				draft.wallpapers = {}
			end
			appendUnique(draft.wallpapers, selected)
			noctalia.state.set("editorDraft", draft)
		end
	else
		local theme = themes.byId(themes.lastAppliedId())
		if theme ~= nil then
			local merged = {}
			for _, p in ipairs(themes.wallpapersOf(theme)) do
				table.insert(merged, p)
			end
			if #merged == 0 then
				theme.wallpaperIndex = 0
			end
			appendUnique(merged, selected)
			theme.wallpapers = merged
			themes.upsert(theme)
		end
	end
end

-- Reopen the panel that launched the picker (if any) and forget the request.
local function returnToCaller()
	local returnPanel = noctalia.state.get("pickerReturn")
	noctalia.state.set("pickerReturn", nil)
	noctalia.state.set("pickerTarget", nil)
	if type(returnPanel) == "string" and returnPanel ~= "" then
		noctalia.togglePanel(returnPanel)
	else
		panel.close()
	end
end

-- Filename-only fallback used when no thumbnail tool is installed.
local function listRow(item)
	local isSelected = selectedSet[item.path] == true
	return ui.row({
		key = "img-" .. item.path,
		gap = 8,
		align = "center",
		padding = 8,
		radius = 8,
		fill = isSelected and "surface_variant" or "#00000000",
		onClick = function()
			toggle(item.path)
		end,
	}, {
		ui.glyph({
			name = isSelected and "square-check" or "square",
			size = 18,
			color = isSelected and "primary" or "on_surface_variant",
		}),
		ui.label({
			text = item.name,
			fontSize = 13,
			maxLines = 1,
			flexGrow = 1,
			color = isSelected and "primary" or "on_surface",
		}),
	})
end

local function tile(item)
	local isSelected = selectedSet[item.path] == true
	local thumb = thumbs[item.path]
	local border = isSelected and "primary" or "outline"
	local borderWidth = isSelected and 3 or 1

	local preview
	if thumb ~= nil then
		preview = ui.image({
			path = thumb,
			width = CARD_W,
			height = CARD_H,
			radius = 8,
			fit = "cover",
			border = border,
			borderWidth = borderWidth,
		})
	else
		preview = ui.column({
			width = CARD_W,
			height = CARD_H,
			radius = 8,
			fill = "surface_variant",
			border = border,
			borderWidth = borderWidth,
			align = "center",
			justify = "center",
		}, {
			ui.glyph({ name = "photo", size = 24, color = "on_surface_variant" }),
		})
	end

	local labelRow = {}
	if isSelected then
		table.insert(labelRow, ui.glyph({ name = "check", size = 14, color = "primary" }))
	end
	table.insert(labelRow, ui.label({
		text = item.name,
		fontSize = 11,
		maxLines = 1,
		flexGrow = 1,
		color = isSelected and "primary" or "on_surface_variant",
	}))

	return ui.column({
		key = "tile-" .. item.path,
		width = CARD_W,
		gap = 4,
		align = "stretch",
		onClick = function()
			toggle(item.path)
		end,
	}, {
		preview,
		ui.row({ gap = 4, align = "center" }, labelRow),
	})
end

local function grid(items)
	local tiles = {}
	for _, item in ipairs(items) do
		tiles[#tiles + 1] = tile(item)
	end

	local rows = {}
	local row = {}
	for _, t in ipairs(tiles) do
		row[#row + 1] = t
		if #row == COLUMNS then
			table.insert(rows, ui.row({ gap = COLUMN_GAP, align = "start" }, row))
			row = {}
		end
	end
	if #row > 0 then
		table.insert(rows, ui.row({ gap = COLUMN_GAP, align = "start" }, row))
	end
	return ui.column({ gap = 10, align = "stretch" }, rows)
end

local function listBody(visible)
	local items = pageItems(visible)
	if #items == 0 then
		local msg = (#images == 0) and tr("picker.empty_dir") or tr("picker.no_matches")
		return { ui.label({ text = msg, color = "on_surface_variant" }) }
	end
	if tool == nil then
		local rows = {}
		for _, item in ipairs(items) do
			rows[#rows + 1] = listRow(item)
		end
		return { ui.column({ gap = 4, align = "stretch" }, rows) }
	end
	return { grid(items) }
end

render = function()
	if not isOpen then
		return
	end
	local visible = visibleImages()
	local count = #selected
	local pages = pageCount()

	local children = {
		ui.row({ align = "center", gap = 8 }, {
			ui.label({ text = tr("picker.title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
			ui.label({ text = trp("picker.image_count", #visible), fontSize = 12, color = "on_surface_variant" }),
			ui.button({ glyph = "close", variant = "ghost", onClick = "onCancel" }),
		}),
		ui.separator({}),
		ui.label({ text = dir, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
		ui.input({
			key = "picker-filter",
			value = filter,
			placeholder = tr("picker.filter_placeholder"),
			onChange = "onFilterChange",
		}),
	}

	if pages > 1 then
		table.insert(children, ui.row({ align = "center", gap = 8 }, {
			ui.button({
				glyph = "chevron-left",
				variant = "ghost",
				tooltip = tr("picker.prev_page"),
				enabled = page > 0,
				onClick = "onPrevPage",
			}),
			ui.label({
				text = tr("picker.page", { page = page + 1, pages = pages }),
				fontSize = 12,
				color = "on_surface_variant",
			}),
			ui.button({
				glyph = "chevron-right",
				variant = "ghost",
				tooltip = tr("picker.next_page"),
				enabled = page + 1 < pages,
				onClick = "onNextPage",
			}),
			ui.spacer({ flexGrow = 1 }),
		}))
	end

	table.insert(children, ui.scroll({ flexGrow = 1, gap = 6, padding = 4 }, listBody(visible)))
	table.insert(children, ui.row({ gap = 8, align = "center" }, {
		ui.button({
			text = tr("picker.select_all"),
			variant = "outline",
			enabled = #visible > 0,
			onClick = "onSelectAll",
		}),
		ui.button({ text = tr("picker.clear"), variant = "ghost", enabled = count > 0, onClick = "onClear" }),
		ui.spacer({ flexGrow = 1 }),
		ui.button({ text = tr("picker.cancel"), variant = "ghost", onClick = "onCancel" }),
		ui.button({ text = trp("picker.add", count), variant = "primary", enabled = count > 0, onClick = "onConfirm" }),
	}))

	panel.render(ui.column({ flexGrow = 1, gap = 10, padding = 12, align = "stretch" }, children))
end

function onOpen(_context)
	isOpen = true
	detectTool()
	dir = defaultDir()
	selected = {}
	selectedSet = {}
	filter = ""
	refresh()
	-- Render placeholders first so the panel is never blank, then look up cached
	-- thumbnails for this page and render again.
	render()
	ensurePageThumbs()
	render()
end

function onClose()
	isOpen = false
	-- Dismissed without confirming: don't leave a stale request behind.
	if noctalia.state.get("pickerReturn") ~= nil then
		noctalia.state.set("pickerReturn", nil)
		noctalia.state.set("pickerTarget", nil)
	end
end

function onFilterChange(value)
	filter = value or ""
	page = 0
	ensurePageThumbs()
	render()
end

function onPrevPage()
	if page > 0 then
		page = page - 1
		ensurePageThumbs()
		render()
	end
end

function onNextPage()
	if page + 1 < pageCount() then
		page = page + 1
		ensurePageThumbs()
		render()
	end
end

function onSelectAll()
	for _, img in ipairs(visibleImages()) do
		if not selectedSet[img.path] then
			selectedSet[img.path] = true
			table.insert(selected, img.path)
		end
	end
	render()
end

function onClear()
	selected = {}
	selectedSet = {}
	render()
end

function onConfirm()
	applySelection()
	returnToCaller()
end

function onCancel()
	returnToCaller()
end
