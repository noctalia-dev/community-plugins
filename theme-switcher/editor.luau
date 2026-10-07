--!nonstrict
-- Theme editor panel: create or edit a saved theme (title, palette source +
-- selection, wallpaper, screenshot). Opens from the carousel; the id of the
-- theme to edit is handed over through noctalia.state.editThemeId ("" = new).

local themes = require("./themes.luau")
local palette = require("./palette.luau")

local tr = noctalia.tr
local EDITOR_PANEL = "theblackdon/theme-switcher:editor"

local isOpen = false
local draft = nil -- editable theme candidate
local editId = nil -- nil | "" = create new, otherwise the theme id
local paletteOptions = {}
local communityNames = {}
local communityLoaded = false
local showBrowse = false
local browseDir = ""
local browseFiles = {}
local screenshotBusy = false
-- ui.input is uncontrolled: its value seeds only when the control is first
-- created. Bumping these keys when we set a path programmatically forces a
-- fresh control that re-seeds from the new value.
local screenshotSeed = 0
-- Bumped on every open so the uncontrolled inputs are recreated (and re-seeded from
-- the current draft) instead of keeping the previous theme's text.
local formSeed = 0
-- Forward declaration so closures defined below (ensureCommunity, rebuildPaletteOptions)
-- capture this upvalue rather than a nil global. Assigned by `render = function ...`.
local render

local SOURCE_KEYS = palette.SOURCES
local IMAGE_EXTS = { "png", "jpg", "jpeg", "webp", "bmp", "gif" }

local function indexOf(list, value)
	for i, v in ipairs(list) do
		if v == value then
			return i - 1
		end
	end
	return -1
end

-- Capture the current monitor with the first available tool, saving to a known path.
local function captureCommand(outPath)
	if noctalia.commandExists("spectacle") then
		-- -m captures only the current monitor (-f would stitch every monitor).
		-- A short delay lets the closing editor panel fully leave the screen first.
		return { "spectacle", "-b", "-m", "-d", "300", "-o", outPath }
	end
	if noctalia.commandExists("grim") then
		local out = noctalia.focusedOutputName()
		if out ~= nil and out ~= "" then
			return { "grim", "-o", out, outPath }
		end
		return { "grim", outPath }
	end
	if noctalia.commandExists("gnome-screenshot") then
		return { "gnome-screenshot", "-f", outPath }
	end
	if noctalia.commandExists("scrot") then
		return { "scrot", outPath }
	end
	if noctalia.commandExists("maim") then
		return { "maim", outPath }
	end
	return nil
end

local function defaultScreenshotDir()
	return noctalia.expandPath("~/Pictures/Screenshots")
end

local function copyTheme(t)
	local wallpapers = {}
	for _, wp in ipairs(themes.wallpapersOf(t)) do
		table.insert(wallpapers, wp)
	end
	return {
		id = t.id,
		title = t.title or "",
		source = t.source or "builtin",
		palette = t.palette or "",
		wallpaperScheme = t.wallpaperScheme or "m3-content",
		wallpapers = wallpapers,
		wallpaperIndex = t.wallpaperIndex or 0,
		screenshotPath = t.screenshotPath or "",
	}
end

local function freshDraft()
	-- A clean slate for a new theme. (Editing loads the saved theme via copyTheme.)
	return {
		title = "",
		source = "builtin",
		palette = "Noctalia",
		wallpaperScheme = "m3-content",
		wallpapers = {},
		wallpaperIndex = 0,
		screenshotPath = "",
	}
end

local function ensureCommunity()
	if communityLoaded then
		return
	end
	palette.listCommunity(function(names)
		communityLoaded = true
		communityNames = names
		if isOpen and draft ~= nil and draft.source == "community" then
			paletteOptions = names
			render()
		end
	end)
end

local function rebuildPaletteOptions()
	local source = draft.source
	paletteOptions = {}
	if source == "builtin" then
		paletteOptions = palette.BUILTIN
	elseif source == "wallpaper" then
		paletteOptions = palette.SCHEMES
	elseif source == "custom" then
		paletteOptions = palette.listCustom()
	elseif source == "community" then
		if communityLoaded then
			paletteOptions = communityNames
		else
			paletteOptions = { tr("editor.loading") }
			ensureCommunity()
		end
	end

	-- On a fresh source the previous value may not be a valid option; default
	-- builtin/wallpaper to their first entry and leave community/custom empty.
	if #paletteOptions > 0 then
		local current = (source == "wallpaper") and draft.wallpaperScheme or draft.palette
		if indexOf(paletteOptions, current) < 0 then
			if source == "builtin" or source == "wallpaper" then
				local first = paletteOptions[1]
				if source == "wallpaper" then
					draft.wallpaperScheme = first
				else
					draft.palette = first
				end
			end
		end
	end
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

-- The wallpaper image currently applied to an output, if any.
local function currentWallpaperPath()
	local conn = noctalia.focusedOutputName()
	if conn ~= nil and conn ~= "" then
		local p = noctalia.wallpaperPath(conn)
		if p ~= nil and p ~= "" then
			return p
		end
	end
	local outs = noctalia.outputs()
	if outs ~= nil then
		for _, out in ipairs(outs) do
			if out.name ~= nil then
				local p = noctalia.wallpaperPath(out.name)
				if p ~= nil and p ~= "" then
					return p
				end
			end
		end
	end
	return ""
