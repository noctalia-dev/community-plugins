--!nonstrict
-- Shared click / wheel handling for every display mode and the navigator panel.
-- Everything resolves by stable id against the *latest* model at the moment of the
-- action; render-time indices are never trusted.

local niri = require("./niri.luau")

local A = {}

function A.focusWorkspace(model, id)
  local ws = model.workspaces[id]
  if ws == nil or ws.isFocused then
    return false
  end
  niri.focusWorkspace(ws, model:focusedOutput())
  return true
end

function A.focusWindow(model, id)
  if model.windows[id] == nil or model:isWindowFocused(id) then
    return false
  end
  niri.focusWindow(id)
  return true
end

-- Wheel / navigator step on one output: -1 = up (towards idx 1), +1 = down.
function A.step(model, view, delta)
  local View = require("./view.luau")
  local target = View.neighbor(view, delta)
  if target == nil then
    return false
  end
  local ws = model.workspaces[target.id]
  if ws == nil then
    return false
  end
  -- Stepping an unfocused output must land on that output, not the focused one.
  niri.focusWorkspace(ws, model:focusedOutput())
  return true
end

return A
