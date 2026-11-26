--!nonstrict
-- Flexa bar widget: defaults to a clean music icon in the status bar, with
-- optional album art, track title, inline controls, and scroll-to-volume.

local PANEL_ID = "nirikshak01/flexa:player"

local playback = noctalia.state.get("playback")
local library = noctalia.state.get("libraryMeta")

local function sendCommand(payload: { [string]: any })
	payload._at = noctalia.nowMs()
	noctalia.state.set("command", payload)
end

local function readBarSettings()
	return {
		showControls = noctalia.getConfig("showBarControls") == true,
		showTitle = noctalia.getConfig("showBarTitle") == true,
		showArtwork = noctalia.getConfig("showBarArtwork") == true,
		maxWidth = tonumber(noctalia.getConfig("barMaxWidth")) or 220,
	}
end

local function updateTooltip()
	if type(playback) == "table" and type(playback.title) == "string" and playback.title ~= "" then
		local status = (playback.playing and not playback.paused) and "Playing" or "Paused"
		local artist = (type(playback.artist) == "string" and playback.artist ~= "") and playback.artist or "Local file"
		barWidget.setTooltip({
			{ key = status, value = playback.title },
			{ key = "Artist", value = artist },
			{ key = "Volume", value = tostring(playback.volume or 80) .. "%" },
			{ key = "Hint", value = "Click: player  |  Right: play/pause  |  Scroll: volume" },
		})
	else
		barWidget.setTooltip(noctalia.tr("widget.tooltip.idle"))
	end
end

local function render()
	local cfg = readBarSettings()
	local vertical = barWidget.isVertical()
	local isPlaying = type(playback) == "table" and playback.playing == true and playback.paused ~= true
	local hasTrack = type(playback) == "table" and type(playback.title) == "string" and playback.title ~= ""
	local coverPath = (type(playback) == "table" and type(playback.coverPath) == "string") and playback.coverPath or ""

	local noDir = type(library) == "table" and library.error == "no_dir"
	local titleText = hasTrack and playback.title or (noDir and noctalia.tr("widget.empty") or noctalia.tr("widget.idle"))

	local children = {}
	if cfg.showArtwork and coverPath ~= "" and hasTrack then
		table.insert(children, ui.image({
			path = coverPath,
			width = 18,
			height = 18,
			radius = 4,
			fit = "cover",
		}))
	else
		table.insert(children, ui.glyph({
			name = isPlaying and "disc" or "music",
			size = (not cfg.showTitle and not cfg.showControls) and 18 or 16,
			color = isPlaying and "primary" or "on_surface",
		}))
	end

	if not vertical and cfg.showTitle then
		table.insert(children, ui.label({
			text = titleText,
			maxWidth = cfg.maxWidth,
			maxLines = 1,
			fontWeight = isPlaying and "semibold" or "medium",
			color = isPlaying and "on_surface" or "on_surface_variant",
		}))
	end

	if not vertical and cfg.showControls then
		table.insert(children, ui.button({
			glyph = isPlaying and "player-pause-filled" or "player-play-filled",
			glyphSize = 12,
			variant = "ghost",
			tooltip = isPlaying and "Pause" or "Play",
			onClick = function()
				sendCommand({ action = "play-pause" })
			end,
		}))
		table.insert(children, ui.button({
			glyph = "player-skip-forward-filled",
			glyphSize = 12,
			variant = "ghost",
			tooltip = "Next track",
			onClick = function()
				sendCommand({ action = "next" })
			end,
		}))
	end

	local container = vertical and ui.column or ui.row
	barWidget.render(container({ gap = 6, align = "center" }, children))
	updateTooltip()
end

noctalia.state.watch("playback", function(value)
	playback = value
	render()
end)

noctalia.state.watch("libraryMeta", function(value)
	library = value
	render()
end)

noctalia.state.watch("configRev", function()
	render()
end)

function update()
	render()
end

function onClick()
	noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
	sendCommand({ action = "play-pause" })
end

function onMiddleClick()
	sendCommand({ action = "next" })
end

function onScroll(axis: string, steps: number, _startsGesture: boolean)
	if axis == "vertical" and steps ~= 0 then
		sendCommand({ action = "volume-delta", delta = -steps * 4 })
	end
end
