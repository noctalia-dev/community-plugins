--!nonstrict
-- The service's common ground: where its files live, its timers, the state that more
-- than one service module reads, and the helpers they all call (settings, JSON, running
-- a script, publishing to the panel). Required by every service-*.luau module and by
-- service.luau, which owns the tick. State a single module owns lives in that module.

local M = {}

M.PLUGIN = noctalia.pluginDir()
M.SCRIPTS = M.PLUGIN .. "/scripts"
M.HOME = noctalia.getenv("HOME") or ""
M.DEFAULT_DIR = M.HOME .. "/.claude"
M.DATA = noctalia.pluginDataDir()
M.PRICING = M.DATA .. "/pricing.json"
M.SAVED_ACCOUNTS = M.DATA .. "/accounts.json"
M.SAVED_LIMITS = M.DATA .. "/limits.json"
M.PINS = M.DATA .. "/pins.json"
M.INDEX_MS = 5 * 60000 -- the saved-session index; also rebuilt when a session ends

M.TICK_MS = 2000
M.SLOW_MS = 60000 -- account discovery, Recent, Remote Control
M.RANK = { waiting = 0, busy = 1, idle = 2 }
M.HOUR_MS, M.DAY_MS = 3600000, 86400000

-- Tables the modules change in place, so each may keep its own reference.
M.accounts = {} -- dir -> { dir, label, email, limits, limitsAt, limitsPending, limitsErr, remote = { list, at, pending, err } }
M.details = {} -- pid -> { key, data, pending }
-- Replaced by the tick each time: read them through this table, never through a copy.
M.current = {} -- the published, sorted live sessions
M.localBridges = {} -- claude.ai/code ids of Remote Control sessions running here

function M.cfg(key, fallback)
  local v = noctalia.getConfig(key)
  if v == nil then return fallback end
  return v
end

function M.minutes(key, fallback) return (tonumber(M.cfg(key, fallback)) or fallback) * 60000 end

function M.decode(text)
  local v = noctalia.json.decode(text or "")
  return type(v) == "table" and v or nil
end

-- Runs a script with argv, decodes its JSON stdout and hands it to done(value, result);
-- value is nil on a failed run or bad JSON. Returns false when the process did not start.
function M.runJson(argv, timeoutMs, done)
  return noctalia.runAsync(argv, function(r)
    done(r.exitCode == 0 and M.decode(r.stdout) or nil, r)
  end, timeoutMs)
end

-- Publishes only real changes: the tick runs every 2 s, and every state.set wakes the
-- widget, panel and launcher to re-render.
local published = {}
function M.publish(key, value)
  local encoded = noctalia.json.encode(value) or ""
  if published[key] == encoded then return end
  published[key] = encoded
  noctalia.state.set(key, value)
end

function M.script(name, ...)
  local argv = { "bash", M.SCRIPTS .. "/" .. name }
  for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
  return argv
end

-- "2026-10-01T20:29:59.766+00:00" -> epoch ms, honouring the offset.
function M.isoToMs(iso)
  local y, mo, d, h, mi, sec, sign, oh, om = string.match(iso or "",
    "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)[%.%d]*([%+%-]?)(%d*):?(%d*)")
  if not y then return nil end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  -- days since epoch (Howard Hinnant's days_from_civil)
  if mo <= 2 then y -= 1 end
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local doy = (153 * ((mo + 9) % 12) + 2) // 5 + d - 1
  local days = era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
  local secs = days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
  if sign ~= "" and oh ~= "" then
    local off = tonumber(oh) * 3600 + (tonumber(om) or 0) * 60
    secs = sign == "+" and secs - off or secs + off
  end
  return secs * 1000
end

return M
