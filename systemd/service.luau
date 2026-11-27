--!nonstrict
-- Headless action runner for the controls panel. The panel writes a "command"
-- ({ verb, unit, scope, seq }); this single service instance runs it exactly once,
-- whatever the number of bar widgets, and publishes "result" when it finishes so
-- the panel and the matching widgets refresh.

local common = require("./common.luau")

local VERBS = { start = true, stop = true, restart = true }

-- Never replay a command that was already in state when the service (re)loaded.
local current = noctalia.state.get("command")
local lastSeq = if type(current) == "table" and type(current.seq) == "number" then current.seq else 0

noctalia.state.watch("command", function(cmd)
  if type(cmd) ~= "table" or type(cmd.seq) ~= "number" or cmd.seq <= lastSeq then
    return
  end
  lastSeq = cmd.seq
  if not VERBS[cmd.verb] or (cmd.scope ~= "user" and cmd.scope ~= "system") then
    return
  end
  if type(cmd.unit) ~= "string" or cmd.unit == "" then
    return
  end
  common.runAction(cmd.verb, cmd.scope, cmd.unit, function(ok)
    noctalia.state.set("result", { unit = cmd.unit, scope = cmd.scope, ok = ok, seq = noctalia.nowMs() })
  end)
end)
