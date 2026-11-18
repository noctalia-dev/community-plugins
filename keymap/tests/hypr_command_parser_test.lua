local stateValues = {}
local watchers = {}
local sourcePath = "/tmp/keybind-test/keybind.lua"
local source = table.concat({
	"-- 1. Applications",
	[[hl.bind("SUPER + RETURN", hl.dsp.exec_cmd("kitty"), { description = "Terminal" })]],
	[=[hl.bind("SUPER + Q", hl.dsp.exec_cmd([[browser --private]]), { description = "Browser" })]=],
	[[hl.bind("SUPER + P", hl.dsp.exec_cmd("printf \"ok\""), { description = "Quoted" })]],
	[[hl.bind("SUPER + W", hl.dsp.window.close(), { description = "Close Window" })]],
}, "\n") .. "\n"

local liveBinds = {
	{ key = "RETURN", modmask = 64, description = "Terminal", has_description = true, dispatcher = "__lua" },
	{ key = "Q", modmask = 64, description = "Browser", has_description = true, dispatcher = "__lua" },
	{ key = "P", modmask = 64, description = "Quoted", has_description = true, dispatcher = "__lua" },
	{ key = "W", modmask = 64, description = "Close Window", has_description = true, dispatcher = "__lua" },
}

noctalia = {
	getConfig = function(key)
		local values = {
			compositor = "hyprland", hyprland_config = sourcePath,
			show_undescribed = true, merge_sequential = false,
		}
		return values[key]
	end,
	getenv = function() return "" end,
	expandPath = function(path) return path end,
	readFile = function(path) return path == sourcePath and source or nil end,
	fileExists = function(path) return path == sourcePath end,
	commandExists = function(command) return command == "hyprctl" end,
	runAsync = function(_command, callback, _timeout)
		callback({ exitCode = 0, timedOut = false, stdout = "live-binds" })
		return true
	end,
	json = { decode = function(value) assert(value == "live-binds") return liveBinds end },
	tr = function(key)
		if key == "category.other" then return "Other" end
		if key == "category.undescribed" then return "Without description" end
		return key
	end,
	state = {
		get = function(key) return stateValues[key] end,
		set = function(key, value)
			stateValues[key] = value
			if watchers[key] ~= nil then watchers[key](value) end
		end,
		watch = function(key, callback) watchers[key] = callback end,
	},
}

assert(loadfile("service.luau"))()

local snapshot = stateValues["keymap.snapshot"]
assert(type(snapshot) == "table" and snapshot.status == "ready", "service did not publish a ready snapshot")
local byDescription = {}
for _, category in ipairs(snapshot.categories or {}) do
	for _, bind in ipairs(category.binds or {}) do byDescription[bind.description] = bind end
end

assert(byDescription.Terminal.command == "kitty", "double-quoted exec_cmd was not parsed")
assert(byDescription.Terminal.capabilities.command == true, "double-quoted command was not marked editable")
assert(byDescription.Browser.command == "browser --private", "long-string exec_cmd regressed")
assert(byDescription.Quoted.command == 'printf "ok"', "escaped quoted command was decoded incorrectly")
assert(byDescription["Close Window"].capabilities.command == false, "native action was exposed as a shell command")

print("hypr command parser tests: ok")
