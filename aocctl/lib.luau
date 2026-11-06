--!nonstrict
-- Shared by the bar widget and the panel: runs `aocctl ... --json`, picks the monitor an entry
-- controls, and formats values. Each entry gets its own copy (require() caches per entry).

local M = {}

M.PANEL = "manishmodak/aocctl:panel"

-- Runs aocctl with `args` plus --json and calls done(data, err): the decoded JSON, or nil and a
-- message. aocctl prints JSON on stdout even when it fails; `{"error": ...}` means the command
-- couldn't run at all, other non-zero exits (a write that read back differently) still carry data.
function M.run(args, timeoutMs, done)
  local argv = { "aocctl" }
  for _, a in ipairs(args) do
    table.insert(argv, a)
  end
  table.insert(argv, "--json")
  local started = noctalia.runAsync(argv, function(result)
    local ok, data = pcall(noctalia.json.decode, result.stdout or "")
    if ok and type(data) == "table" then
      if data.error then
        done(nil, tostring(data.error))
      else
        done(data, nil)
      end
    elseif result.timedOut then
      done(nil, "aocctl took too long to answer")
    else
      local err = noctalia.string.trim(result.stderr or "")
      done(nil, err ~= "" and err or `aocctl exited with code {result.exitCode}`)
    end
  end, timeoutMs or 15000)
  if not started then
    done(nil, "couldn't start aocctl")
  end
end

-- From `aocctl list --json`: the AOC monitor on `connector`, else (with `fallback`) the first
-- AOC monitor. nil when there's none to pick.
function M.pickDisplay(list, connector, fallback)
  local first = nil
  for _, d in ipairs(list.displays or {}) do
    if d.aoc then
      if d.connector == connector then
        return d
      end
      first = first or d
    end
  end
  return fallback and first or nil
end

-- "AOC 24G4"
function M.modelName(d)
  return `{d.mfg or "AOC"} {d.model or "monitor"}`
end

-- Whether aocctl can talk to the display (it has a DDC/CI bus)
function M.reachable(d)
  return d ~= nil and d.bus ~= nil
end

-- The shared state key holding a display's last known brightness, so the bar widget shows
-- changes made in the panel at once.
function M.brightnessKey(connector)
  return "brightness:" .. connector
end

return M
