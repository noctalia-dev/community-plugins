--!nonstrict
-- Controls panel for the unit whose bar widget was clicked: its state and
-- Start / Stop / Restart. Actions run in the action service (service.luau), which
-- notifies the same way the launcher does and publishes "result" when done.

local common = require("./common.luau")

local tr = common.tr
local target = nil -- { unit, scope }, from the clicked widget
local status = nil -- { load, active, sub, description }
local busy = false

local function matches(t)
  return type(t) == "table" and target ~= nil and t.unit == target.unit and t.scope == target.scope
end

local function subtitle()
  local parts = { common.scopeLabel(target.scope), common.stateText(status) }
  if status ~= nil and status.description ~= "" then
    table.insert(parts, status.description)
  end
  return table.concat(parts, " · ")
end

local render

local function act(verb)
  if target == nil or busy then
    return
  end
  busy = true
  render()
  noctalia.state.set("command", { verb = verb, unit = target.unit, scope = target.scope, seq = noctalia.nowMs() })
end

local function actionButton(verb, variant, enabled)
  return ui.button({
    text = tr("panel." .. verb),
    glyph = common.VERB_GLYPH[verb],
    variant = variant,
    enabled = enabled,
    flexGrow = 1,
    onClick = function()
      act(verb)
    end,
  })
end

render = function()
  if target == nil then
    panel.render(ui.column({ gap = 8 }, {
      ui.label({ text = tr("widget.no-unit"), color = "on_surface_variant" }),
    }))
    return
  end

  local glyph, color = common.stateIcon(status)
  local known = status ~= nil and status.load ~= "not-found"
  local running = known and common.isRunning(status.active)
  local canAct = known and not busy

  panel.render(ui.column({ gap = 10 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = glyph, color = color }),
      ui.label({ text = target.unit, fontSize = 14, fontWeight = "bold", maxLines = 1, flexGrow = 1 }),
    }),
    ui.label({
      text = if busy then tr("panel.busy") else subtitle(),
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 2,
    }),
    ui.row({ gap = 6 }, {
      actionButton("start", "primary", canAct and not running),
      actionButton("stop", "destructive", canAct and running),
      actionButton("restart", "outline", canAct and running),
    }),
  }))
end

local function fetch()
  if target == nil then
    return
  end
  local t = target
  common.queryUnit(t.scope, t.unit, function(st)
    if matches(t) then
      status = st
      render()
    end
  end)
end

function onOpen(_context)
  local t = noctalia.state.get("panel_target")
  if type(t) == "table" and type(t.unit) == "string" and t.unit ~= "" then
    target = { unit = t.unit, scope = if t.scope == "user" then "user" else "system" }
    status = if type(t.status) == "table" then t.status else nil
  else
    target = nil
    status = nil
  end
  busy = false
  render()
  fetch()
end

noctalia.state.watch("result", function(r)
  if matches(r) then
    busy = false
    fetch()
  end
end)