end

local function sourceOptions()
	local out = {}
	for _, key in ipairs(SOURCE_KEYS) do
		table.insert(out, tr("source." .. key))
	end
	return out
end

local function wallpaperRemove(index)
	if type(draft.wallpapers) ~= "table" then
		return
	end
	table.remove(draft.wallpapers, index)
	render()
end

local function wallpaperRows()
	local wps = draft.wallpapers or {}
	local rows = {}
	if #wps == 0 then
		table.insert(rows, ui.label({ text = tr("editor.no_wallpapers") }))
	else
		for i, wp in ipairs(wps) do
			table.insert(rows, ui.row({ gap = 8, align = "center" }, {
				ui.label({ text = wp, fontSize = 12, maxLines = 1, flexGrow = 1 }),
				ui.button({ glyph = "trash", variant = "ghost", controlSize = "sm", onClick = function()
					wallpaperRemove(i)
				end }),
			}))
		end
	end
	return ui.column({ gap = 6, align = "stretch" }, rows)
end

render = function()
	local titleText = tr("editor.title_new")
	if editId ~= nil and editId ~= "" then
		titleText = tr("editor.title_edit")
	end

	local children = {
		ui.row({ align = "center", gap = 8 }, {
			ui.label({ text = titleText, fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
			ui.button({ glyph = "close", variant = "ghost", onClick = "onCancel" }),
		}),
		ui.separator({}),
	}

	-- Everything above the footer lives in a scroll region: a long wallpaper
	-- list must not push the Save/Cancel buttons off the panel.
	local body = {
		ui.column({ gap = 8, padding = 6 }, {
			ui.label({ text = tr("editor.title"), fontSize = 12, color = "on_surface_variant" }),
			ui.input({ key = "ed-title-" .. formSeed, value = draft.title, placeholder = tr("editor.title_placeholder"), onChange = "onTitleChange" }),

			ui.label({ text = tr("editor.source"), fontSize = 12, color = "on_surface_variant" }),
			ui.select({ key = "ed-source", options = sourceOptions(), selectedIndex = indexOf(SOURCE_KEYS, draft.source), onChange = "onSourceChange" }),

			ui.label({ text = tr("editor.palette"), fontSize = 12, color = "on_surface_variant" }),
			ui.select({
				key = "ed-palette-" .. draft.source,
				options = paletteOptions,
				selectedIndex = indexOf(paletteOptions, (draft.source == "wallpaper") and draft.wallpaperScheme or draft.palette),
				onChange = "onPaletteChange",
				enabled = #paletteOptions > 0,
			}),

			ui.label({ text = tr("editor.wallpapers"), fontSize = 12, color = "on_surface_variant" }),
			wallpaperRows(),
			ui.row({ gap = 8, align = "center" }, {
				ui.button({ text = tr("editor.wallpaper_browse"), variant = "outline", onClick = "onWallpaperBrowse" }),
				ui.spacer({ flexGrow = 1 }),
				ui.button({ text = tr("editor.current_wallpaper"), variant = "outline", onClick = "onUseCurrent" }),
			}),

			ui.label({ text = tr("editor.screenshot"), fontSize = 12, color = "on_surface_variant" }),
			ui.input({ key = "ed-screenshot-" .. formSeed .. "-" .. screenshotSeed, value = draft.screenshotPath, placeholder = tr("editor.screenshot_placeholder"), onChange = "onScreenshotChange" }),
			ui.button({
				text = screenshotBusy and tr("editor.capturing") or tr("editor.capture"),
				variant = "outline",
				enabled = not screenshotBusy,
				contentAlign = "start",
				onClick = "onCapture",
			}),
		}),
	}

	if showBrowse then
		local browseBody
		if #browseFiles == 0 then
			browseBody = ui.label({ text = tr("editor.no_images") })
		else
			browseBody = ui.select({ key = "ed-browse", options = browseFiles, selectedIndex = 0, onChange = "onBrowsePick" })
		end
		table.insert(body, ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = tr("editor.browse_title"), fontSize = 12, flexGrow = 1 }),
			browseBody,
			ui.button({ glyph = "close", variant = "ghost", onClick = "onBrowseCancel" }),
		}))
	end

	table.insert(children, ui.scroll({ flexGrow = 1, gap = 8, padding = 0 }, {
		ui.column({ gap = 8, align = "stretch" }, body),
	}))

	local footer = {
		ui.spacer({ flexGrow = 1 }),
	}
	if editId ~= nil and editId ~= "" then
		table.insert(footer, ui.button({ text = tr("editor.delete"), variant = "destructive", onClick = "onDelete" }))
	end
	table.insert(footer, ui.button({ text = tr("editor.cancel"), variant = "ghost", onClick = "onCancel" }))
	table.insert(footer, ui.button({ text = tr("editor.save"), variant = "primary", onClick = "onSave" }))
	table.insert(children, ui.row({ gap = 8, align = "center", justify = "end" }, footer))

	panel.render(ui.column({ gap = 8, padding = 12, flexGrow = 1 }, children))
