--!nonstrict
-- Shared NVibrant logic: state kept in a file (shared by widget and panel), apply.sh runs through a queue.
local M = {}

local MAX = 1023
local running = false
local queued = nil

local function statePath()
  local dir = noctalia.pluginDataDir()
  return dir and (dir .. "/state.json") or nil
end

function M.load()
  local path = statePath()
  local state = { enabled = false, level = 512 }
  if path then
    local text = noctalia.readFile(path)
    if text then
      local ok, data = pcall(noctalia.json.decode, text)
      if ok and type(data) == "table" then
        state.enabled = data.enabled == true
        state.level = math.clamp(tonumber(data.level) or 512, 0, MAX)
      end
    end
  end
  return state
end

function M.save(state)
  local path = statePath()
  if path then
    noctalia.writeFile(path, noctalia.json.encode({ enabled = state.enabled, level = state.level }))
  end
end

local function run(value)
  -- setting: 0 = all ports, N = port N; apply.sh takes -1 for all ports, otherwise a 0-based index
  local idx = (tonumber(noctalia.getConfig("display_index")) or 0) - 1
  if running then
    queued = value
    return
  end
  running = true
  noctalia.runAsync({ "bash", noctalia.pluginDir() .. "/apply.sh", tostring(value), tostring(idx) }, function(result)
    running = false
    if queued ~= nil then
      local v = queued
      queued = nil
      run(v)
      return
    end
    local code = result.exitCode
    if code == 3 then
      noctalia.notifyError(noctalia.tr("toast.no_display.title"), noctalia.tr("toast.no_display.body"))
    elseif code == 5 or code == 6 then
      noctalia.notifyError(noctalia.tr("toast.no_ctm.title"), noctalia.tr("toast.no_ctm.body"))
    elseif code ~= 0 then
      noctalia.notifyError(noctalia.tr("toast.failed.title"), noctalia.tr("toast.failed.body"))
    end
  end)
end

-- Apply a level to the display (0 resets).
function M.apply(value)
  run(math.clamp(math.floor(value + 0.5), 0, MAX))
end

function M.toggle()
  local state = M.load()
  state.enabled = not state.enabled
  M.save(state)
  M.apply(state.enabled and state.level or 0)
  return state
end

M.MAX = MAX
return M
