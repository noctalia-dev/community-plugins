-- dropkitty bar widget: a view of noctalia.state["dropkitty"] (published by service.luau).
-- Left click toggles, middle click flips position, scroll resizes, right click opens settings.
-- Helper failures notify; vertical scroll steps are batched until update().

local KEY = "dropkitty"
local GLYPH = "terminal-2"
local CLICK_TIMEOUT_MS = 15000
local pending = 0

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function helper()
  local dir = noctalia.pluginDir and noctalia.pluginDir()
  return dir and (dir .. "/bin/dropkitty") or nil
end

local function render(s)
  s = type(s) == "table" and s or {}
  barWidget.setGlyph(GLYPH)
  if s.error then
    barWidget.setGlyphColor("error")
    barWidget.setTooltip(tr("widget.error", { message = tostring(s.error) }))
  elseif s.badge ~= nil then
    barWidget.setGlyphColor(s.badge == 0 and "tertiary" or "error")
    if s.cmd then
      barWidget.setTooltip(tr("widget.finished_cmd", { cmd = s.cmd, code = tostring(s.badge), duration = s.duration }))
    else
      barWidget.setTooltip(tr("widget.finished", { code = tostring(s.badge) }))
    end
  elseif s.open then
    barWidget.setGlyphColor("primary")
    barWidget.setTooltip(tr("widget.open"))
  elseif s.alive then
    barWidget.setGlyphColor("on_surface")
    barWidget.setTooltip(tr("widget.hidden"))
  else
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setTooltip(tr("widget.stopped"))
  end
end

local function launch_failed(message)
  noctalia.notifyError(tr("widget.title"), message or tr("widget.launch_failed"))
end

-- The helper's stderr says why a gesture did nothing (no kitten, unsupported compositor).
local function report(result)
  if type(result) ~= "table" or result.exitCode == 0 then
    return
  end
  local msg = result.timedOut and "" or tostring(result.stderr or ""):gsub("%s+$", "")
  launch_failed(msg ~= "" and msg or nil)
end

function onClick()
  local bin = helper()
  -- Cold start: up to 5 s for the lock plus 3 s for kitty's socket.
  if not bin or not noctalia.runAsync({ bin, "toggle" }, report, CLICK_TIMEOUT_MS) then
    launch_failed()
  end
end

function onMiddleClick()
  local bin = helper()
  if not bin or not noctalia.runAsync({ bin, "position" }, report, CLICK_TIMEOUT_MS) then
    launch_failed()
  end
end

function onScroll(axis, steps, _startsGesture)
  if axis == "vertical" then
    pending = pending + steps
  end
end

function update()
  if pending == 0 then
    return
  end
  local steps = pending
  pending = 0
  local bin = helper()
  if not bin or not noctalia.runAsync({ bin, steps < 0 and "grow" or "shrink", tostring(math.min(90, math.abs(steps) * 5)) }, report, CLICK_TIMEOUT_MS) then
    launch_failed()
  end
end

function onRightClick()
  noctalia.openSettings()
end

noctalia.state.watch(KEY, render)
render(noctalia.state.get(KEY))
