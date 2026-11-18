--!nonstrict
-- grim capture of one bar strip -> Rgb8 with the bar's long axis horizontal.

local ppm = require("../core/ppm.luau")
local tasks = require("./tasks.luau")

local M = {}
local counter = 0

local function tmpPath(): string
	counter += 1
	local dir = noctalia.getenv("XDG_RUNTIME_DIR")
	if dir == nil or dir == "" then
		dir = noctalia.pluginDataDir()
	end
	return `{dir}/pixel-shift-{noctalia.nowMs()}-{counter}.ppm` -- unique across shell instances
end

function M.available(): boolean
	return noctalia.commandExists("grim")
end

-- Must run inside a task. Returns an Rgb8, or nil and an error message.
function M.grab(geometry: string, transpose: boolean)
	local path = tmpPath()
	local res = tasks.await(function(done)
		if not noctalia.runAsync({ "grim", "-t", "ppm", "-g", geometry, path }, done, 5000) then
			done(nil)
		end
	end)
	if not res or res.exitCode ~= 0 or res.timedOut then
		noctalia.removeFile(path)
		return nil, (res and res.stderr ~= "" and res.stderr) or "grim did not run"
	end
	local data, err = tasks.await(function(done)
		if not noctalia.readFileAsync(path, done) then
			done(noctalia.readFile(path))
		end
	end)
	noctalia.removeFile(path)
	if not data then
		return nil, err or "capture unreadable"
	end
	local img, perr = ppm.parse(data)
	if not img then
		return nil, perr
	end
	if transpose then
		img = ppm.transpose(img)
	end
	return img
end

return M
