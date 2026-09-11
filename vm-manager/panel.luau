--!nonstrict
-- panel.luau — VM manager panel: list VMs and drive start/shutdown/force-off/console.
--
-- The panel never talks to virsh itself. It pushes { action, name } onto the
-- "vm_action" state channel; the service performs the command and re-publishes.

local SNAPSHOT_DEFAULTS = {
	vms = {},
	running = 0,
	paused = 0,
	total = 0,
	updatedAt = 0,
	busy = {},
	error = nil,
}

local snapshot = noctalia.state.get("vms") or SNAPSHOT_DEFAULTS

local function sendAction(action, name)
	noctalia.state.set("vm_action", { action = action, name = name })
end

local function stateColor(state)
	if state == "running" then
		return "primary"
	elseif state == "paused" then
		return "on_surface"
	end
	return "on_surface_variant"
end

local function actionButton(action, name, disabled)
	local spec = {
		start = { glyph = "player-play", label = noctalia.tr("panel.start"), variant = "primary" },
		shutdown = { glyph = "power", label = noctalia.tr("panel.shutdown"), variant = "default" },
		["force-off"] = { glyph = "x", label = noctalia.tr("panel.force_off"), variant = "destructive" },
		suspend = { glyph = "player-pause", label = noctalia.tr("panel.suspend"), variant = "default" },
		resume = { glyph = "player-play", label = noctalia.tr("panel.resume"), variant = "primary" },
		console = { glyph = "screen-share", label = noctalia.tr("panel.console"), variant = "outline" },
	}
	local cfg = spec[action]
	if cfg == nil then
		return nil
	end
	return ui.button({
		text = cfg.label,
		glyph = cfg.glyph,
		glyphSize = 12,
		fontSize = 14,
		variant = cfg.variant,
		controlSize = "sm",
		enabled = not disabled,
		onClick = function()
			sendAction(action, name)
		end,
	})
end

local function actionsFor(state)
	if state == "shut off" then
		return { "start" }
	elseif state == "running" then
		return { "shutdown", "suspend", "force-off", "console" }
	elseif state == "paused" then
		return { "resume", "force-off", "console" }
	end
	return { "force-off", "console" }
end

local function openAutostartMenu(vm)
	local action, label
	if vm.autostart == true then
		action = "autostart-disable"
		label = noctalia.tr("panel.autostart_off")
	else
		action = "autostart"
		label = noctalia.tr("panel.autostart_on")
	end
	panel.openContextMenu({
		items = {
			{ kind = "header", label = vm.name },
			{ id = action, label = label },
			{ id = "autostart-once", label = noctalia.tr("panel.autostart_once") },
		},
		onActivate = "onAutostartMenuAction",
		context = vm.name,
	})
end

-- Always visible; shrinks and dims while the VM is running.
local function autostartButton(vm, disabled)
	local running = vm.state == "running"
	local props = {
		glyph = "settings",
		glyphSize = 14,
		tooltip = noctalia.tr("panel.autostart"),
		variant = "ghost",
		enabled = not disabled,
		onClick = function()
			openAutostartMenu(vm)
		end,
	}
	if running then
		props.controlSize = "sm"
		props.opacity = 0.5
	end
	return ui.button(props)
end

local function vmCard(vm)
	local busyAction = (snapshot.busy or {})[vm.name]
	local isBusy = busyAction ~= nil

	local actionRow = {}
	for _, action in ipairs(actionsFor(vm.state)) do
		local button = actionButton(action, vm.name, isBusy)
		if button ~= nil then
			table.insert(actionRow, button)
		end
	end
	table.insert(actionRow, autostartButton(vm, isBusy))

	local statusText = vm.state or "unknown"
	local statusColor = stateColor(vm.state)
	if isBusy then
		statusText = noctalia.tr("panel.busy", { action = tostring(busyAction) })
		statusColor = "on_surface_variant"
	end

	return ui.column({
		key = vm.name,
		gap = 8,
		padding = 10,
		radius = 8,
		border = "outline",
		borderWidth = 1,
		fill = "surface_variant/0.25",
	}, {
		ui.row({ align = "center", gap = 8 }, {
			ui.label({ text = vm.name, fontSize = 14, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.label({ text = statusText, fontSize = 11, color = statusColor }),
		}),
		ui.row({ align = "center", gap = 4 }, actionRow),
	})
end

local function render()
	local children = {}

	-- Header: icon · title · refresh · close
	table.insert(children, ui.row({ align = "center", gap = 8 }, {
		ui.glyph({ name = "server-2", size = 18, color = "primary" }),
		ui.label({ text = noctalia.tr("panel.title"), fontSize = 15, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
		ui.button({ glyph = "refresh", variant = "ghost", tooltip = noctalia.tr("panel.refresh"), onClick = "onRefreshClicked" }),
		ui.button({ glyph = "close", variant = "ghost", tooltip = noctalia.tr("panel.close"), onClick = "onCloseClicked" }),
	}))

	-- Error banner
	if snapshot.error ~= nil then
		table.insert(children, ui.column({ gap = 4, padding = 8, radius = 8, fill = "error/0.10" }, {
			ui.label({ text = noctalia.tr("panel.error"), fontSize = 12, fontWeight = "bold", color = "error" }),
			ui.label({ text = snapshot.error, fontSize = 11, color = "on_surface_variant", maxLines = 3 }),
		}))
	end

	-- VM list or empty state
	if snapshot.total == 0 then
		table.insert(children, ui.row({ align = "center", gap = 8, padding = 16 }, {
			ui.glyph({ name = "inbox", size = 20, color = "on_surface_variant" }),
			ui.label({ text = noctalia.tr("panel.empty"), fontSize = 13, color = "on_surface_variant" }),
		}))
	else
		local cards = {}
		for _, vm in ipairs(snapshot.vms) do
			table.insert(cards, vmCard(vm))
		end
		table.insert(children, ui.scroll({ flexGrow = 1, gap = 8 }, cards))
	end

	-- Footer summary
	local footer = noctalia.tr("panel.footer", {
		running = tostring(snapshot.running or 0),
		paused = tostring(snapshot.paused or 0),
		total = tostring(snapshot.total or 0),
	})
	if (snapshot.updatedAt or 0) > 0 then
		footer = footer .. " · " .. noctalia.tr("panel.updated") .. " " .. noctalia.formatTime("%H:%M:%S", snapshot.updatedAt)
	end
	table.insert(children, ui.label({ text = footer, fontSize = 10, color = "on_surface_variant" }))

	panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 4 }, children))
end

noctalia.state.watch("vms", function(value)
	if type(value) == "table" then
		snapshot = value
		render()
	end
end)

function onRefreshClicked()
	noctalia.state.set("vm_action", { action = "refresh" })
end

function onCloseClicked()
	panel.close()
end

function onAutostartMenuAction(actionId, context)
	if actionId == "autostart" or actionId == "autostart-disable" or actionId == "autostart-once" then
		sendAction(actionId, context)
	end
end

function onOpen()
	render()
end
