--!nonstrict
-- Panel: one row per Keychron mouse with a battery bar, connection and charging state.

local SNAPSHOT_KEY = "keychron_snapshot"
local COMMAND_KEY = "keychron_command"

local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {}

local function sendRefresh()
	noctalia.state.set(COMMAND_KEY, { action = "refresh", nonce = tostring(noctalia.nowMs()) })
end

local function deviceRow(d)
	local low = tonumber(noctalia.getConfig("low_threshold")) or 20
	local hasLevel = type(d.level) == "number"
	local progressProps = {
		progress = hasLevel and math.max(0, math.min(100, d.level)) / 100 or 0,
		flexGrow = 1,
		radius = 3,
		height = 6,
	}
	if hasLevel and d.level <= low and not d.charging then
		progressProps.fill = "error"
	end

	local meta = noctalia.tr("connection." .. d.connection)
	if d.charging then
		meta = meta .. " · " .. noctalia.tr("panel.charging")
	end

	local children = {
		ui.row({ align = "center", gap = 10 }, {
			ui.glyph({ name = "mouse", size = 18, color = "primary" }),
			ui.column({ flexGrow = 1, gap = 1 }, {
				ui.label({ text = d.displayName or "", fontSize = 13, fontWeight = "medium", color = "on_surface", maxLines = 1 }),
				ui.label({ text = meta, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
			}),
			ui.label({ text = hasLevel and (tostring(d.level) .. "%") or "--", fontSize = 13, color = "on_surface", width = 44, textAlign = "end" }),
		}),
		ui.progress(progressProps),
	}
	if not d.available then
		table.insert(children, ui.label({ text = noctalia.tr("panel.hint_mouse_off"), fontSize = 11, color = "on_surface_variant", opacity = 0.8 }))
	end
	return ui.column({ gap = 6 }, children)
end

local function render()
	local body = {}
	local err = tostring(snapshot.error or "")
	if err ~= "" then
		table.insert(body, ui.label({ text = err, fontSize = 12, color = "error" }))
	end
	local devices = snapshot.devices or {}
	if #devices == 0 and err == "" then
		table.insert(body, ui.label({ text = noctalia.tr("panel.none"), fontSize = 13, color = "on_surface_variant" }))
	end
	for _, d in ipairs(devices) do
		table.insert(body, deviceRow(d))
	end

	panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefreshClicked" }),
			ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
		}),
		ui.scroll({ flexGrow = 1, gap = 14 }, body),
	}))
end

noctalia.state.watch(SNAPSHOT_KEY, function(value)
	if type(value) == "table" then
		snapshot = value
		render()
	end
end)

function onOpen(_context)
	sendRefresh()
	render()
end

function onRefreshClicked()
	sendRefresh()
end

function onCloseClicked()
	panel.close()
end

render()
