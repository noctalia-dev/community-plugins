--!nonstrict
-- service.luau — runs sampler.py as one long-lived process and republishes its
-- output to the other entries through noctalia.state:
--   "snapshot" : the latest raw JSON line (string)
--   "history"  : { cpu = {0..1}, ram = {0..1}, gpu = {0..1} } totals, oldest first
--   "status"   : "starting" | "running" | "error: ..."

local HISTORY_LEN = 60

local history = { cpu = {}, ram = {}, gpu = {} }
local lastLineAt = 0
local generation = 0

local function push(list, v)
    table.insert(list, math.clamp(v or 0, 0, 1))
    while #list > HISTORY_LEN do
        table.remove(list, 1)
    end
end

local function shellQuote(s)
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function onLine(gen, line)
    if gen ~= generation then return end -- output of a stream we replaced
    if string.sub(line, 1, 1) ~= "{" then
        noctalia.log("sampler: " .. line)
        return
    end
    lastLineAt = os.time()
    noctalia.state.set("snapshot", line)

    local ok, snap = pcall(noctalia.json.decode, line)
    if ok and type(snap) == "table" then
        push(history.cpu, (snap.cpu and snap.cpu.pct or 0) / 100)
        local mem = snap.mem or {}
        push(history.ram, (mem.total or 0) > 0 and mem.used / mem.total or 0)
        push(history.gpu, (snap.gpu and snap.gpu.pct or 0) / 100)
        noctalia.state.set("history", history)
    end
    noctalia.state.set("status", "running")
end

local function start()
    generation += 1
    local gen = generation
    local dir = noctalia.pluginDir()
    if not dir then
        noctalia.state.set("status", "error: plugin directory unknown")
        return
    end
    if not noctalia.commandExists("python3") then
        noctalia.state.set("status", "error: python3 not found")
        return
    end
    local interval = math.floor(tonumber(noctalia.getConfig("interval_ms")) or 2000)
    local limit = math.floor(tonumber(noctalia.getConfig("rows_per_metric")) or 40)
    local sampler = shellQuote(dir .. "/sampler.py")
    -- Restart the sampler if it crashes; exit code 3 means our reader is gone.
    local cmd = string.format(
        "while :; do python3 -I %s --interval %d --limit %d; [ $? -eq 3 ] && exit 0; sleep 2; done",
        sampler, interval, limit
    )
    lastLineAt = os.time()
    noctalia.state.set("status", "starting")
    local ok = noctalia.runStream(cmd, function(line) onLine(gen, line) end)
    if not ok then
        noctalia.state.set("status", "error: could not start sampler")
    end
end

-- Watchdog: runStream has no close callback, so restart if output stops.
noctalia.setUpdateInterval(5000)
function update()
    local interval = (tonumber(noctalia.getConfig("interval_ms")) or 2000) / 1000
    if os.time() - lastLineAt > math.max(15, interval * 6) then
        noctalia.log("sampler silent, restarting")
        start()
    end
end

-- No onConfigChanged on purpose: without it the host restarts this runtime on a
-- settings change, which also terminates the running stream, so the sampler is
-- relaunched with the new interval instead of a second one piling up.

local saved = noctalia.state.get("history")
if type(saved) == "table" then
    history.cpu = saved.cpu or {}
    history.ram = saved.ram or {}
    history.gpu = saved.gpu or {}
end

start()
