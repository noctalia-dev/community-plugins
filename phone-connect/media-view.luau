--!nonstrict
-- Device-tab media controls. The injected context supplies UI factories,
-- host APIs, translation lookup and the service command dispatcher.
local MediaView = {}

-- Keep drag previews and the previous unmuted volume local to each panel.
-- Return a view builder; device playback values remain service-owned.
function MediaView.new(context)
	local ui, noctalia, translate, sendCommand = context.ui, context.api, context.t, context.send
	local mediaDragState, volumeDragState, previousVolume = {}, {}, {}
	local function formatDuration(ms)
		local seconds = math.floor(math.max(0, tonumber(ms) or 0) / 1000)
		return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
	end

	local function mediaSection(device)
		local title = device.mediatitle
		if not title or title == "" then
			-- Match the playing state's alignment to avoid shifting the layout
			-- when playback starts or stops.
			return ui.column({ gap = 6, padding = 10, radius = 8, fill = "surface/0.5" }, {
				ui.row({ gap = 6, align = "center" }, {
					ui.glyph({ name = "music", size = 13, color = "primary" }),
					ui.label({
						text = translate("panel.now_playing"),
						fontSize = 10,
						color = "primary",
						fontWeight = "bold",
						flexGrow = 1,
					}),
				}),
				ui.row({ gap = 8, align = "center" }, {
					ui.glyph({ name = "music-off", size = 20, color = "on_surface_variant" }),
					ui.label({
						text = translate("panel.no_media"),
						fontSize = 11,
						color = "on_surface_variant",
					}),
				}),
			})
		end
		local artist = device.mediaartist or ""
		local album = device.mediaalbum or ""
		local playing = device.mediaisPlaying == true
		local length = tonumber(device.medialength) or 0
		local position = tonumber(device.mediaposition) or 0
		local canSeek = device.mediacanSeek == true
		local artUrl = device.mediaArtPath

		-- only use art if the file exists (phone path via SFTP mount)
		if artUrl and artUrl ~= "" and not noctalia.fileExists(artUrl) then
			artUrl = nil
		end

		local header = ui.row({ gap = 6, align = "center" }, {
			ui.glyph({ name = "music", size = 13, color = "primary" }),
			ui.label({
				text = translate("panel.now_playing"),
				fontSize = 10,
				color = "primary",
				fontWeight = "bold",
				flexGrow = 1,
			}),
		})

		local titleBlock
		if artUrl then
			titleBlock = ui.row({ gap = 8, align = "center" }, {
				ui.image({ path = artUrl, width = 36, height = 36, radius = 4, fit = "cover" }),
				ui.column({ gap = 1, flexGrow = 1 }, {
					ui.label({
						text = title,
						fontSize = 12,
						fontWeight = "medium",
						color = "on_surface",
						maxLines = 1,
					}),
					ui.label({
						text = artist,
						fontSize = 10,
						color = "on_surface_variant",
						maxLines = 1,
					}),
					ui.label({
						text = album,
						fontSize = 9,
						color = "on_surface_variant",
						maxLines = 1,
					}),
				}),
			})
		else
			titleBlock = ui.column({ gap = 1 }, {
				ui.label({
					text = title,
					fontSize = 12,
					fontWeight = "medium",
					color = "on_surface",
					maxLines = 1,
				}),
				ui.label({
					text = artist,
					fontSize = 10,
					color = "on_surface_variant",
					maxLines = 1,
				}),
				ui.label({ text = album, fontSize = 9, color = "on_surface_variant", maxLines = 1 }),
			})
		end

		local transport = ui.row({ gap = 4, align = "center" }, {
			ui.button({
				glyph = "player-skip-back",
				variant = "ghost",
				controlSize = "sm",
				tooltip = translate("media.previous"),
				onClick = function()
					sendCommand({ op = "media", device = device.id, action = "Previous" })
				end,
			}),
			ui.button({
				glyph = playing and "player-pause" or "player-play",
				variant = "primary",
				controlSize = "sm",
				tooltip = translate(playing and "media.pause" or "media.play"),
				onClick = function()
					sendCommand({ op = "media", device = device.id, action = "PlayPause" })
				end,
			}),
			ui.button({
				glyph = "player-skip-forward",
				variant = "ghost",
				controlSize = "sm",
				tooltip = translate("media.next"),
				onClick = function()
					sendCommand({ op = "media", device = device.id, action = "Next" })
				end,
			}),
			ui.button({
				glyph = "player-stop",
				variant = "ghost",
				controlSize = "sm",
				tooltip = translate("media.stop"),
				onClick = function()
					sendCommand({ op = "media", device = device.id, action = "Stop" })
				end,
			}),
		})

		local progress
		if canSeek and length > 0 then
			local dragState = mediaDragState[device.id]
			-- Freeze the thumb only while the user is actually dragging; a stale
			-- drag state (e.g. onDragEnd never fired) expires after 2s and the bar
			-- resumes tracking the live position.
			local frozen = dragState
				and dragState.dragging
				and (os.clock() - (dragState.at or 0)) < 2.0
			if dragState and dragState.dragging and not frozen then
				mediaDragState[device.id] = nil
			end
			local sliderValue = frozen and dragState.position or position
			progress = ui.column({ gap = 2 }, {
				ui.slider({
					min = 0,
					max = length,
					step = 1000,
					value = sliderValue,
					controlSize = "sm",
					onChange = function(v)
						mediaDragState[device.id] =
							{ dragging = true, position = tonumber(v) or position, at = os.clock() }
					end,
					onDragEnd = function()
						local finalDragState = mediaDragState[device.id]
						local target = (finalDragState and finalDragState.position) or position
						mediaDragState[device.id] = nil
						sendCommand({
							op = "media_seek",
							device = device.id,
							offset = tostring(target),
						})
					end,
				}),
				ui.row({ justify = "space_between" }, {
					ui.label({
						text = formatDuration(sliderValue),
						fontSize = 9,
						color = "on_surface_variant",
					}),
					ui.label({
						text = formatDuration(length),
						fontSize = 9,
						color = "on_surface_variant",
					}),
				}),
			})
		end

		local children = { header, titleBlock, transport }
		if progress then
			table.insert(children, progress)
		end
		return ui.column({ gap = 6, padding = 10, radius = 8, fill = "primary/0.08" }, children)
	end

	return function(device)
		local children = { mediaSection(device) }
		local volume = tonumber(device.mediavolume)
		if volume and volume >= 0 then
			local frozen = volumeDragState[device.id]
			local shown = frozen or volume
			table.insert(
				children,
				ui.row({ gap = 12, align = "center" }, {
					ui.button({
						glyph = shown == 0 and "volume-off" or "volume",
						variant = "ghost",
						tooltip = translate(shown == 0 and "media.unmute" or "media.mute"),
						enabled = device.isReachable,
						onClick = function()
							if volume > 0 then
								previousVolume[device.id] = volume
							end
							sendCommand({
								op = "media_set_volume",
								device = device.id,
								volume = volume == 0 and (previousVolume[device.id] or 50) or 0,
							})
						end,
					}),
					ui.slider({
						key = "volume-" .. device.id,
						min = 0,
						max = 100,
						step = 1,
						value = shown,
						enabled = device.isReachable,
						flexGrow = 1,
						onChange = function(v)
							volumeDragState[device.id] = tonumber(v)
						end,
						onDragEnd = function()
							sendCommand({
								op = "media_set_volume",
								device = device.id,
								volume = volumeDragState[device.id] or volume,
							})
							volumeDragState[device.id] = nil
						end,
					}),
					ui.label({ text = tostring(math.floor(shown)) .. "%", width = 46 }),
				})
			)
		end
		return ui.column({ gap = 12 }, children)
	end
end
return MediaView
