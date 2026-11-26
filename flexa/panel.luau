--!nonstrict
-- Flexa panel UI: Amberol-inspired folder music player built strictly with
-- Noctalia's declarative ui.* tree and live theme color roles.
-- Filtering and pagination run in Python so every render is O(1) <= 25 rows.

local playback = noctalia.state.get("playback") or {}
local view = noctalia.state.get("view") or {}
local backendError = noctalia.state.get("backendError")

local showCloseButton = true
local panelOpen = false

local isSeeking = false
local seekDraft = 0

local function sendCommand(payload: { [string]: any })
	payload._at = noctalia.nowMs()
	noctalia.state.set("command", payload)
end

local function formatTime(seconds: number?): string
	local s = math.max(0, math.floor(tonumber(seconds) or 0))
	local h = math.floor(s / 3600)
	local m = math.floor((s % 3600) / 60)
	local rem = s % 60
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, rem)
	end
	return string.format("%d:%02d", m, rem)
end

local function formatCount(n: number): string
	if n >= 1000 then
		return string.format("%.1fk", n / 1000)
	end
	return tostring(n)
end

local function renderHeader(totalTracks: number, scanning: boolean)
	local countText = totalTracks == 1 and "1 track" or (tostring(totalTracks) .. " tracks")

	local rightButtons = {
		ui.button({
			key = "btn-rescan",
			glyph = "refresh",
			glyphSize = 15,
			variant = "ghost",
			controlSize = "sm",
			tooltip = noctalia.tr("panel.rescan"),
			onClick = function()
				sendCommand({ action = "rescan" })
			end,
		}),
		ui.button({
			key = "btn-settings",
			glyph = "settings",
			glyphSize = 15,
			variant = "ghost",
			controlSize = "sm",
			tooltip = noctalia.tr("panel.settings"),
			onClick = function()
				noctalia.openSettings()
			end,
		}),
	}
	if showCloseButton then
		table.insert(rightButtons, ui.button({
			key = "btn-close",
			glyph = "x",
			glyphSize = 15,
			variant = "ghost",
			controlSize = "sm",
			tooltip = noctalia.tr("panel.close"),
			onClick = function()
				panel.close()
			end,
		}))
	end

	return ui.row({ align = "center", justify = "space_between", gap = 8 }, {
		ui.row({ align = "center", gap = 8 }, {
			ui.glyph({ name = "vinyl", size = 18, color = "primary" }),
			ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
			ui.row({ fill = "primary/0.16", radius = 999, paddingH = 8, paddingV = 2, align = "center" }, {
				ui.label({
					text = scanning and "Scanning..." or countText,
					fontSize = 11,
					fontWeight = "semibold",
					color = "primary",
				}),
			}),
		}),
		ui.row({ align = "center", gap = 2 }, rightButtons),
	})
end

