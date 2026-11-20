--!nonstrict
-- Remote Control sessions elsewhere: each account's live claude.ai/code sessions from
-- remote.sh, minus the ones running on this machine, published for the Live tab's
-- Elsewhere section, with a notification when one starts needing input.

local core = require("./service-core.luau")
local acc = require("./service-accounts.luau")
local accounts = core.accounts
local cfg, runJson, publish, script, isoToMs = core.cfg, core.runJson, core.publish, core.script, core.isoToMs
local M = {}

local remoteSeen = {} -- remote id -> last status category, for notifications

-- Every account's live Remote Control sessions, minus the ones running here.
function M.publishElsewhere()
  local out, alive = {}, {}
  local on = cfg("show_elsewhere", true)
  local multi = #acc.accountList() > 1
  for _, a in pairs(accounts) do
    for _, r in ipairs(on and a.remote.list or {}) do
      if not core.localBridges[r.id] then
        r.account, r.url, r.since = a.dir, "https://claude.ai/code/" .. r.id, isoToMs(r.lastEventAt) or 0
        out[#out + 1] = r
        alive[r.id] = true
        local was = remoteSeen[r.id]
        if was and was ~= "need_input" and r.category == "need_input" and cfg("notify_waiting", true) then
          noctalia.notify("Claude needs you (elsewhere)",
            (multi and `[{a.label}] ` or "") .. r.title .. (r.needs ~= "" and (": " .. r.needs) or ""))
        end
        remoteSeen[r.id] = r.category or ""
      end
    end
  end
  for id in pairs(remoteSeen) do if not alive[id] then remoteSeen[id] = nil end end
  table.sort(out, function(x, y)
    if (x.category == "need_input") ~= (y.category == "need_input") then return x.category == "need_input" end
    return x.since > y.since
  end)
  publish("elsewhere", out)
end

function M.fetchRemote(a)
  local rem = a.remote
  if rem.pending then return end
  rem.pending, rem.at = true, noctalia.nowMs()
  local started = runJson(script("remote.sh", a.dir), 20000, function(list, r)
    rem.pending = false
    local err = nil
    if list then
      rem.list = list
    else
      err = noctalia.string.trim(r.stderr or "")
      if err == "" then err = `exit {r.exitCode}` end
      -- Rate limited (curl -f reports the 429): skip ten minutes of the once-a-minute poll.
      if string.find(err, "429", 1, true) then rem.at = noctalia.nowMs() + 9 * 60000 end
    end
    if err ~= rem.err and err then noctalia.log(`claude-operator: remote sessions ({a.label}): {err}`) end
    rem.err = err
    M.publishElsewhere()
  end)
  if not started then rem.pending = false end
end

return M
