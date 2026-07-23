--!nonstrict

local opened = false
local requestSerial = 0
local outputs = {}
local destinationOutputs = {}
local sourceName = nil
local destinationName = nil
local sourceIndex = -1
local destinationIndex = -1
local render

local status = noctalia.state.get("mirror_status")
	or {
		phase = "stopped",
		running = false,
		available = noctalia.commandExists("wl-mirror"),
		command_available = noctalia.commandExists("wl-mirror"),
		message = "",
	}

local function tr(key, values)
	return noctalia.tr(key, values)
end

local function outputLabel(output)
	local description = output.description or ""
	if description == "" or description == output.name then
		return output.name
	end

	return output.name .. " — " .. description
end

local function findOutputIndex(items, name)
	for index, output in ipairs(items) do
		if output.name == name then
			return index - 1
		end
	end

	return -1
end

local function hasOutput(name)
	return name ~= nil and findOutputIndex(outputs, name) >= 0
end

local function rebuildDestinationOutputs()
	destinationOutputs = {}

	for _, output in ipairs(outputs) do
		if output.name ~= sourceName then
			table.insert(destinationOutputs, output)
		end
	end

	if findOutputIndex(destinationOutputs, destinationName) < 0 then
		destinationName = destinationOutputs[1] and destinationOutputs[1].name or nil
	end

	destinationIndex = findOutputIndex(destinationOutputs, destinationName)
end

local function refreshOutputs()
	local refreshed = noctalia.outputs() or {}
	outputs = {}

	for _, output in ipairs(refreshed) do
		if type(output.name) == "string" and output.name ~= "" then
			table.insert(outputs, output)
		end
	end

	table.sort(outputs, function(left, right)
		return left.name < right.name
	end)

	if (status.phase == "running" or status.phase == "starting") and hasOutput(status.source) then
		sourceName = status.source
	end

	if not hasOutput(sourceName) then
		sourceName = outputs[1] and outputs[1].name or nil
	end

	if
		(status.phase == "running" or status.phase == "starting")
		and status.destination ~= sourceName
		and hasOutput(status.destination)
	then
		destinationName = status.destination
	end

	sourceIndex = findOutputIndex(outputs, sourceName)
	rebuildDestinationOutputs()
end

local function labels(items)
	local result = {}
	for _, output in ipairs(items) do
		table.insert(result, outputLabel(output))
	end
	return result
end

local function phaseDetails()
	local phase = status.phase or "stopped"

	if phase == "running" then
		return tr("panel.status.running_title"), tr("panel.status.running_message"), "primary", "screen-share"
	elseif phase == "starting" then
		return tr("panel.status.starting_title"), tr("panel.status.starting_message"), "on_surface_variant", "loader-2"
	elseif phase == "stopping" then
		return tr("panel.status.stopping_title"), tr("panel.status.stopping_message"), "on_surface_variant", "loader-2"
	elseif phase == "error" then
		local message = status.message
		if message == nil or message == "" then
			message = tr("panel.status.error_message")
		end
		return tr("panel.status.error_title"), message, "error", "alert-circle"
	end

	local message = status.message
	if message == nil or message == "" then
		message = tr("panel.status.ready_message")
	end
	return tr("panel.status.ready_title"), message, "on_surface_variant", "devices"
end

local function section(title, control)
	return ui.column({ gap = 7 }, {
		ui.label({
			text = title,
			fontWeight = "medium",
			color = "on_surface_variant",
		}),
		control,
	})
end