local function renderHeroCard()
	local trackId = type(playback.trackId) == "string" and playback.trackId or ""
	local hasTrack = trackId ~= "" and type(playback.title) == "string" and playback.title ~= ""
	local isPlaying = playback.playing == true and playback.paused ~= true
	local coverPath = type(playback.coverPath) == "string" and playback.coverPath or ""
	local duration = tonumber(playback.duration) or 0
	local pos = isSeeking and seekDraft or (tonumber(playback.pos) or 0)
	local volume = tonumber(playback.volume) or 80
	local muted = playback.mute == true
	local shuffleOn = playback.shuffle == true
	local repeatMode = type(playback.repeatMode) == "string" and playback.repeatMode or "off"
	local isFav = playback.liked == true

	local artNode
	if coverPath ~= "" and hasTrack then
		artNode = ui.image({
			key = "hero-art-img",
			path = coverPath,
			width = 76,
			height = 76,
			radius = 12,
			fit = "cover",
			border = "outline_variant/0.4",
			borderWidth = 1,
		})
	else
		artNode = ui.row({
			key = "hero-art-fallback",
			width = 76,
			height = 76,
			radius = 12,
			fill = "primary/0.14",
			border = "primary/0.25",
			borderWidth = 1,
			align = "center",
			justify = "center",
		}, {
			ui.glyph({ name = "disc", size = 34, color = "primary" }),
		})
	end

	local badgeParts = {}
	if hasTrack and type(playback.ext) == "string" and playback.ext ~= "" then
		table.insert(badgeParts, ui.row({ fill = "secondary/0.2", radius = 6, paddingH = 6, paddingV = 2 }, {
			ui.label({ text = playback.ext, fontSize = 10, fontWeight = "bold", color = "secondary" }),
		}))
	end
	if hasTrack and type(playback.folder) == "string" and playback.folder ~= "" then
		table.insert(badgeParts, ui.label({
			text = playback.folder,
			fontSize = 11,
			color = "on_surface_variant",
			maxLines = 1,
			maxWidth = 180,
		}))
	end

	local muteIcon = muted and "volume-off" or (volume == 0 and "volume-3" or (volume < 50 and "volume-2" or "volume"))
	local repeatIcon = repeatMode == "one" and "repeat-once" or (repeatMode == "all" and "repeat" or "repeat-off")

	local infoChildren = {}
	if #badgeParts > 0 then
		table.insert(infoChildren, ui.row({ gap = 6, align = "center" }, badgeParts))
	end
	table.insert(infoChildren, ui.label({
		text = hasTrack and playback.title or noctalia.tr("panel.no-track"),
		fontSize = 15,
		fontWeight = "bold",
		color = "on_surface",
		maxLines = 1,
		maxWidth = 285,
	}))
	table.insert(infoChildren, ui.label({
		text = hasTrack
				and ((type(playback.artist) == "string" and playback.artist ~= "") and playback.artist or "Local file")
			or noctalia.tr("panel.select-track"),
		fontSize = 12,
		color = "on_surface_variant",
		maxLines = 1,
		maxWidth = 285,
	}))

	return ui.column({
		fill = "surface_container",
		radius = 16,
		padding = 14,
		gap = 10,
		border = "outline_variant/0.35",
		borderWidth = 1,
	}, {
		ui.row({ gap = 12, align = "center" }, {
			artNode,
			ui.column({ flexGrow = 1, gap = 3, align = "start" }, infoChildren),
			ui.button({
				key = "hero-fav",
				glyph = isFav and "heart-filled" or "heart",
				glyphSize = 16,
				variant = isFav and "primary" or "ghost",
				controlSize = "sm",
				enabled = hasTrack,
				tooltip = isFav and "Remove from Liked" or "Add to Liked",
				onClick = function()
					if trackId ~= "" then
						sendCommand({ action = "favorite-toggle", trackId = trackId })
					end
				end,
			}),
		}),

		ui.column({ gap = 2, align = "stretch" }, {
			ui.slider({
				key = "hero-seek",
				min = 0,
				max = math.max(1, math.floor(duration)),
				step = 1,
				value = math.min(math.max(0, math.floor(pos)), math.max(1, math.floor(duration))),
				controlSize = "sm",
				enabled = hasTrack and duration > 0,
				onChange = function(val: string)
					isSeeking = true
					seekDraft = tonumber(val) or 0
					render()
				end,
				onDragEnd = function()
					local target = seekDraft
					isSeeking = false
					sendCommand({ action = "seek", seconds = target })
				end,
			}),
			ui.row({ justify = "space_between", align = "center" }, {
				ui.label({ text = formatTime(pos), fontSize = 11, color = "on_surface_variant" }),
				ui.label({ text = formatTime(duration), fontSize = 11, color = "on_surface_variant" }),
			}),
		}),

		ui.row({ justify = "space_between", align = "center", gap = 8 }, {
			ui.row({ align = "center", gap = 4 }, {
				ui.button({
					key = "ctrl-shuffle",
					glyph = "arrows-shuffle",
					glyphSize = 15,
					variant = shuffleOn and "secondary" or "ghost",
					selected = shuffleOn,
					controlSize = "sm",
					tooltip = shuffleOn and "Shuffle: On" or "Shuffle: Off",
					onClick = function()
						sendCommand({ action = "shuffle-toggle" })
					end,
				}),
				ui.button({
					key = "ctrl-prev",
					glyph = "player-skip-back-filled",
					glyphSize = 16,
					variant = "ghost",
					controlSize = "sm",
					tooltip = "Previous",
					onClick = function()
						sendCommand({ action = "prev" })
					end,
				}),
				ui.button({
					key = "ctrl-play",
					glyph = isPlaying and "player-pause-filled" or "player-play-filled",
					glyphSize = 18,
					variant = "primary",
					controlSize = "md",
					tooltip = isPlaying and "Pause" or "Play",
					onClick = function()
						sendCommand({ action = "play-pause" })
					end,
				}),
				ui.button({
					key = "ctrl-next",
					glyph = "player-skip-forward-filled",
					glyphSize = 16,
					variant = "ghost",
					controlSize = "sm",
					tooltip = "Next",
					onClick = function()
						sendCommand({ action = "next" })
					end,
				}),
				ui.button({
					key = "ctrl-repeat",
					glyph = repeatIcon,
					glyphSize = 15,
					variant = repeatMode ~= "off" and "secondary" or "ghost",
					selected = repeatMode ~= "off",
					controlSize = "sm",
					tooltip = "Repeat: " .. repeatMode,
					onClick = function()
						sendCommand({ action = "repeat-cycle" })
					end,
				}),
			}),

			ui.row({ align = "center", gap = 4 }, {
				ui.button({
					key = "ctrl-mute",
					glyph = muteIcon,
					glyphSize = 15,
					variant = muted and "destructive" or "ghost",
					controlSize = "sm",
					tooltip = muted and "Unmute" or ("Volume " .. tostring(volume) .. "%"),
					onClick = function()
						sendCommand({ action = "mute-toggle" })
					end,
				}),
				ui.slider({
					key = "ctrl-volume",
					width = 84,
					min = 0,
					max = 100,
					step = 2,
					value = volume,
					controlSize = "sm",
					onChange = function(val: string)
						local v = math.floor(tonumber(val) or 80)
						playback.volume = v
						sendCommand({ action = "volume", value = v })
					end,
				}),
			}),
		}),
	})
