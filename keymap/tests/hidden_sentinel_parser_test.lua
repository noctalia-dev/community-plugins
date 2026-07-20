local function xorByte(left, right)
	local result, place = 0, 1
	for _ = 1, 8 do
		if left % 2 ~= right % 2 then result = result + place end
		left, right, place = math.floor(left / 2), math.floor(right / 2), place * 2
	end
	return result
end

local function fingerprint(value)
	local hash = 2166136261
	for index = 1, #value do
		local low = hash % 256
		hash = hash - low + xorByte(low, value:byte(index))
		hash = (hash * 403 + (hash % 256) * 16777216) % 4294967296
	end
	return string.format("%08x", hash)
end

local function hex(value)
	local output = {}
	for index = 1, #value do output[#output + 1] = string.format("%02x", value:byte(index)) end
	return table.concat(output)
end

local function hiddenSnippet(compositor, comment, original)
	local indent = original:match("^([\t ]*)") or ""
	local marker = indent .. comment .. " Keymap hidden v1"
	local blockId = fingerprint(compositor .. "\0" .. original)
	local encoded = hex(original)
	local lines = { marker .. " begin " .. blockId .. " " .. fingerprint(original) }
	for offset = 1, #encoded, 96 do lines[#lines + 1] = marker .. " data " .. encoded:sub(offset, offset + 95) end
	lines[#lines + 1] = marker .. " end " .. blockId
	return table.concat(lines, "\n")
end

local function stateMock()
	local values, watchers = {}, {}
	return values, {
		get = function(key) return values[key] end,
		set = function(key, value)
			values[key] = value
			if watchers[key] then watchers[key](value) end
		end,
		watch = function(key, callback) watchers[key] = callback end,
	}
end

local function assertHidden(snapshot, source, original, raw)
	assert(snapshot.status == "ready", "hidden-only config must be ready")
	assert(snapshot.total == 0 and #(snapshot.categories or {}) == 0, "hidden bind leaked into active data")
	assert(#(snapshot.hidden or {}) == 1, "hidden target missing")
	local target = snapshot.hidden[1]
	assert(target.hidden == true and target.source == source, "hidden provenance missing")
	assert(target.start_line <= target.end_line and target.raw_snippet == raw, "hidden raw block/range mismatch")
	assert(target.fingerprint == fingerprint(raw), "hidden block fingerprint mismatch")
	assert(target.original_fingerprint == fingerprint(original), "original fingerprint mismatch")
	assert(target.capabilities.restore == true and target.capabilities.delete == true, "hidden capabilities missing")
	assert(type(target.id) == "string" and target.id ~= "", "hidden id missing")
	assert(#(snapshot.warnings or {}) >= 1, "malformed sentinel was not reported")
end

do
	local values, state = stateMock()
	local root, child = "/tmp/hidden/hyprland.lua", "/tmp/hidden/child.lua"
	local original = '-- Keymap bind-category: Media\nhl.bind("SUPER + H", hl.dsp.exec_cmd("true"), { description = "Hidden Hypr" })'
	local raw = hiddenSnippet("Hyprland", "--", original)
	local files = {
		[root] = 'require("child")\n',
		[child] = raw .. "\n-- Keymap hidden v1 begin BAD bad\n",
	}
	noctalia = {
		state = state, getConfig = function(key) return ({ compositor = "hyprland", hyprland_config = root })[key] end,
		getenv = function() return "" end, expandPath = function(path) return path end,
		fileExists = function(path) return files[path] ~= nil end, readFile = function(path) return files[path] end,
		commandExists = function() return true end, tr = function(key) return key end,
		runAsync = function(_, callback) callback({ exitCode = 0, timedOut = false, stdout = "[]" }); return true end,
		json = { decode = function() return {} end },
	}
	assert(loadfile("service.luau"))()
	assertHidden(values["keymap.snapshot"], child, original, raw)
end

do
	local values, state = stateMock()
	local root, child = "/tmp/hidden/config.kdl", "/tmp/hidden/child.kdl"
	local original = '    // Keymap bind-category: Media\n    Super+H hotkey-overlay-title="Hidden Niri" { spawn-sh "true"; }'
	local raw = hiddenSnippet("Niri", "//", original)
	local files = { [root] = 'include "child.kdl"\n', [child] = "binds {\n" .. raw .. "\n}\n// Keymap hidden V1 begin bad bad\n" }
	noctalia = {
		state = state, getConfig = function(key) return ({ compositor = "niri", niri_config = root })[key] end,
		getenv = function() return "" end, fileExists = function(path) return files[path] ~= nil end,
		readFile = function(path) return files[path] end, tr = function(key) return key end,
	}
	assert(loadfile("niri_service.luau"))()
	assertHidden(values["keymap.snapshot"], child, original, raw)
end

do
	local values, state = stateMock()
	local root, child = "/tmp/hidden/mango.conf", "/tmp/hidden/child.conf"
	local original = '# Keymap bind-category: Media\nbind=SUPER,H,spawn_shell,true #"Hidden Mango"'
	local raw = hiddenSnippet("MangoWC", "#", original)
	local files = { [root] = "source=child.conf\n", [child] = raw .. "\n# Keymap hidden v1 begin 00000000 00000000\n" }
	noctalia = {
		state = state, getConfig = function(key) return ({ compositor = "mangowc", mangowc_config = root })[key] end,
		getenv = function() return "" end, expandPath = function(path) return path end,
		fileExists = function(path) return files[path] ~= nil end, readFile = function(path) return files[path] end,
		tr = function(key) return key end,
	}
	assert(loadfile("mangowc_service.luau"))()
	assertHidden(values["keymap.snapshot"], child, original, raw)
end

print("hidden sentinel parser tests: ok")
