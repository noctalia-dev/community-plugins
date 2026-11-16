local Layouts = require("./layouts")

local fixture = { layouts = {
	{ symbol = "T", name = "tile" },
	{ symbol = "S", name = "scroller" },
	{ symbol = "G", name = "grid" },
	{ symbol = "M", name = "monocle" },
	{ symbol = "K", name = "deck" },
	{ symbol = "CT", name = "center_tile" },
	{ symbol = "RT", name = "right_tile" },
	{ symbol = "VS", name = "vertical_scroller" },
	{ symbol = "VT", name = "vertical_tile" },
	{ symbol = "VG", name = "vertical_grid" },
	{ symbol = "VK", name = "vertical_deck" },
	{ symbol = "DW", name = "dwindle" },
	{ symbol = "F", name = "fair" },
	{ symbol = "VF", name = "vertical_fair" },
	{ symbol = "FL", name = "floating" },
} }

local config = {}
local decoded = fixture
local response = { exitCode = 0, stdout = "fixture" }
local canStart = true
local pending
local calls = {}
local mock = {
	getConfig = function(key) return config[key] end,
	tr = function(key) return key end,
	json = { decode = function(text)
		assert(text == "fixture")
		if decoded == "malformed" then error("invalid JSON") end
		return decoded
	end },
	runAsync = function(argv, callback, timeout)
		table.insert(calls, argv)
		assert(timeout == 3000)
		if not canStart then return false end
		pending = callback
		return true
	end,
}
for _, method in pairs(Layouts) do
	setfenv(method, setmetatable({ noctalia = mock }, { __index = getfenv(method) }))
end

