-- Lunar Workspaces bar widget
-- Renders one pill per workspace (focused/urgent/occupied/empty), reading
-- state from the background service (service.luau) via noctalia.state.watch().

local STATE_KEY = "lunar_workspaces"

local wsState = noctalia.state.get(STATE_KEY) or {}
local renderedVertical = nil
-- Forward-declared: gif frame extraction finishes asynchronously (outside
-- any update()/state-change tick), and needs to trigger a render itself to
-- pick up the now-ready frames instead of leaving the static fallback
-- showing until something unrelated happens to re-render next.
local render

local compositorSetting = noctalia.getConfig("compositor") or "auto"
local displayMode = noctalia.getConfig("workspace_display_mode") or "all"
local workspaceCount = tonumber(noctalia.getConfig("workspace_count")) or 9

-- Bool settings must not use `or true`: that would coerce an explicit
-- `false` back to `true`. Only nil (unset) should fall back to the default.
local function getBoolConfig(key, default)
	local v = noctalia.getConfig(key)
	if v == nil then
		return default
	end
	return v
end

local enableAnimation = getBoolConfig("enable_animation", true)

local iconFocused = noctalia.getConfig("icon_focused") or "🌕"
local iconUrgent = noctalia.getConfig("icon_urgent") or "🌟"
local iconOccupied = noctalia.getConfig("icon_occupied") or "🌗"
local iconEmpty = noctalia.getConfig("icon_empty") or "🌙"

local sizeFocused = tonumber(noctalia.getConfig("size_focused")) or 22
local sizeUrgent = tonumber(noctalia.getConfig("size_urgent")) or 20
local sizeOccupied = tonumber(noctalia.getConfig("size_occupied")) or 18
local sizeEmpty = tonumber(noctalia.getConfig("size_empty")) or 16

local focusedPillStyle = noctalia.getConfig("focused_pill_style") or "fill"
local focusedColor = noctalia.getConfig("focused_color") or "primary"
local urgentPillStyle = noctalia.getConfig("urgent_pill_style") or "fill"
local urgentColor = noctalia.getConfig("urgent_color") or "error"
local occupiedPillStyle = noctalia.getConfig("occupied_pill_style") or "ghost"
local occupiedColor = noctalia.getConfig("occupied_color") or "secondary"
local emptyPillStyle = noctalia.getConfig("empty_pill_style") or "ghost"
local emptyColor = noctalia.getConfig("empty_color") or "surface_variant"

-- True if an icon setting value looks like an image path rather than an
-- emoji or plain glyph. Strips a "file://" prefix (added by the native file
-- picker) before checking.
local function isImagePath(v)
	if type(v) ~= "string" then
		return false
	end
	local path = v:gsub("^file://", "")
	if path:sub(1, 1) == "/" then
		return true
	end
	return path:lower():match("%.%a+$") ~= nil
		and (path:lower():match("%.png$") or path:lower():match("%.jpe?g$")
			or path:lower():match("%.gif$") or path:lower():match("%.webp$")
			or path:lower():match("%.svg$")) ~= nil
end

-- Normalizes an icon setting value into a plain filesystem path.
local function imagePathFor(v)
	return (v:gsub("^file://", ""))
end

-- Animated GIF icons.
--
-- ui.image only ever shows a gif's first frame - there's no AnimatedImage
-- equivalent in the plugin sandbox (see UiImageProps in noctalia.d.luau).
-- So a .gif icon is pre-split into PNG frames with ImageMagick once, cached
-- under the plugin's data dir, and the frames are hand-cycled on a timer -
-- the same trick the official bongocat plugin uses with font glyphs instead
-- of image files.
local GIF_TICK_MS = 50
local GIF_DEFAULT_FRAME_MS = 100 -- GIF spec: a 0 delay is conventionally ~100ms

local gifStartMs = noctalia.nowMs()
local gifMagickBinary = nil -- nil = unchecked, false = unavailable, else "magick"|"convert"
local gifWarnedNoMagick = false
-- [resolvedPath] = "pending" | "unavailable" | { frames = {path,...}, cum = {ms,...}, total = ms }
local gifCache = {}

