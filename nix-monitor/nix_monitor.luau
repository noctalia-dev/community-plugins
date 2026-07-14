function tr(key)
	return noctalia.tr(key)
end

function cfg(key)
	return noctalia.getConfig(key)
end

function getState(key)
	return noctalia.state.get(key)
end

function displayWidget(glyph: string, text: string, color: string?)
	local _color = color or "on_surface"

	if cfg("colorize_text") then
		barWidget.setColor(_color)
	end

	if cfg("colorize_glyph") then
		barWidget.setGlyphColor(_color)
	end

	if cfg("show_glyph") then
		barWidget.setGlyph(glyph)
	end

	if cfg("show_text") then
		barWidget.setText(text)
	end
end

-- Hooks
function update()
	if getState("isRemoteCheckRunning") then
		displayWidget(cfg("checking_glyph"), tr("bar.checking"), cfg("checking_color"))
	else
		if getState("isUpdateAvailable") then
			displayWidget(cfg("update_available_glyph"), tr("bar.update_available"), cfg("update_available_color"))
		else
			if getState("localHash") == "n/a" or getState("remoteHash") == "n/a" then
				displayWidget(cfg("unknown_glyph"), tr("bar.unknown"), cfg("unknown_color"))
			else
				displayWidget(cfg("up_to_date_glyph"), tr("bar.up_to_date"), cfg("up_to_date_color"))
			end
		end
	end
end

function onClick()
	noctalia.togglePanel("avivbintangaringga/nix-monitor:panel")
end