end

local function renderTrackRow(track: any, rowIndex: number, queueMode: boolean)
	local currentId = type(playback.trackId) == "string" and playback.trackId or ""
	local isCurrent = track.id == currentId
	local isFav = track.liked == true
	local durText = (tonumber(track.duration) or 0) > 0 and formatTime(track.duration) or "--:--"
	local rowKey = (queueMode and "q-" or "t-") .. tostring(rowIndex) .. "-" .. track.id

	local rightNodes = {
		ui.label({
			text = durText,
			fontSize = 11,
			color = isCurrent and "primary" or "on_surface_variant",
		}),
		ui.button({
			key = rowKey .. "-fav",
			glyph = isFav and "heart-filled" or "heart",
			glyphSize = 14,
			variant = "ghost",
			controlSize = "sm",
			tooltip = isFav and "Unlike" or "Like",
			onClick = function()
				sendCommand({ action = "favorite-toggle", trackId = track.id })
			end,
		}),
	}

	if queueMode then
		local qIdx = tonumber(track.queueIdx) or 0
		table.insert(rightNodes, ui.button({
			key = rowKey .. "-rm",
			glyph = "x",
			glyphSize = 14,
			variant = "ghost",
			controlSize = "sm",
			tooltip = "Remove from queue",
			onClick = function()
				sendCommand({ action = "queue-remove", index = qIdx })
			end,
		}))
	else
		table.insert(rightNodes, ui.button({
			key = rowKey .. "-add",
			glyph = "playlist-add",
			glyphSize = 14,
			variant = "ghost",
			controlSize = "sm",
			tooltip = "Add to queue",
			onClick = function()
				sendCommand({ action = "queue-add", trackId = track.id })
			end,
		}))
	end

	return ui.row({
		key = rowKey,
		fill = isCurrent and "primary/0.16" or "surface_container/0.55",
		radius = 10,
		paddingH = 10,
		paddingV = 6,
		gap = 10,
		align = "center",
		border = isCurrent and "primary/0.45" or nil,
		borderWidth = isCurrent and 1 or nil,
		onClick = function()
			sendCommand({
				action = "play",
				trackId = track.id,
				fromView = not queueMode,
			})
		end,
	}, {
		ui.glyph({
			name = isCurrent and "player-play-filled" or "music",
			size = 15,
			color = isCurrent and "primary" or "on_surface_variant",
		}),
		ui.column({ flexGrow = 1, gap = 1, align = "start" }, {
			ui.label({
				text = track.title or "Untitled",
				fontSize = 13,
				fontWeight = isCurrent and "bold" or "medium",
				color = isCurrent and "primary" or "on_surface",
				maxLines = 1,
				maxWidth = 275,
			}),
			ui.label({
				text = (track.artist and track.artist ~= "" and track.artist or "Local file")
					.. (track.ext and track.ext ~= "" and ("  ·  " .. track.ext) or ""),
				fontSize = 11,
				color = "on_surface_variant",
				maxLines = 1,
				maxWidth = 275,
			}),
		}),
		ui.row({ align = "center", gap = 2 }, rightNodes),
	})