local function gifBinary()
	if gifMagickBinary == nil then
		if noctalia.commandExists("magick") then
			gifMagickBinary = "magick"
		elseif noctalia.commandExists("convert") then
			gifMagickBinary = "convert"
		else
			gifMagickBinary = false
		end
	end
	return gifMagickBinary
end

-- Single-quotes a value for /bin/sh: close the quote, emit an escaped
-- literal quote, reopen it.
local function shellQuote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function djb2Hex(s)
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + s:byte(i)) % 4294967296
	end
	return string.format("%08x", h)
end

local function gifCacheDirFor(path)
	local dataDir = noctalia.pluginDataDir()
	if not dataDir then
		return nil
	end
	-- Folds the file's mtime into the cache key so replacing the gif at the
	-- same path re-extracts instead of serving stale frames.
	local info = noctalia.fileInfo(path)
	local mtime = info and info.mtime or 0
	return dataDir .. "/gif-frames/" .. djb2Hex(path) .. "-" .. tostring(mtime)
end

local function startGifExtraction(path)
	local binary = gifBinary()
	if not binary then
		if not gifWarnedNoMagick then
			gifWarnedNoMagick = true
			noctalia.log("Lunar Workspaces: ImageMagick (magick/convert) not found; gif icons will show as a static image")
		end
		gifCache[path] = "unavailable"
		return
	end

	local cacheDir = gifCacheDirFor(path)
	if not cacheDir then
		gifCache[path] = "unavailable"
		return
	end

	gifCache[path] = "pending"

	local qPath = shellQuote(path)
	local identifyBin = (binary == "magick") and "magick identify" or "identify"
	local cmd = "mkdir -p " .. shellQuote(cacheDir)
		.. " && " .. binary .. " " .. qPath .. " -coalesce " .. shellQuote(cacheDir .. "/frame-%04d.png")
		.. " && " .. identifyBin .. " -format '%T ' " .. qPath

	noctalia.runAsync(cmd, function(result)
		if result.exitCode ~= 0 then
			gifCache[path] = "unavailable"
			return
		end

		local delaysMs = {}
		for token in result.stdout:gmatch("%d+") do
			local centiseconds = tonumber(token) or 0
			table.insert(delaysMs, (centiseconds > 0 and centiseconds * 10) or GIF_DEFAULT_FRAME_MS)
		end

		if #delaysMs <= 1 then
			-- No frames parsed, or genuinely a single-frame gif: nothing to
			-- cycle, so leave it to render as a plain static image.
			gifCache[path] = "unavailable"
			return
		end

		local frames, cum, total = {}, {}, 0
		for i, ms in ipairs(delaysMs) do
			frames[i] = cacheDir .. "/frame-" .. string.format("%04d", i - 1) .. ".png"
			total = total + ms
			cum[i] = total
		end
		gifCache[path] = { frames = frames, cum = cum, total = total }

		-- Extraction finishes off the render cycle that kicked it off, so
		-- nothing else would otherwise re-render to pick up the new frames.
		render(renderedVertical)
	end, 15000)
end

