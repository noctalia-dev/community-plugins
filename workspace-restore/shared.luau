--!nonstrict
-- Runs wsr.py, which does all the Hyprland work and owns the state files.
-- Shared by the bar widget and the panel, which run in separate VMs.

local M = {}

local function script()
  return "python3 -I '" .. noctalia.pluginDir() .. "/wsr.py'"
end

local function quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end
M.quote = quote

-- Runs `wsr.py <args>` and hands the decoded JSON output (or nil) to cb.
function M.run(args, cb)
  noctalia.runAsync(script() .. " " .. args, function(result)
    if cb == nil then
      return
    end
    if type(result) ~= "table" or result.timedOut or result.exitCode ~= 0 then
      cb(nil)
      return
    end
    local data = noctalia.json.decode(result.stdout or "")
    cb(type(data) == "table" and data or nil)
  end)
end

-- A restore can wait up to 45 s for launched apps, so it runs detached and
-- the panel reads its report from the status afterwards.
function M.restore(args)
  noctalia.runAsync("setsid -f " .. script() .. " restore " .. args .. " >/dev/null 2>&1", function() end)
end

function M.status(cb)
  M.run("status", cb)
end

function M.ago(epoch)
  local s = os.time() - (tonumber(epoch) or 0)
  if s < 90 then
    return "just now"
  elseif s < 5400 then
    return tostring(math.floor(s / 60)) .. " min ago"
  elseif s < 172800 then
    return tostring(math.floor(s / 3600)) .. " h ago"
  end
  return tostring(math.floor(s / 86400)) .. " days ago"
end

return M
