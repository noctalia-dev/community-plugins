--!nonstrict
-- Process Monitor — background sampler (service).
--
-- Runs `ps` every refresh_interval ms, parses the rows, and publishes the
-- process list plus a lightweight CPU/RAM summary through the plugin state
-- channel. The bar widget and panel are pure subscribers.
--
-- Structure matches the proven audio-switcher/drive-health service pattern:
--   noctalia.setUpdateInterval(...) + function update() + a guarded runAsync.
--
-- Root-cause hardening (added 0.1.5):
--   * Every step logs via noctalia.log so runtime failures are visible in the
--     shell's plugin log instead of the silent "service stopped responding".
--   * The runAsync callback body runs under pcall: an internal error can no
--     longer take the service VM down and trip the watchdog; it logs instead.
--   * refreshedAtMs uses os.time()*1000 (milliseconds) so the sampler has no
--     dependency on noctalia.nowMs().
--   * stats is derived from the ps output itself (summed %cpu/%mem/rss), so the
--     bars work without noctalia.systemStats().

local function cfg(key)
	return noctalia.getConfig(key)
end

local function setState(key, val)
	noctalia.state.set(key, val)
end

local function st(key)
	return noctalia.state.get(key)
end

local function log(msg)
	noctalia.log("[procmon/service] " .. msg)
end

-- `args` is placed last so the fixed fields are positional and everything
-- after them is the full command line (which may contain spaces). The shell
-- pre-sorts by CPU and truncates to the top 80 rows so the Luau parse stays
-- tiny: parsing every process blew the async callback's CPU budget even with a
-- single-pass gmatch. The panel caps at 80 rows (MAX_ROWS), so parsing more is
-- wasted work -- top-80 is exactly what gets displayed.
-- The trailing ##STAT/##MEM sections carry real total CPU/RAM from /proc so the
-- bars read the machine's actual usage -- ps %cpu is a per-process lifetime
-- average, so summing the top rows and capping at 100 always pegged the bar.
local PS_CMD = "ps -eo pid=,user=,%cpu=,%mem=,rss=,stat=,time=,args= --sort=-%cpu | head -n 80"

-- Real total CPU/RAM come from /proc in a SEPARATE, tiny command so the async
-- callback that parses it stays far under the CPU budget. Folding the markers
-- into the ps command made one callback scan the whole ~15KB buffer two extra
-- times (string.match over the full output) and tipped it over the razor-thin
-- budget. Each callback now parses only its own small output.
local STATS_CMD = "grep '^cpu ' /proc/stat; echo '##MEM'; grep -E 'MemTotal:|MemAvailable:|SwapTotal:|SwapFree:' /proc/meminfo; echo '##LOAD'; cat /proc/loadavg"

-- Single-pass row pattern. ps -eo with trailing `=` emits no header. Six
-- space-delimited fields then `([^\n]*)` grabs the rest of the line (args, which
-- may contain spaces). Note: `.*` would cross newlines in Lua (dot matches `\n`),
-- collapsing every remaining row into the first one -- so args must be `[^\n]*`.
-- One gmatch pass, no per-token tables, no trim gsubs. ppid/etime are dropped
-- (not shown in the panel) to keep captures to a minimum for the CPU budget.
local ROW = "(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+([^\n]*)"

-- Upper bound on how long `ps` may take before we give up on a sample.
local PS_TIMEOUT_MS = 5000

local function parse(raw)
	local list, n = {}, 0
	for pidS, user, cpuS, memS, rssS, stat, timeS, args in raw:gmatch(ROW) do
		local pid = tonumber(pidS)
		if pid ~= nil then
			n += 1
			list[n] = {
				pid = pid,
				user = user,
				cpu = tonumber(cpuS) or 0,
				mem = tonumber(memS) or 0,
				rssMb = (tonumber(rssS) or 0) / 1024,
				stat = stat,
				cpuTime = timeS or "0:00",
				cmd = args,
			}
		end
	end
	return list
end

-- Real total CPU% from /proc/stat deltas between consecutive samples. ps %cpu is
-- a lifetime average, so we diff the kernel's cumulative jiffies instead.
local prevCpu = nil -- { busy, total }