local layouts = assert(Layouts.normalize(fixture))
assert(#layouts == 15)
for index, entry in ipairs(layouts) do
	assert(entry.name == fixture.layouts[index].name)
	assert(entry.symbol == fixture.layouts[index].symbol)
end
assert(Layouts.find(layouts, "K").name == "deck")
assert(Layouts.find(layouts, "VK").name == "vertical_deck")
assert(Layouts.find(layouts, "FL").name == "floating")
assert(Layouts.find(layouts, "D") == nil)
assert(Layouts.glyph(Layouts.find(layouts, "K")) == "layers-difference")
assert(Layouts.label(Layouts.find(layouts, "FL")) == "name_floating")

table.insert(fixture.layouts, { name = "future_layout", symbol = "NEW" })
layouts = assert(Layouts.normalize(fixture))
assert(#layouts == 16)
local future = assert(Layouts.find(layouts, "NEW"))
assert(Layouts.glyph(future) == "layout")
assert(Layouts.label(future) == "Future layout")
assert(Layouts.visible(future))
config.show_tile = false
assert(not Layouts.visible(layouts[1]))
config.show_tile = "false"
assert(not Layouts.visible(layouts[1]))
config.show_tile = "true"
assert(Layouts.visible(layouts[1]))
config.show_floating = false
assert(Layouts.visible(Layouts.find(layouts, "FL")))
config.show_future_layout = false
assert(Layouts.visible(future))
table.insert(fixture.layouts, { name = "tile", symbol = "duplicate" })
layouts = assert(Layouts.normalize(fixture))
assert(#layouts == 16 and layouts[1].symbol == "T")

for _, invalid in ipairs({
	false,
	{},
	{ layouts = {} },
	{ layouts = "bad" },
	{ layouts = { { name = "tile" } } },
	{ layouts = { { name = "", symbol = "T" } } },
	{ layouts = { { name = "tile", symbol = " " } } },
	{ layouts = { { name = 3, symbol = "T" } } },
	{ layouts = { { name = "tile", symbol = "T" }, false } },
	{ layouts = { named = { name = "tile", symbol = "T" } } },
}) do
	assert(Layouts.normalize(invalid) == nil)
end

assert(Layouts.active(nil) == "")
assert(Layouts.active({ monitors = {} }) == "")
assert(Layouts.active({ monitors = {
	{ active = false, layout_symbol = "T" },
	{ active = true, layout_symbol = "VK" },
} }) == "VK")

local completions = 0
local result
local function complete(value)
	completions = completions + 1
	result = value
end
Layouts.discover(complete)
assert(completions == 0)
assert(calls[1][1] == "mmsg" and calls[1][2] == "get" and calls[1][3] == "layouts")
pending(response)
assert(completions == 1 and #result == 16)

for _, badResponse in ipairs({
	{ exitCode = 1, stdout = "fixture" },
	{ exitCode = 0, stdout = "invalid" },
	{ exitCode = 0 },
}) do
	Layouts.discover(complete)
	pending(badResponse)
	assert(result == nil)
end
decoded = "malformed"
Layouts.discover(complete)
pending(response)
assert(result == nil)
decoded = { layouts = {} }
Layouts.discover(complete)
pending(response)
assert(result == nil)

canStart = false
local previous = completions
Layouts.discover(complete)
assert(completions == previous + 1 and result == nil)
canStart = true
decoded = fixture
Layouts.discover(complete)
pending(response)
assert(#result == 16)

print("Mango layout discovery tests passed")

return function(sources)
	local runtimeFixture = { layouts = {} }
	for index = 1, 16 do
		table.insert(runtimeFixture.layouts, fixture.layouts[index])
	end

	local function host(source)
		local state = { pending = {}, config = { show_text = true }, now = 0, renders = 0 }
		local environment = setmetatable({}, { __index = getfenv() })
		environment.os = { time = function() return state.now end }
		environment.require = function(path)
			assert(path == "./layouts.luau")
			return Layouts
		end
		environment.noctalia = {
			getConfig = function(key) return state.config[key] end,
			tr = function(key) return key end,
			json = { decode = function(value) return value end },
			setUpdateInterval = function(value) state.interval = value end,
			runAsync = function(argv, callback, timeout)
				assert(timeout == 3000 and type(argv) == "table")
				table.insert(state.pending, { argv = argv, callback = callback })
				return true
			end,
		}
		environment.barWidget = {
			setGlyph = function(value) state.glyph = value end,
			setText = function(value) state.text = value end,
			setColor = function(value) state.color = value end,
			setGlyphColor = function(value) state.glyphColor = value end,
		}
		environment.ui = setmetatable({}, { __index = function(_, kind)
			return function(props, children)
				return { kind = kind, props = props, children = children or {} }
			end
		end })
		environment.panel = {
			render = function(root)
				state.root = root
				state.renders = state.renders + 1
			end,
			close = function() environment.onClose() end,
		}
		for _, method in pairs(Layouts) do setfenv(method, environment) end
		setfenv(assert(loadstring(source)), environment)()
		state.env = environment
		function state.resolve(target, data, exitCode)
			for index, request in ipairs(state.pending) do
				if request.argv[2] == "get" and request.argv[3] == target then
					table.remove(state.pending, index)
					request.callback({ exitCode = exitCode or 0, stdout = data })
					return
				end
			end
			error("No pending query for " .. target)
		end
		function state.buttons()
			local buttons = {}
			local function visit(node)
				if node.kind == "button" then buttons[node.props.key] = node.props end
				for _, child in ipairs(node.children) do visit(child) end
			end
			visit(state.root)
			return buttons
		end
		return state
	end

	local monitors = { monitors = { { active = true, layout_symbol = "K" } } }
	local widget = host(sources.widget)
	widget.env.update()
	widget.env.update()
	assert(#widget.pending == 2)
	widget.resolve("all-monitors", monitors)
	assert(widget.text == "K")
	widget.resolve("layouts", runtimeFixture)
	assert(widget.text == "name_deck" and widget.glyph == "layers-difference")
	assert(widget.interval == 1000)
	widget.now = 1
	widget.env.update()
	assert(#widget.pending == 1)
	widget.resolve("all-monitors", { monitors = { { active = true, layout_symbol = "UNSEEN" } } })
	assert(widget.text == "UNSEEN" and #widget.pending == 0)
	widget.now = 5
	widget.env.update()
	widget.resolve("all-monitors", { monitors = { { active = true, layout_symbol = "UNSEEN" } } })
	assert(#widget.pending == 1)
	widget.resolve("layouts", nil, 1)
	assert(widget.text == "UNSEEN")
	widget.now = 6
	widget.env.update()
	assert(#widget.pending == 1)
	widget.resolve("all-monitors", monitors)
	assert(widget.text == "name_deck")
	widget.now = 10
	widget.env.update()
	widget.resolve("layouts", runtimeFixture)
	widget.resolve("all-monitors", { monitors = { { active = true, layout_symbol = "VK" } } })
	assert(widget.text == "name_vertical_deck")
	widget.config.show_glyph = false
	widget.config.custom_color = "primary"
	widget.now = 11
	widget.env.update()
	widget.resolve("all-monitors", nil, 1)
	assert(widget.text == "layout_unavailable" and widget.glyph == "")
	assert(widget.color == "primary" and widget.glyphColor == "primary")
	widget.now = 40
	widget.env.update()
	assert(#widget.pending == 2)
	widget.resolve("layouts", nil, 1)
	widget.resolve("all-monitors", monitors)
	assert(widget.text == "name_deck")

	local picker = host(sources.panel)
	for _, entry in ipairs(runtimeFixture.layouts) do
		picker.env.onOpen()
		picker.resolve("all-monitors", { monitors = { { active = true, layout_symbol = entry.symbol } } })
		picker.resolve("layouts", runtimeFixture)
		local buttons = picker.buttons()
		local count = 0
		for _ in pairs(buttons) do count = count + 1 end
		assert(count == 16)
		assert(buttons[entry.name].variant == "primary")
		buttons[entry.name].onClick()
		local dispatch = table.remove(picker.pending)
		assert(dispatch.argv[1] == "mmsg" and dispatch.argv[2] == "dispatch")
		assert(dispatch.argv[3] == "setlayout," .. entry.name and #dispatch.argv == 3)
	end

	picker.config.list_mode = true
	picker.config.show_tile = false
	picker.env.onOpen()
	picker.resolve("layouts", runtimeFixture)
	picker.resolve("all-monitors", monitors)
	assert(picker.buttons().tile == nil)
	assert(picker.buttons().floating.text == "name_floating")
	assert(picker.buttons().future_layout.text == "Future layout")
	local oldClick = picker.buttons().deck.onClick
	picker.env.onClose()
	oldClick()
	assert(#picker.pending == 0)

	picker.env.onOpen()
	picker.env.onClose()
	picker.env.onOpen()
	local renders = picker.renders
	picker.resolve("layouts", { layouts = { { name = "stale", symbol = "STALE" } } })
	picker.resolve("all-monitors", monitors)
	assert(picker.renders == renders)
	picker.resolve("layouts", nil, 1)
	picker.resolve("all-monitors", monitors)
	assert(picker.buttons().deck ~= nil and picker.buttons().stale == nil)

	local commandName = "future;echo injected"
	picker.env.onOpen()
	picker.resolve("layouts", { layouts = { { name = commandName, symbol = "SAFE" } } })
	picker.resolve("all-monitors", monitors)
	picker.buttons()[commandName].onClick()
	local dispatch = table.remove(picker.pending)
	assert(#dispatch.argv == 3 and dispatch.argv[3] == "setlayout," .. commandName)

	local unavailable = host(sources.panel)
	unavailable.env.onOpen()
	unavailable.resolve("layouts", nil, 1)
	unavailable.resolve("all-monitors", nil, 1)
	assert(next(unavailable.buttons()) == nil)
	unavailable.env.onOpen()
	unavailable.resolve("layouts", runtimeFixture)
	unavailable.resolve("all-monitors", monitors)
	assert(unavailable.buttons().floating ~= nil)
	print("Mango widget and panel runtime tests passed")
end