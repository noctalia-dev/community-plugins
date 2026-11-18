--!nonstrict
-- Tiny coroutine runner so async steps (captures, waits) read top to bottom.
-- Tasks are resumed from the engine's update() tick, never from callbacks.

local M = {}
local running = {}

-- `onError(err)` hears about a task that fails; without it the error is logged.
function M.spawn(name: string, fn: () -> (), onError: ((any) -> ())?)
	table.insert(running, { name = name, co = coroutine.create(fn), onError = onError })
end

-- Inside a task: start a callback-style operation and wait for its result.
function M.await(start: ((...any) -> ()) -> ())
	local result = nil
	start(function(...)
		result = table.pack(...)
	end)
	while result == nil do
		coroutine.yield()
	end
	return table.unpack(result, 1, result.n)
end

function M.sleep(ms: number)
	local untilMs = noctalia.nowMs() + ms
	repeat
		coroutine.yield()
	until noctalia.nowMs() >= untilMs
end

function M.waitFor(pred: () -> boolean, timeoutMs: number): boolean
	local untilMs = noctalia.nowMs() + timeoutMs
	while not pred() do
		if noctalia.nowMs() >= untilMs then
			return false
		end
		coroutine.yield()
	end
	return true
end

function M.tick()
	for i = #running, 1, -1 do
		local t = running[i]
		local ok, err = coroutine.resume(t.co)
		if not ok then
			table.remove(running, i)
			if t.onError then
				t.onError(err)
			else
				noctalia.log(`pixel-shift: task {t.name} failed: {tostring(err)}`)
			end
		elseif coroutine.status(t.co) == "dead" then
			table.remove(running, i)
		end
	end
end

function M.active(): boolean
	return #running > 0
end

function M.running(name: string): boolean
	for _, t in ipairs(running) do
		if t.name == name then
			return true
		end
	end
	return false
end

function M.runningPrefix(prefix: string): boolean
	for _, t in ipairs(running) do
		if string.sub(t.name, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

return M
