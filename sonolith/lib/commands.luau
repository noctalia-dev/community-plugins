--!nonstrict
-- Sends commands from a UI entry to the service, which runs them through the bridge.
--
--   local commands = require("./lib/commands.luau")
--   commands.init("nowplaying")
--   commands.send("player.toggle", nil, function(ok, result, err) ... end)
--
-- The entry writes { id, method, params } to cmd:<entry>; the service answers on res:<entry> with
-- { id, ok, result?, error? }. Every write is delivered, so commands sent back to back are not lost.

local S = require("./state.luau")

local M = {}

local entryId = nil
local seq = 0
local pending = {}

function M.init(id)
  entryId = id
  noctalia.state.watch(S.resKey(id), function(res)
    if type(res) ~= "table" then
      return
    end
    local cb = pending[res.id]
    if cb then
      pending[res.id] = nil
      cb(res.ok == true, res.result, res.error)
    end
  end)
end

-- cb(ok, result, error) is optional; error is { name, reason, retryAfterMs?, ... }.
function M.send(method, params, cb)
  assert(entryId, "commands.init() first")
  seq += 1
  local id = `{entryId}:{noctalia.nowMs()}:{seq}`
  if cb then
    pending[id] = cb
  end
  noctalia.state.set(S.cmdKey(entryId), { id = id, method = method, params = params or {} })
  return id
end

return M
