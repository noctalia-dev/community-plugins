--!nonstrict
-- Duration picker and status panel. Mirrors Omarchy's terminal flow (choose a
-- duration, read the warning, confirm) as one Noctalia panel; the password is
-- then asked by Noctalia's polkit dialog.

local common = require("./lib/common.luau")
local tr = noctalia.tr

local TEXT_WIDTH = 344
local selected = "15"
local showClose = true
local isOpen = false

local function wrap(text, props)
  props = props or {}
  props.text = text
  props.maxWidth = props.maxWidth or TEXT_WIDTH
  props.maxLines = props.maxLines or 4
  return ui.label(props)
end

local function statusLine(s)
  if not s.known then
    return tr("panel.checking"), "on_surface_variant"
  end
  if not s.active then
    return tr("panel.status_off"), "on_surface_variant"
  end
  if s.mode == "timed" then
    return tr("panel.status_timed", {
      time = common.formatClock(s.deadline),
      span = common.formatRemaining(s.deadline - common.nowSec()),
    }), "error"
  elseif s.mode == "permanent" then
    return tr("panel.status_permanent"), "error"
  end
  return tr("panel.status_external"), "error"
end

local function header(s)
  local text, color = statusLine(s)
  local children = {
    ui.column({
      width = 40,
      height = 40,
      radius = 20,
      align = "center",
      justify = "center",
      fill = s.active and "error/0.15" or "primary/0.15",
    }, {
      ui.glyph({ name = "shield-lock", size = 22, color = s.active and "error" or "primary" }),
    }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = text, fontSize = 12, color = color, maxWidth = 280, maxLines = 2 }),
    }),
  }
  if showClose then
    table.insert(children, ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", onClick = function() panel.close() end }))
  end
  return ui.row({ gap = 12, align = "center" }, children)
end

local function durationGrid(s)
  local buttons = {}
  for _, d in ipairs(common.DURATIONS) do
    local isSel = d.value == selected
    table.insert(buttons, ui.button({
      key = "dur-" .. d.value,
      text = tr(d.key),
      glyph = d.value == "permanent" and "infinity" or "clock-hour-4",
      variant = isSel and "primary" or "outline",
      selected = isSel,
      enabled = not s.busy,
      flexGrow = 1,
      onClick = function()
        selected = d.value
        render()
      end,
    }))
  end
  return ui.column({ gap = 8 }, {
    ui.row({ gap = 8 }, { buttons[1], buttons[2] }),
    ui.row({ gap = 8 }, { buttons[3], buttons[4] }),
  })
end

local function warningCard()
  local span = common.durationPhrase(selected)
  local expiry = selected == "permanent" and tr("warning.expiry_permanent")
    or tr("warning.expiry_timed", { span = common.formatRemaining(tonumber(selected) * 60) })
  return ui.column({
    gap = 8,
    padding = 12,
    radius = 12,
    fill = "error/0.08",
    border = "error/0.35",
    borderWidth = 1,
  }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "alert-triangle", size = 18, color = "error" }),
      ui.label({ text = tr("warning.title"), fontWeight = "bold", color = "error" }),
    }),
    wrap(tr("warning.body", { span = span }), { color = "on_surface", fontSize = 13, maxWidth = TEXT_WIDTH - 24 }),
    wrap(tr("warning.agents"), { color = "on_surface_variant", fontSize = 12, maxWidth = TEXT_WIDTH - 24 }),
    wrap(expiry, { color = "on_surface_variant", fontSize = 12, maxWidth = TEXT_WIDTH - 24 }),
  })
end

local function busyRow()
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "loader-2", size = 16, color = "primary" }),
    ui.label({ text = tr("panel.waiting"), color = "on_surface_variant" }),
  })
end

local function enableAndClose()
  common.send("enable", selected)
  panel.close()
end

local function disableAndClose()
  common.send("disable")
  panel.close()
end

function render()
  local s = common.status()
  local body = { header(s), ui.separator({}) }

  if s.busy then
    table.insert(body, busyRow())
  end

  if s.active and s.mode == "external" then
    table.insert(body, wrap(tr("panel.external_note"), { color = "on_surface_variant" }))
    table.insert(body, ui.row({ gap = 8, justify = "end" }, {
      ui.button({ text = tr("button.close"), variant = "ghost", onClick = function() panel.close() end }),
    }))
  elseif s.active then
    table.insert(body, ui.label({ text = tr("panel.change_prompt"), fontWeight = "semibold", color = "on_surface" }))
    table.insert(body, durationGrid(s))
    table.insert(body, warningCard())
    table.insert(body, ui.row({ gap = 8, justify = "end" }, {
      ui.button({ text = tr("button.apply"), glyph = "refresh", variant = "outline", enabled = not s.busy, onClick = enableAndClose }),
      ui.button({ text = tr("button.disable"), glyph = "shield-check", variant = "primary", enabled = not s.busy, onClick = disableAndClose }),
    }))
  else
    table.insert(body, ui.label({ text = tr("panel.prompt"), fontWeight = "semibold", color = "on_surface" }))
    table.insert(body, durationGrid(s))
    table.insert(body, warningCard())
    table.insert(body, ui.row({ gap = 8, justify = "end" }, {
      ui.button({ text = tr("button.cancel"), variant = "ghost", onClick = function() panel.close() end }),
      ui.button({
        text = tr("button.enable", { span = common.durationPhrase(selected) }),
        glyph = "lock-open",
        variant = "destructive",
        enabled = s.known and not s.busy,
        onClick = enableAndClose,
      }),
    }))
  end

  panel.render(ui.column({ gap = 14 }, body))
end

function onOpen(_context)
  isOpen = true
  showClose = noctalia.getSetting("shell.show_close_buttons") ~= false
  local s = common.status()
  if s.active and s.mode == "permanent" then
    selected = "permanent"
  elseif not s.active then
    selected = "15"
  end
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  isOpen = false
end

function update()
  if isOpen then
    render()
  end
end

noctalia.state.watch("status", function()
  if isOpen then
    render()
  end
end)