render = function()
	local phase = status.phase or "stopped"
	local running = phase == "running"
	local busy = phase == "starting" or phase == "stopping"
	local available = status.available ~= false
	local validPair = sourceName ~= nil and destinationName ~= nil and sourceName ~= destinationName
	local canToggle = not busy and (running or (available and validPair))
	local stateTitle, stateMessage, stateColor, stateGlyph = phaseDetails()

	local actionText = tr("panel.action.start")
	local actionGlyph = "player-play"
	local actionVariant = "primary"

	if running then
		actionText = tr("panel.action.stop")
		actionGlyph = "player-stop"
		actionVariant = "destructive"
	elseif phase == "starting" then
		actionText = tr("panel.action.starting")
		actionGlyph = "loader-2"
	elseif phase == "stopping" then
		actionText = tr("panel.action.stopping")
		actionGlyph = "loader-2"
	end

	local hint = nil
	if not available then
		local message = status.message
		if status.command_available == false then
			message = tr("panel.wl_mirror_missing")
		elseif message == nil or message == "" then
			message = tr("panel.status.error_message")
		end
		hint = ui.label({
			text = message,
			color = "error",
			maxLines = 2,
		})
	elseif #outputs < 2 then
		hint = ui.label({
			text = tr("panel.two_monitors_required"),
			color = "error",
			maxLines = 2,
		})
	end

	local children = {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.row({ align = "center", gap = 9, flexGrow = 1 }, {
				ui.glyph({ name = "screen-share", size = 18, color = "primary" }),
				ui.label({
					text = tr("title"),
					fontSize = 16,
					fontWeight = "bold",
					color = "on_surface",
				}),
			}),
			ui.button({
				glyph = "close",
				variant = "ghost",
				tooltip = tr("panel.close"),
				onClick = "onCloseClicked",
			}),
		}),
		section(
			tr("panel.source_monitor"),
			ui.select({
				options = labels(outputs),
				selectedIndex = sourceIndex,
				placeholder = tr("panel.no_monitor"),
				controlSize = "md",
				enabled = not busy and not running and #outputs > 0,
				onChange = "onSourceChanged",
			})
		),
		section(
			tr("panel.destination_monitor"),
			ui.select({
				options = labels(destinationOutputs),
				selectedIndex = destinationIndex,
				placeholder = tr("panel.choose_another"),
				controlSize = "md",
				enabled = not busy and not running and #destinationOutputs > 0,
				onChange = "onDestinationChanged",
			})
		),
		ui.row({
			align = "center",
			gap = 9,
			fill = "surface_variant/0.45",
			radius = 9,
			padding = 10,
		}, {
			ui.glyph({ name = stateGlyph, size = 17, color = stateColor }),
			ui.column({ gap = 2, flexGrow = 1 }, {
				ui.label({ text = stateTitle, fontWeight = "medium", color = stateColor }),
				ui.label({
					text = stateMessage,
					color = "on_surface_variant",
					maxLines = 2,
				}),
			}),
		}),
	}

	if hint ~= nil then
		table.insert(children, hint)
	end

	table.insert(
		children,
		ui.button({
			text = actionText,
			glyph = actionGlyph,
			variant = actionVariant,
			controlSize = "lg",
			enabled = canToggle,
			onClick = "onToggleMirroring",
		})
	)

	panel.render(ui.column({ flexGrow = 1, gap = 14 }, children))
end

noctalia.state.watch("mirror_status", function(value)
	if type(value) ~= "table" then
		return
	end

	status = value

	if status.phase == "running" or status.phase == "starting" then
		sourceName = status.source or sourceName
		destinationName = status.destination or destinationName
	end

	if opened then
		refreshOutputs()
		render()
	end
end)

function onOpen(_context)
	opened = true
	status = noctalia.state.get("mirror_status") or status
	refreshOutputs()
	render()
end

function onClose()
	opened = false
end

function onSourceChanged(index, _text)
	local selected = outputs[(tonumber(index) or -1) + 1]
	if selected == nil then
		return
	end

	sourceName = selected.name
	sourceIndex = tonumber(index) or -1
	rebuildDestinationOutputs()
	render()
end

function onDestinationChanged(index, _text)
	local selected = destinationOutputs[(tonumber(index) or -1) + 1]
	if selected == nil or selected.name == sourceName then
		return
	end

	destinationName = selected.name
	destinationIndex = tonumber(index) or -1
	render()
end

function onToggleMirroring()
	local phase = status.phase or "stopped"

	if phase == "running" then
		status.phase = "stopping"
		status.message = tr("panel.status.stopping_message")
		render()

		requestSerial += 1
		noctalia.state.set("mirror_request", {
			action = "stop",
			serial = requestSerial,
		})
		return
	end

	if phase == "starting" or phase == "stopping" then
		return
	end

	if sourceName == nil or destinationName == nil or sourceName == destinationName then
		noctalia.notifyError(tr("title"), tr("panel.invalid_pair"))
		return
	end

	status.phase = "starting"
	status.source = sourceName
	status.destination = destinationName
	status.message = tr("panel.status.starting_message")
	render()

	requestSerial += 1
	noctalia.state.set("mirror_request", {
		action = "start",
		source = sourceName,
		destination = destinationName,
		serial = requestSerial,
	})
end

function onCloseClicked()
	panel.close()
end