end

function onOpen(_context)
	isOpen = true
	formSeed = formSeed + 1
	local savedDraft = noctalia.state.get("editorDraft")
	if type(savedDraft) == "table" then
		-- Reopening after a capture hid the panel: restore the stashed form as-is.
		draft = savedDraft
		local savedEditId = noctalia.state.get("editorEditId")
		editId = (type(savedEditId) == "string" and savedEditId ~= "") and savedEditId or nil
		noctalia.state.set("editorDraft", nil)
		noctalia.state.set("editorEditId", nil)
	else
		local requested = noctalia.state.get("editThemeId")
		if type(requested) == "string" and requested ~= "" then
			local existing = themes.byId(requested)
			if existing ~= nil then
				editId = existing.id
				draft = copyTheme(existing)
			else
				editId = nil
				draft = freshDraft()
			end
		else
			editId = nil
			draft = freshDraft()
		end
	end
	communityLoaded = false
	communityNames = {}
	showBrowse = false
	rebuildPaletteOptions()
	if draft.source == "community" then
		ensureCommunity()
	end
	render()
end

function onClose()
	isOpen = false
end

function onTitleChange(value)
	draft.title = value
end

function onSourceChange(index)
	local idx = tonumber(index) or 0
	draft.source = SOURCE_KEYS[idx + 1] or "builtin"
	rebuildPaletteOptions()
	render()
end

function onPaletteChange(index)
	local idx = tonumber(index) or 0
	local value = paletteOptions[idx + 1]
	if value ~= nil then
		if draft.source == "wallpaper" then
			draft.wallpaperScheme = value
		else
			draft.palette = value
		end
	end
	render() -- selects are controlled; reflect the new selection
end

function onScreenshotChange(value)
	draft.screenshotPath = value
end

function onUseCurrent()
	local p = currentWallpaperPath()
	if p ~= "" then
		if type(draft.wallpapers) ~= "table" then
			draft.wallpapers = {}
		end
		table.insert(draft.wallpapers, p)
	else
		noctalia.notifyError(tr("editor.wallpaper_current_fail"))
	end
	render()
end

function onWallpaperBrowse()
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
		if type(draft.wallpapers) ~= "table" then
			draft.wallpapers = {}
		end
		table.insert(draft.wallpapers, browseDir .. "/" .. name)
	end
	showBrowse = false
	render()
end

function onBrowseCancel()
	showBrowse = false
	render()
end

function onCapture()
	if screenshotBusy then
		return
	end
	local dir = defaultScreenshotDir()
	local outPath = dir .. "/theme-screenshot-" .. tostring(noctalia.nowMs()) .. ".png"
	noctalia.mkdirAll(dir)
	local cmd = captureCommand(outPath)
	if cmd == nil then
		noctalia.notifyError(tr("editor.capture_fail_title"), tr("editor.capture_fail_body"))
		return
	end
	screenshotBusy = true
	-- Hide the editor so it is not in the shot; stash the form first so we can
	-- restore it (and any unsaved edits) when the panel reopens.
	noctalia.state.set("editorDraft", draft)
	noctalia.state.set("editorEditId", editId)
	panel.close()
	noctalia.runAsync(cmd, function(res)
		screenshotBusy = false
		local ok = res ~= nil and res.exitCode == 0 and noctalia.fileExists(outPath)
		if ok then
			local stashed = noctalia.state.get("editorDraft")
			if type(stashed) == "table" then
				stashed.screenshotPath = outPath
				noctalia.state.set("editorDraft", stashed)
			end
		else
			noctalia.notifyError(tr("editor.capture_fail_title"), tr("editor.capture_fail_body"))
		end
		noctalia.togglePanel(EDITOR_PANEL)
	end, 20000)
end

function onSave()
	local t = noctalia.string.trim(draft.title)
	if t == "" then
		noctalia.notifyError(tr("editor.missing_title"))
		return
	end
	local id = editId
	if id == nil or id == "" then
		id = themes.slug(t)
	end
	local theme = {
		id = id,
		title = t,
		source = draft.source or "builtin",
		palette = (draft.source == "wallpaper") and "" or (draft.palette or ""),
		wallpaperScheme = draft.wallpaperScheme or "m3-content",
		wallpapers = draft.wallpapers or {},
		wallpaperIndex = draft.wallpaperIndex or 0,
		screenshotPath = draft.screenshotPath or "",
	}
	themes.upsert(theme)
	editId = id
	noctalia.notify(tr("editor.saved"), tr("editor.saved_body", { title = theme.title }))
	panel.close()
end

function onCancel()
	panel.close()
end

function onDelete()
	if editId ~= nil and editId ~= "" then
		local existing = themes.byId(editId)
		themes.remove(editId)
		if existing ~= nil then
			noctalia.notify(tr("editor.deleted"), tr("editor.deleted_body", { title = existing.title }))
		end
	end
	panel.close()
end