end

local function renderEmptyState(message: string, showSettingsBtn: boolean)
	local children = {
		ui.glyph({ name = "folder-open", size = 32, color = "on_surface_variant" }),
		ui.label({ text = message, fontSize = 13, color = "on_surface_variant", textAlign = "center" }),
	}
	if showSettingsBtn then
		table.insert(children, ui.button({
			key = "empty-settings-btn",
			text = noctalia.tr("panel.open-settings"),
			glyph = "settings",
			variant = "primary",
			controlSize = "sm",
			onClick = function()
				noctalia.openSettings()
			end,
		}))
	end
	return ui.column({
		flexGrow = 1,
		padding = 24,
		gap = 10,
		align = "center",
		justify = "center",
		fill = "surface_container/0.45",
		radius = 14,
	}, children)
end

local function renderPager(offset: number, pageSize: number, matched: number)
	if matched <= pageSize then
		return nil
	end
	local page = math.floor(offset / pageSize) + 1
	local totalPages = math.max(1, math.ceil(matched / pageSize))
	return ui.row({ key = "pager-row", justify = "space_between", align = "center", paddingH = 4, paddingV = 2 }, {
		ui.button({
			key = "pager-prev",
			text = noctalia.tr("panel.page-prev"),
			glyph = "chevron-left",
			glyphSize = 14,
			variant = "ghost",
			controlSize = "sm",
			enabled = offset > 0,
			onClick = function()
				sendCommand({ action = "view", offset = math.max(0, offset - pageSize) })
			end,
		}),
		ui.label({
			text = tostring(page) .. " / " .. tostring(totalPages) .. "  (" .. tostring(matched) .. ")",
			fontSize = 11,
			color = "on_surface_variant",
		}),
		ui.button({
			key = "pager-next",
			text = noctalia.tr("panel.page-next"),
			glyph = "chevron-right",
			glyphSize = 14,
			variant = "ghost",
			controlSize = "sm",
			enabled = (offset + pageSize) < matched,
			onClick = function()
				sendCommand({ action = "view", offset = offset + pageSize })
			end,
		}),
	})
end

