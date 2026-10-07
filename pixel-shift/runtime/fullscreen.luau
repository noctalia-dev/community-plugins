--!nonstrict
-- Asks the compositor which outputs a fullscreen window covers. One short
-- process, only when the engine is about to do something that would recreate
-- or capture the bar anyway; never polled. Any failure counts as "nothing
-- covered", which is how the plugin behaved before it asked.

local core = require("../core/fullscreen.luau")
local tasks = require("./tasks.luau")

local M = {}
M.TTL_MS = 3000 -- one answer serves every caller within this time
M.WAIT_MS = 2500 -- longest a second caller waits for a query already running
M.RUN_MS = 2000 -- longest the compositor tool may take
M.host = nil -- the host API; tests put a fake here

local last = nil -- {at, covered}
local inflight = false
local failing = false -- the previous query failed (log a failure streak once)
local detected, detectedKind = false, nil

local function host()
	return M.host or noctalia
end

-- hyprland, sway or nil (anything else: no way to ask). Looked up once.
function M.kind(): string?
	if not detected then
		detected = true
		local h = host()
		detectedKind = core.compositor(h.getenv, h.commandExists)
	end
	return detectedKind
end

-- The covered set of the last answer while it is recent, else nil.
function M.fresh()
	if last and host().nowMs() - last.at < M.TTL_MS then
		return last.covered
	end
	return nil
end

-- The last answer however old, and its age in ms (for the debug line).
function M.last()
	return if last then last.covered else nil
end

function M.age(): number?
	return if last then host().nowMs() - last.at else nil
end

local function ask(kind: string)
	local h = host()
	local res = tasks.await(function(done)
		if not h.runAsync(core.argv(kind), done, M.RUN_MS) then
			done(nil)
		end
	end)
	if not res then
		return nil, "could not start"
	end
	if res.timedOut then
		return nil, "timed out"
	end
	if res.exitCode ~= 0 then
		local err = tostring(res.stderr or ""):gsub("%s+$", "")
		return nil, `exit {tostring(res.exitCode)}{if err ~= "" then ": " .. err else ""}`
	end
	local out = tostring(res.stdout or "")
	if kind == "hyprland" then
		local docs = core.splitBatch(out)
		local okM, monitors = pcall(h.json.decode, docs[1] or "")
		local okC, clients = pcall(h.json.decode, docs[2] or "")
		if not okM or not okC or type(monitors) ~= "table" or type(clients) ~= "table" then
			return nil, "unreadable answer"
		end
		return core.hyprland(monitors, clients)
	end
	local ok, tree = pcall(h.json.decode, out)
	if not ok or type(tree) ~= "table" then
		return nil, "unreadable answer"
	end
	return core.sway(tree)
end

-- Must run inside a task. The covered set, from the last answer if it is
-- recent. {} when the compositor cannot be asked or does not answer.
function M.query()
	local kind = M.kind()
	if not kind then
		return {}
	end
	local recent = M.fresh()
	if recent then
		return recent
	end
	if inflight then
		tasks.waitFor(function()
			return not inflight
		end, M.WAIT_MS)
		return M.fresh() or {}
	end
	inflight = true
	local ok, set, why = pcall(ask, kind)
	inflight = false
	if not ok then
		set, why = nil, tostring(set)
	end
	if set == nil then
		if not failing then
			host().log(`pixel-shift: could not ask the compositor about fullscreen windows: {why}`)
		end
		failing = true
		set = {}
	else
		failing = false
	end
	-- a failure is remembered too, so a step is not held up by asking again
	last = { at = host().nowMs(), covered = set }
	return set
end

-- Forget the compositor and every answer (tests).
function M.reset()
	last, inflight, failing, detected, detectedKind = nil, false, false, false, nil
end

-- Outside a task: start a query unless one is running or the answer is recent.
function M.request()
	if not M.kind() or M.fresh() or inflight or tasks.running("fullscreen") then
		return
	end
	tasks.spawn("fullscreen", function()
		M.query()
	end)
end

return M