-- Returns (displayPath, isAnimating) for a .gif icon path at the given
-- render-pass timestamp. Kicks off extraction on first sight; until frames
-- are ready (or if extraction isn't possible) the caller falls back to the
-- raw gif path, which still renders as a static first-frame image.
local function resolveGifFrame(path, nowMs)
	local cached = gifCache[path]
	if cached == nil then
		startGifExtraction(path)
		cached = gifCache[path]
	end
	if type(cached) ~= "table" then
		return nil, false
	end
	local elapsed = (nowMs - gifStartMs) % cached.total
	for i, cutoff in ipairs(cached.cum) do
		if elapsed < cutoff then
			return cached.frames[i], true
		end
	end
	return cached.frames[#cached.frames], true
end

local function entryFor(idxStr)
	return wsState[idxStr] or { focused = false, urgent = false, occupied = false }
end

local function iconFor(entry)
	if entry.focused then
		return iconFocused
	elseif entry.urgent then
		return iconUrgent
	elseif entry.occupied then
		return iconOccupied
	end
	return iconEmpty
end

local function sizeFor(entry)
	if entry.focused then
		return sizeFocused
	elseif entry.urgent then
		return sizeUrgent
	elseif entry.occupied then
		return sizeOccupied
	end
	return sizeEmpty
end

-- Animated pill sizes.

local ANIM_INTERVAL_MS = 16   -- ~60fps while animating
local ANIM_IDLE_MS = 250      -- slow tick once settled (keeps orientation checks alive)
local ANIM_EASE = 0.28        -- fraction of the remaining distance closed per tick
local ANIM_SNAP_EPSILON = 0.3 -- px distance below which we snap to the target

local pillAnim = {}    -- [idxStr] = { size = <current eased size> }
local currentIntervalMs = nil -- nil until the first render() decides a tick rate

-- Workspace indices to render, per workspace_display_mode:
--   all             - every workspace from 1..workspace_count
--   active_occupied - only occupied, focused, or urgent workspaces
--   once            - occupied/focused/urgent workspaces, plus a single
--                     "anticipatory" empty slot right after the last
--                     occupied one, so there's always one place to go next
local function visibleIndices()
	local indices = {}

	if displayMode == "active_occupied" then
		for i = 1, workspaceCount do
			local e = entryFor(tostring(i))
			if e.occupied or e.focused or e.urgent then
				table.insert(indices, i)
			end
		end
	elseif displayMode == "once" then
		local maxOccupied = 0
		for i = 1, workspaceCount do
			local e = entryFor(tostring(i))
			if e.occupied then
				maxOccupied = i
			end
		end

		local shown = {}
		for i = 1, workspaceCount do
			local e = entryFor(tostring(i))
			if e.occupied or e.focused or e.urgent then
				table.insert(indices, i)
				shown[i] = true
			end
		end

		local anticipatory
		for i = maxOccupied + 1, workspaceCount do
			local e = entryFor(tostring(i))
			if not e.occupied then
				anticipatory = i
				break
			end
		end
		if anticipatory and not shown[anticipatory] then
			table.insert(indices, anticipatory)
		end
	else -- "all"
		for i = 1, workspaceCount do
			table.insert(indices, i)
		end
	end

	table.sort(indices)

	if #indices == 0 then
		table.insert(indices, 1)
	end

	return indices
end

-- Switches to the given workspace index on whichever compositor is active.
local function switchWorkspace(idx)
	local useHyprland
	if compositorSetting == "hyprland" then
		useHyprland = true
	elseif compositorSetting == "niri" then
		useHyprland = false
	else
		useHyprland = noctalia.commandExists("hyprctl") and noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE") ~= nil
	end

	if useHyprland then
		noctalia.runAsync("hyprctl dispatch workspace " .. idx)
	else
		noctalia.runAsync("niri msg action focus-workspace " .. idx)
	end
end

-- Builds and renders the row/column of workspace pills.
function render(vertical)
	renderedVertical = vertical
	local container = vertical and ui.column or ui.row
	local pill = vertical and ui.column or ui.row
	local children = {}
	local stillAnimating = false
	local sawAnimatedGif = false
	local seen = {}
	local nowMs = noctalia.nowMs()

	for _, idx in ipairs(visibleIndices()) do
		local idxStr = tostring(idx)
		seen[idxStr] = true
		local entry = entryFor(idxStr)
		local glyphOrPath = iconFor(entry)
		local targetSize = sizeFor(entry)

		local a = pillAnim[idxStr]
		if not a then
			a = { size = targetSize }
			pillAnim[idxStr] = a
		end
		if not enableAnimation then
			a.size = targetSize
		elseif math.abs(targetSize - a.size) > ANIM_SNAP_EPSILON then
			a.size = a.size + (targetSize - a.size) * ANIM_EASE
			stillAnimating = true
		else
			a.size = targetSize
		end
		local size = a.size

		-- "ghost" = transparent, bare icon. "fill" = colored pill behind it.
		local style, color
		if entry.focused then
			style, color = focusedPillStyle, focusedColor
		elseif entry.urgent then
			style, color = urgentPillStyle, urgentColor
		elseif entry.occupied then
			style, color = occupiedPillStyle, occupiedColor
		else
			style, color = emptyPillStyle, emptyColor
		end

		local fill = "#00000000"
		local textColor = "on_surface"
		if style == "fill" then
			fill = color
			textColor = "on_" .. color
		end

		local inner
		if isImagePath(glyphOrPath) then
			local resolved = noctalia.expandPath(imagePathFor(glyphOrPath))
			local displayPath = resolved
			if resolved:lower():match("%.gif$") then
				local framePath, animating = resolveGifFrame(resolved, nowMs)
				if animating then
					displayPath = framePath
					sawAnimatedGif = true
				end
			end
			-- `key` keeps this node's identity stable across re-renders so a
			-- static image isn't reloaded on every state update; an animated
			-- gif's frame path changing under the same key is exactly what
			-- drives its playback.
			inner = ui.image({
				key = "icon-" .. idxStr,
				path = displayPath,
				width = size,
				height = size,
			})
		else
			inner = ui.label({ text = glyphOrPath, fontSize = size, color = textColor, textAlign = "center" })
		end

		table.insert(
			children,
			pill({
				key = idxStr,
				align = "center",
				justify = "center",
				fill = fill,
				radius = 8,
				onClick = function()
					switchWorkspace(idxStr)
				end,
			}, { inner })
		)
	end

	-- Drop animation state for workspaces no longer rendered
	for idxStr in pairs(pillAnim) do
		if not seen[idxStr] then
			pillAnim[idxStr] = nil
		end
	end

	local desiredIntervalMs = ANIM_IDLE_MS
	if stillAnimating then
		desiredIntervalMs = ANIM_INTERVAL_MS
	elseif sawAnimatedGif then
		desiredIntervalMs = GIF_TICK_MS
	end
	if desiredIntervalMs ~= currentIntervalMs then
		currentIntervalMs = desiredIntervalMs
		noctalia.setUpdateInterval(desiredIntervalMs)
	end

	barWidget.render(container({ gap = 6, align = "center" }, children))
end

noctalia.state.watch(STATE_KEY, function(value)
	wsState = type(value) == "table" and value or {}
	render(renderedVertical)
end)

function update()
	local vertical = barWidget.isVertical()
	if vertical ~= renderedVertical then
		render(vertical)
	elseif currentIntervalMs ~= nil and currentIntervalMs ~= ANIM_IDLE_MS then
		render(renderedVertical)
	end
end

function onConfigChanged()
	compositorSetting = noctalia.getConfig("compositor") or "auto"
	displayMode = noctalia.getConfig("workspace_display_mode") or "all"
	workspaceCount = tonumber(noctalia.getConfig("workspace_count")) or 9
	enableAnimation = getBoolConfig("enable_animation", true)
	iconFocused = noctalia.getConfig("icon_focused") or "🌕"
	iconUrgent = noctalia.getConfig("icon_urgent") or "🌟"
	iconOccupied = noctalia.getConfig("icon_occupied") or "🌗"
	iconEmpty = noctalia.getConfig("icon_empty") or "🌙"
	sizeFocused = tonumber(noctalia.getConfig("size_focused")) or 22
	sizeUrgent = tonumber(noctalia.getConfig("size_urgent")) or 20
	sizeOccupied = tonumber(noctalia.getConfig("size_occupied")) or 18
	sizeEmpty = tonumber(noctalia.getConfig("size_empty")) or 16
	focusedPillStyle = noctalia.getConfig("focused_pill_style") or "fill"
	focusedColor = noctalia.getConfig("focused_color") or "primary"
	urgentPillStyle = noctalia.getConfig("urgent_pill_style") or "fill"
	urgentColor = noctalia.getConfig("urgent_color") or "error"
	occupiedPillStyle = noctalia.getConfig("occupied_pill_style") or "ghost"
	occupiedColor = noctalia.getConfig("occupied_color") or "secondary"
	emptyPillStyle = noctalia.getConfig("empty_pill_style") or "ghost"
	emptyColor = noctalia.getConfig("empty_color") or "surface_variant"
	render(renderedVertical)
end

-- Scroll-to-switch: moves focus to the next/previous visible workspace.
function onScroll(axis, steps, startsGesture)
	if not startsGesture then
		return
	end
	local visible = visibleIndices()
	local currentPos = nil
	for pos, idx in ipairs(visible) do
		if entryFor(tostring(idx)).focused then
			currentPos = pos
			break
		end
	end
	if currentPos == nil then
		return
	end
	local delta = (steps > 0) and 1 or -1
	local nextPos = ((currentPos - 1 + delta) % #visible) + 1
	switchWorkspace(tostring(visible[nextPos]))
end

render(barWidget.isVertical())