local function sampleCpu(raw)
	local line = raw:match("^cpu%s+([^\n]+)")
	if not line then
		return nil
	end
	local t = {}
	for n in line:gmatch("%d+") do
		t[#t + 1] = tonumber(n)
	end
	if #t < 4 then
		return nil
	end
	-- cpu user nice system idle iowait irq softirq steal ... ; idle=iowait=0 load.
	local total, busy = 0, 0
	for i = 1, 8 do
		local v = t[i] or 0
		total += v
		if i ~= 4 and i ~= 5 then
			busy += v
		end
	end
	if not prevCpu then
		prevCpu = { busy = busy, total = total }
		return nil -- need one more sample to diff
	end
	local db = busy - prevCpu.busy
	local dt = total - prevCpu.total
	prevCpu = { busy = busy, total = total }
	if dt <= 0 then
		return 0
	end
	local pct = db / dt * 100
	if pct < 0 then
		pct = 0
	elseif pct > 100 then
		pct = 100
	end
	return math.floor(pct + 0.5)
end

local function sampleSwap(raw)
	local sec = raw:match("##MEM\n(.+)") or ""
	local totalKb = tonumber(sec:match("SwapTotal:%s*(%d+)") or "")
	if not totalKb or totalKb <= 0 then
		return nil
	end
	local freeKb = tonumber(sec:match("SwapFree:%s*(%d+)") or "")
	local usedKb = totalKb - (freeKb or 0)
	if usedKb < 0 then
		usedKb = 0
	end
	return math.floor(usedKb / totalKb * 100 + 0.5), math.floor(usedKb / 1024), math.floor(totalKb / 1024)
end

-- Load average (1/5/15 min) from /proc/loadavg.
local function sampleLoad(raw)
	local line = raw:match("##LOAD\n([^\n]+)")
	if not line then
		return nil
	end
	local a = {}
	for n in line:gmatch("%d+%.%d+") do
		a[#a + 1] = tonumber(n)
	end
	if #a >= 3 then
		return { a[1], a[2], a[3] }
	end
	return nil
end
local function sampleRam(raw)
	local sec = raw:match("##MEM\n(.+)") or ""
	local totalKb = tonumber(sec:match("MemTotal:%s*(%d+)") or "")
	local availKb = tonumber(sec:match("MemAvailable:%s*(%d+)") or "")
	if not totalKb or not availKb or totalKb <= 0 then
		return nil
	end
	local usedKb = totalKb - availKb
	if usedKb < 0 then
		usedKb = 0
	end
	return math.floor(usedKb / totalKb * 100 + 0.5), math.floor(usedKb / 1024), math.floor(totalKb / 1024)
end

-- inFlight counts outstanding async callbacks. sample() only starts when it is
-- 0, so a slow `ps` can never overlap the next tick's subprocesses -- overlapping
-- spawns were a big part of the CPU-budget blowout.
local inFlight = 0
local tick = 0

local function sample()
	if inFlight > 0 then
		return -- one in-flight sample at a time
	end
	tick += 1

	-- Cheap /proc stats every tick: the bars stay real-time.
	inFlight += 1
	noctalia.runAsync(STATS_CMD, function(res)
		local ok, perr = pcall(function()
			if res == nil or res.timedOut or res.exitCode ~= 0 then
				return
			end
			local cpuPct = sampleCpu(res.stdout)
			local ramPct, usedMb, totalMb = sampleRam(res.stdout)
			local swapPct, swapUsedMb, swapTotalMb = sampleSwap(res.stdout)
			local loadAvg = sampleLoad(res.stdout)
			setState("stats", {
				cpu = { usagePercent = cpuPct or 0 },
				ram = { usagePercent = ramPct or 0, usedMb = usedMb or 0, totalMb = totalMb or 0 },
				swap = { usagePercent = swapPct or 0, usedMb = swapUsedMb or 0, totalMb = swapTotalMb or 0 },
				loadAvg = loadAvg or { 0, 0, 0 },
			})
			setState("err", "")
		end)
		if not ok then
			log("stats callback error: " .. tostring(perr))
		end
		inFlight -= 1
	end, PS_TIMEOUT_MS)

	-- The `ps` subprocess is the biggest CPU cost; the process table changes
	-- slowly, so sample it every 2nd tick while stats stay fresh every tick.
	if tick % 2 == 1 then
		inFlight += 1
		noctalia.runAsync(PS_CMD, function(res)
			local ok, perr = pcall(function()
				if res == nil or res.timedOut or res.exitCode ~= 0 then
					local detail = res and (res.stderr or res.stdout or "") or "no result"
					setState("err", detail)
					return
				end
				local procs = parse(res.stdout)
				setState("procs", procs)
				setState("refreshedAtMs", os.time() * 1000)
			end)
			if not ok then
				log("ps callback error: " .. tostring(perr))
			end
			inFlight -= 1
		end, PS_TIMEOUT_MS)
	end
end

-- Seed placeholders so subscribers have something before the first sample.
setState("procs", {})
setState("stats", { cpu = { usagePercent = 0 }, ram = { usagePercent = 0, usedMb = 0, totalMb = 0 } })
setState("refreshedAtMs", 0)
setState("err", "")

local function refreshInterval()
	return tonumber(st("refreshMs") or cfg("refresh_interval")) or 1000
end

-- The panel's Refresh slider publishes its value here; re-arming the sampler
-- timer is how the fetch speed actually changes. Seeded from config so a
-- reload falls back to the user's saved setting.
setState("refreshMs", cfg("refresh_interval") or 1000)
noctalia.state.watch("refreshMs", function(v)
	local n = tonumber(v)
	if n and n > 0 then
		noctalia.setUpdateInterval(n)
		log("interval=" .. n)
	end
end)

noctalia.setUpdateInterval(refreshInterval())
log("loaded, interval=" .. refreshInterval())

function update()
	sample()
end