function render()
	local totalTracks = tonumber(view.total) or 0
	local matched = tonumber(view.matched) or 0
	local offset = tonumber(view.offset) or 0
	local pageSize = tonumber(view.pageSize) or 25
	local scanning = view.scanning == true
	local libError = view.error
	local activeTab = type(view.tab) == "string" and view.tab or "all"
	local selectedFolder = type(view.folder) == "string" and view.folder or ""
	local items = type(view.items) == "table" and view.items or {}
	local queueCount = tonumber(view.queueTotal) or (tonumber(playback.queueTotal) or 0)
	local favCount = tonumber(view.favTotal) or 0

	local tabButtons = {
		{ id = "all", label = noctalia.tr("panel.tab.all") },
		{ id = "folders", label = noctalia.tr("panel.tab.folders") },
		{ id = "queue", label = noctalia.tr("panel.tab.queue") .. " (" .. formatCount(queueCount) .. ")" },
		{ id = "favorites", label = noctalia.tr("panel.tab.favorites") .. " (" .. formatCount(favCount) .. ")" },
	}
	local tabNodes = {}
	for _, tab in ipairs(tabButtons) do
		table.insert(tabNodes, ui.button({
			key = "tab-" .. tab.id,
			text = tab.label,
			variant = activeTab == tab.id and "primary" or "ghost",
			controlSize = "sm",
			flexGrow = 1,
			onClick = function()
				sendCommand({
					action = "view",
					tab = tab.id,
					folder = tab.id == "folders" and selectedFolder or "",
					offset = 0,
				})
			end,
		}))
	end

	local listNode
	if backendError == "missing_mpv" then
		listNode = renderEmptyState("mpv is not installed on PATH. Install mpv to play audio.", false)
	elseif scanning and totalTracks == 0 then
		listNode = renderEmptyState("Scanning music folder...", false)
	elseif libError == "no_dir" then
		listNode = renderEmptyState(noctalia.tr("panel.empty.no-dir"), true)
	elseif libError == "missing_dir" then
		listNode = renderEmptyState("Folder not found: " .. tostring(view.dir or ""), true)
	elseif totalTracks == 0 then
		listNode = renderEmptyState(noctalia.tr("panel.empty.no-tracks"), true)
	elseif activeTab == "folders" and selectedFolder == "" then
		if #items == 0 then
			listNode = renderEmptyState(noctalia.tr("panel.empty.no-matches"), false)
		else
			local rows = {}
			for _, f in ipairs(items) do
				local fname = tostring(f.name or "Root")
				local fcount = tonumber(f.count) or 0
				table.insert(rows, ui.row({
					key = "dir-" .. fname,
					fill = "surface_container/0.55",
					radius = 10,
					paddingH = 12,
					paddingV = 8,
					gap = 10,
					align = "center",
					onClick = function()
						sendCommand({ action = "view", tab = "folders", folder = fname, offset = 0 })
					end,
				}, {
					ui.glyph({ name = "folder-filled", size = 18, color = "primary" }),
					ui.label({
						text = fname,
						fontSize = 13,
						fontWeight = "medium",
						color = "on_surface",
						flexGrow = 1,
						maxLines = 1,
					}),
					ui.row({ fill = "primary/0.14", radius = 999, paddingH = 8, paddingV = 2 }, {
						ui.label({ text = tostring(fcount), fontSize = 11, fontWeight = "semibold", color = "primary" }),
					}),
					ui.glyph({ name = "chevron-right", size = 14, color = "on_surface_variant" }),
				}))
			end
			local pager = renderPager(offset, pageSize, matched)
			if pager then
				table.insert(rows, pager)
			end
			listNode = ui.scroll({ key = "scroll-folders", flexGrow = 1, gap = 6 }, rows)
		end
	elseif activeTab == "queue" then
		if queueCount == 0 then
			listNode = renderEmptyState(noctalia.tr("panel.empty.no-queue"), false)
		elseif #items == 0 then
			listNode = renderEmptyState(noctalia.tr("panel.empty.no-matches"), false)
		else
			local qRows = {
				ui.row({ key = "queue-toolbar", justify = "space_between", align = "center", paddingH = 4 }, {
					ui.label({ text = tostring(queueCount) .. " queued", fontSize = 12, color = "on_surface_variant" }),
					ui.button({
						key = "btn-clear-queue",
						text = noctalia.tr("panel.clear-queue"),
						glyph = "trash",
						glyphSize = 13,
						variant = "ghost",
						controlSize = "sm",
						onClick = function()
							sendCommand({ action = "queue-clear" })
						end,
					}),
				}),
			}
			for i, t in ipairs(items) do
				table.insert(qRows, renderTrackRow(t, i, true))
			end
			local pager = renderPager(offset, pageSize, matched)
			if pager then
				table.insert(qRows, pager)
			end
			listNode = ui.scroll({ key = "scroll-queue", flexGrow = 1, gap = 5 }, qRows)
		end
	else
		local rows = {}
		if activeTab == "folders" and selectedFolder ~= "" then
			table.insert(rows, ui.row({ key = "folder-crumb", justify = "space_between", align = "center", gap = 6 }, {
				ui.button({
					key = "btn-back-folders",
					text = selectedFolder,
					glyph = "chevron-left",
					glyphSize = 14,
					variant = "ghost",
					controlSize = "sm",
					onClick = function()
						sendCommand({ action = "view", tab = "folders", folder = "", offset = 0 })
					end,
				}),
				ui.button({
					key = "btn-play-folder",
					text = noctalia.tr("panel.play-all"),
					glyph = "player-play-filled",
					glyphSize = 13,
					variant = "secondary",
					controlSize = "sm",
					enabled = #items > 0,
					onClick = function()
						sendCommand({ action = "play-folder", folder = selectedFolder })
					end,
				}),
			}))
		end

		if #items == 0 then
			local emptyMsg = activeTab == "favorites" and noctalia.tr("panel.empty.no-favorites")
				or noctalia.tr("panel.empty.no-matches")
			listNode = renderEmptyState(emptyMsg, false)
		else
			for i, t in ipairs(items) do
				table.insert(rows, renderTrackRow(t, i, false))
			end
			local pager = renderPager(offset, pageSize, matched)
			if pager then
				table.insert(rows, pager)
			end
			listNode = ui.scroll({ key = "scroll-tracks", flexGrow = 1, gap = 5 }, rows)
		end
	end

	panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, {
		renderHeader(totalTracks, scanning),
		renderHeroCard(),
		ui.row({ gap = 6, align = "center" }, {
			ui.input({
				key = "flexa-search",
				flexGrow = 1,
				placeholder = noctalia.tr("panel.search.placeholder"),
				controlSize = "sm",
				onChange = function(text: string)
					sendCommand({ action = "view", query = text, offset = 0 })
				end,
			}),
			ui.button({
				key = "btn-shuffle-play",
				glyph = "arrows-shuffle",
				glyphSize = 15,
				variant = "outline",
				controlSize = "sm",
				tooltip = noctalia.tr("panel.shuffle-play"),
				enabled = totalTracks > 0,
				onClick = function()
					sendCommand({ action = "shuffle-play" })
				end,
			}),
		}),
		ui.row({ gap = 6, align = "center" }, tabNodes),
		listNode,
	}))
end

noctalia.state.watch("playback", function(value)
	playback = value or {}
	if panelOpen then
		render()
	end
end)

noctalia.state.watch("view", function(value)
	view = value or {}
	if panelOpen then
		render()
	end
end)

noctalia.state.watch("backendError", function(value)
	backendError = value
	if panelOpen then
		render()
	end
end)

function onOpen(_context)
	panelOpen = true
	showCloseButton = noctalia.getSetting("shell.show_close_buttons") ~= false
	playback = noctalia.state.get("playback") or {}
	view = noctalia.state.get("view") or {}
	backendError = noctalia.state.get("backendError")
	render()
end

function onClose()
	panelOpen = false
end
