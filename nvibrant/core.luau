--!nonstrict
-- Shared NVibrant logic. Two separate things are kept apart:
--   * the preference (state.json): the level the user picked and whether they want it on;
--   * the applied state (noctalia.state "applied"): what apply.sh actually managed to set this session.
-- The widget and the panel show the applied state, so a failed apply never looks like "on", and the preference
-- "on" is stored only after an apply succeeded, so a failure is not restored at the next session either.
local M = {}

local MAX = 1023
local running = false
local queued = nil -- { value = n, done = fn } waiting for the running apply to finish

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

-- true while a non-zero saturation is actually applied in this session
function M.appliedOn()
  local raw = noctalia.state.get("applied")
  if type(raw) ~= "string" then return false end
  local ok, data = pcall(noctalia.json.decode, raw)
  return ok and type(data) == "table" and data.on == true
end

local function report(code)
  if code == 3 then
    noctalia.notifyError(noctalia.tr("toast.no_display.title"), noctalia.tr("toast.no_display.body"))
  elseif code == 5 or code == 6 then
    noctalia.notifyError(noctalia.tr("toast.no_ctm.title"), noctalia.tr("toast.no_ctm.body"))
  else
    noctalia.notifyError(noctalia.tr("toast.failed.title"), noctalia.tr("toast.failed.body"))
  end
end

-- Applies `value` to every display; `done(ok)` is called with the result. While an apply runs, only the latest
-- request is kept (a dragged slider produces many), and its callback is the one that fires.
local function run(value, done)
  if running then
    queued = { value = value, done = done }
    return
  end
  running = true
  local started = noctalia.runAsync({ "bash", noctalia.pluginDir() .. "/apply.sh", tostring(value) }, function(result)
    running = false
    if queued ~= nil then
      local q = queued
      queued = nil
      run(q.value, q.done)
      return
    end
    local ok = result.exitCode == 0
    if ok then
      noctalia.state.set("applied", noctalia.json.encode({ on = value > 0, level = value }))
    else
      report(result.exitCode)
    end
    if done then done(ok) end
  end)
  if not started then
    running = false
    report(-1)
    if done then done(false) end
  end
end

-- Apply a level to the display (0 resets) without touching the stored preference.
function M.apply(value, done)
  run(math.clamp(math.floor(value + 0.5), 0, MAX), done)
end

-- Switch on or off. The preference is stored only when the apply succeeded.
function M.setEnabled(on, done)
  local state = M.load()
  M.apply(on and state.level or 0, function(ok)
    if ok then
      state.enabled = on
      M.save(state)
    end
    if done then done(ok) end
  end)
end

function M.toggle(done)
  M.setEnabled(not M.appliedOn(), done)
end

M.MAX = MAX
return M
