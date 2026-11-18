--!nonstrict

local PANEL_ID = "yuuto/calculator:panel"

local result = "0"
local expression = ""
local hasError = false

local function maxLength()
	local value = noctalia.getConfig("max_bar_length")
	if type(value) ~= "number" then
		return 9
	end
	return math.clamp(math.floor(value), 3, 20)
end

local function compact(text)
	local limit = maxLength()
	if #text <= limit then
		return text
	end
	return text:sub(1, math.max(1, limit - 1)) .. "~"
end

local function badge()
	if noctalia.getConfig("show_bar_value") == false then
		return ""
	end
	if hasError then
		return noctalia.tr("state.error")
	end
	if result == "" or result == "0" then
		return ""
	end
	return compact(result)
end

local function render()
	local container = barWidget.isVertical() and ui.column or ui.row
	local text = badge()
	local color = hasError and "error" or "on_surface"

	barWidget.setTooltip(expression ~= "" and expression or noctalia.tr("bar.tooltip"))

	local children = {
		ui.glyph({ name = "calculator", color = color }),
	}

	if text ~= "" and not barWidget.isVertical() then
		table.insert(children, ui.label({ text = text, fontWeight = "bold", color = color }))
	end

	barWidget.render(container({ gap = 6, align = "center" }, children))
end

function update()
	render()
end

noctalia.state.watch("calc.result", function(value)
	if type(value) == "string" then
		result = value
		render()
	end
end)

noctalia.state.watch("calc.expression", function(value)
	if type(value) == "string" then
		expression = value
		render()
	end
end)

noctalia.state.watch("calc.error", function(value)
	hasError = value == true
	render()
end)

function onClick()
	noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
	noctalia.state.set("calc.result", "0")
	noctalia.state.set("calc.expression", "")
	noctalia.state.set("calc.last_expression", "")
	noctalia.state.set("calc.error", false)
end

function onIpc(event, _payload)
	if event == "toggle" then
		noctalia.togglePanel(PANEL_ID)
	end
end
