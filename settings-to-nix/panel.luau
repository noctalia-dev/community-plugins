--!nonstrict
-- Panel: export status, the export button, and how the file is meant to be used.

local STATUS_KEY = "settings_to_nix.status"
local COMMAND_KEY = "settings_to_nix.command"

local status = noctalia.state.get(STATUS_KEY) or {}

local function send(action)
	noctalia.state.set(COMMAND_KEY, { action = action, nonce = tostring(noctalia.nowMs()) })
end

local function text(value, props)
	props = props or {}
	props.text = value
	props.fontSize = props.fontSize or 12
	props.color = props.color or "on_surface_variant"
	return ui.label(props)
end

local function section(title, children)
	local body = { text(title, { fontSize = 13, fontWeight = "bold", color = "on_surface" }) }
	for _, child in children do
		table.insert(body, child)
	end
	return ui.column({ gap = 6 }, body)
end

local function exportSection()
	local lines = {}
	if status.error and status.error ~= "" then
		table.insert(lines, text(status.error, { color = "error" }))
	else
		local key = status.pending and "panel.export_pending" or "panel.export_current"
		table.insert(lines, text(noctalia.trp(key, status.values or 0)))
		table.insert(lines, text(status.target or "", { maxLines = 2 }))
	end
	table.insert(lines, ui.button({
		text = noctalia.tr("panel.export_button"),
		glyph = "file-export",
		variant = status.pending and "primary" or "default",
		onClick = "onExportClicked",
	}))
	return section(noctalia.tr("panel.export_title"), lines)
end

local function render()
	panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
		ui.row({ align = "center", gap = 8 }, {
			ui.glyph({ name = "snowflake", size = 18, color = "primary" }),
			ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.button({ glyph = "settings", variant = "ghost", onClick = "onSettingsClicked" }),
			ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
		}),
		exportSection(),
		ui.separator({}),
		section(noctalia.tr("panel.usage_title"), { text(noctalia.tr("panel.usage_body")) }),
	}))
end

noctalia.state.watch(STATUS_KEY, function(value)
	if type(value) == "table" then
		status = value
		render()
	end
end)

function onOpen(_context)
	render()
end

function onExportClicked()
	send("export")
end

function onSettingsClicked()
	noctalia.openSettings()
end

function onCloseClicked()
	panel.close()
end

render()
