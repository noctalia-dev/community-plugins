--!nonstrict
-- Saved sessions and pins: the index of every saved session (list-sessions.sh) for the
-- Sessions tab and the launcher, and the pinned project dirs kept in pins.json.

local core = require("./service-core.luau")
local acc = require("./service-accounts.luau")
local decode, runJson, publish, script = core.decode, core.runJson, core.publish, core.script
local DATA, PINS = core.DATA, core.PINS
local M = {}

local indexPending = false
M.indexAt = -math.huge

-- Every saved session, for the Sessions tab and the launcher. list-sessions.sh caches
-- each transcript's summary, so a rebuild costs a stat per unchanged session.
function M.refreshIndex()
  if indexPending then return end
  indexPending, M.indexAt = true, noctalia.nowMs()
  local argv = script("list-sessions.sh", DATA .. "/sessions")
  for _, a in ipairs(acc.accountList()) do argv[#argv + 1] = a.dir end
  local started = runJson(argv, 60000, function(list, r)
    indexPending = false
    if not list then
      noctalia.log("claude-operator: session index failed: " .. noctalia.string.trim(r.stderr or ""))
      return
    end
    -- Published to every entry: ~190 KB for 490 sessions. The size is left out; the
    -- path stays, since deleting by a path rebuilt from cwd misses long, non-ASCII and
    -- empty-cwd project dirs.
    local kept = {}
    for _, x in ipairs(list) do
      x.size = nil
      if #x.prompt > 160 then x.prompt = string.sub(x.prompt, 1, 160) .. "…" end
      -- Agent SDK runs (hooks, scripts) are not sessions anyone resumes.
      if not x.auto then kept[#kept + 1] = x end
    end
    table.sort(kept, function(x, y) return x.mtime > y.mtime end)
    publish("index", kept)
  end)
  if not started then indexPending = false end
end

-- Replaced on every toggle: read it through this table.
M.pins = decode(noctalia.readFile(PINS)) or {}

function M.togglePin(cwd)
  if type(cwd) ~= "string" or cwd == "" then return end
  local out, found = {}, false
  for _, p in ipairs(M.pins) do
    if p == cwd then found = true else out[#out + 1] = p end
  end
  if not found then out[#out + 1] = cwd end
  M.pins = out
  noctalia.writeFile(PINS, noctalia.json.encode(M.pins))
  publish("pins", M.pins)
end

return M
