--!nonstrict
-- Invisible bar widget. Its width is the current pixel-shift offset for this
-- slot; the engine service decides every width, this entry only draws it.

local id = nil
local output = nil -- barWidget.outputName() is nil inside state watchers, so keep it
local width = 0
local known = false
local lastHello = -math.huge

-- Widgets load one after another in bar order, and the shell recreates all
-- of them together (start-up, config reload, plugin reload). Spacers created
-- within WAVE_MS of each other form one wave and are numbered from 1 in load
-- order, so every spacer gets the same id again after each recreation.
local WAVE_MS = 1500

local function ensureId(): boolean
	if id then
		return true
	end
	output = barWidget.outputName()
	if not output then
		return false
	end
	local key = "spacer:wave:" .. output
	local now = noctalia.nowMs()
	local wave = noctalia.state.get(key)
	if type(wave) ~= "table" or now - (wave.at or 0) > WAVE_MS then
		wave = { at = now, n = 0 }
	end
	wave.n += 1
	wave.at = now
	noctalia.state.set(key, wave)
	id = `{output}#{wave.n}`
	return true
end

local function render()
	local w = math.max(width, 0)
	if barWidget.isVertical() then
		barWidget.render(ui.box({ width = 1, height = w, fill = "#00000000" }))
	else
		barWidget.render(ui.box({ width = w, height = 1, fill = "#00000000" }))
	end
end

local function hello()
	if not ensureId() then
		return
	end
	lastHello = os.time()
	noctalia.state.set("spacer:hello", { id = id, output = output, vertical = barWidget.isVertical() })
end

noctalia.state.watch("spacers:known", function(v)
	known = type(v) == "table" and id ~= nil and v[id] ~= nil
end)

noctalia.state.watch("engine:epoch", function()
	known = false
	hello()
end)

noctalia.state.watch("offsets", function(v)
	if type(v) ~= "table" or id == nil then
		return
	end
	local w = tonumber(v[id]) or 0
	if w ~= width then
		width = w
		render()
	end
	noctalia.state.set("ack:" .. id, v.seq or 0)
end)

function update()
	noctalia.setUpdateInterval(1000)
	local now = os.time()
	if (not known and now - lastHello >= 1) or now - lastHello >= 30 then
		hello()
	end
end

function onExit()
	if id then
		noctalia.state.set("spacer:bye", { id = id })
	end
end

render()
hello()
