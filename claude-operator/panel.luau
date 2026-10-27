--!nonstrict
-- Panel shell: header, tab bar, keyboard and lifecycle. Each tab is its own module
-- exposing render(ctx) and, optionally, show(ctx) (the tab became visible) and a
-- `nav` (kit.nav) for up/down/Return. Tabs read the service's state from ctx.S and
-- never poll; the heavier listings (sessions, CLAUDE.md, plugins) load on show.
local shared = require("./shared.luau")
local kit = require("./kit.luau")
local TABS = {
  { id = "live", label = "Live", glyph = "activity", mod = require("./tab-live.luau") },
  { id = "usage", label = "Usage", glyph = "chart-bar", mod = require("./tab-usage.luau") },
  { id = "sessions", label = "Sessions", glyph = "history", mod = require("./tab-sessions.luau") },
  { id = "claudemd", label = "Memory", glyph = "file-text", mod = require("./tab-claudemd.luau") },
  { id = "plugins", label = "Plugins", glyph = "puzzle", mod = require("./tab-plugins.luau") },
}
local BY_ID = {}
for _, t in ipairs(TABS) do BY_ID[t.id] = t end

local KEYS = { up = -1, down = 1 }
-- capture_keys reports one press and one release, so a held arrow repeats from the
-- frame tick, after a delay.
local REPEAT_DELAY_MS, REPEAT_STEP_MS = 350, 60

local isOpen = false
local active = "live"
local dirty = false
local heldStep, repeatIn = 0, 0

local S = {}
local function loadState()
  for _, k in ipairs({ "sessions", "recent", "accounts", "elsewhere", "usage", "pricing", "index", "pins" }) do
    S[k] = noctalia.state.get(k)
  end
  S.sessions, S.recent, S.accounts, S.elsewhere = S.sessions or {}, S.recent or {}, S.accounts or {}, S.elsewhere or {}
end
loadState()

local ctx
local render

local function rates() return type(S.pricing) == "table" and S.pricing.rates or nil end

local function header()
  local total = 0
  for _, s in ipairs(S.sessions) do total += (s.d and s.d.cost or 0) end
  local status, statusColor, statusGlyph = kit.statusLine(S, shared)
  local tab = BY_ID[active].mod
  return ui.row({ gap = 10, align = "center" }, {
    ui.column({ width = 30, height = 30, radius = 8, fill = "primary/0.15", align = "center", justify = "center" }, {
      ui.glyph({ name = "headset", size = 17, color = "primary" }),
    }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = "Claude Operator", fontSize = 15, fontWeight = "bold" }),
        total > 0 and kit.muted(`{shared.money(total, rates())} live`, 10) or ui.spacer({ width = 0 }),
      }),
      ui.row({ gap = 5, align = "center" }, {
        ui.glyph({ name = statusGlyph, size = 11, color = statusColor }),
        ui.label({ text = status, fontSize = 11, color = statusColor, maxLines = 1, flexGrow = 1 }),
      }),
    }),
    ui.button({ glyph = tab.busy and tab.busy(ctx) and "loader-2" or "refresh", variant = "ghost", controlSize = "sm",
      tooltip = "Refresh", onClick = function()
        if tab.refresh then tab.refresh(ctx) else shared.requestRefresh() end
      end }),
    ui.button({ glyph = "settings", variant = "ghost", controlSize = "sm", tooltip = "Settings",
      onClick = function() noctalia.openSettings() end }),
    ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", tooltip = "Close", onClick = function() panel.close() end }),
  })
end

local function tabBar()
  local buttons = {}
  for _, t in ipairs(TABS) do
    local label = t.label
    if t.id == "live" then
      local waiting = 0
      for _, s in ipairs(S.sessions) do if s.status == "waiting" then waiting += 1 end end
      if waiting > 0 then label = `{label} · {waiting}` end
    end
    buttons[#buttons + 1] = ui.button({ key = "tab-" .. t.id, glyph = t.glyph, text = label, variant = "ghost",
      controlSize = "sm", flexGrow = 1, selected = active == t.id,
      onClick = function()
        active = t.id
        if t.mod.show then t.mod.show(ctx) end
        render()
      end })
  end
  return ui.row({ gap = 4, align = "center" }, buttons)
end

-- A tab that throws would otherwise leave its last screen up (often "loading"), with
-- the error only in the log. Show it instead, and log each distinct one once.
local lastTabError = nil
local function tabBody()
  local ok, body = pcall(BY_ID[active].mod.render, ctx)
  if ok then return body end
  local message = tostring(body)
  if message ~= lastTabError then
    lastTabError = message
    noctalia.log(`claude-operator: {active} tab: {message}`)
  end
  return kit.notice("alert-triangle", `This tab hit an error: {message}`, "error")
end

render = function()
  if not isOpen then return end
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    header(),
    tabBar(),
    tabBody(),
  }))
end

ctx = {
  S = S,
  rates = rates,
  render = function() render() end,
  -- Hover bursts (enter/leave pairs) are coalesced to one render per frame.
  markDirty = function() dirty = true end,
  close = function() panel.close() end,
  setTab = function(id) active = id; if BY_ID[id].mod.show then BY_ID[id].mod.show(ctx) end; render() end,
}

for _, k in ipairs({ "sessions", "recent", "accounts", "elsewhere", "usage", "pricing", "index", "pins" }) do
  noctalia.state.watch(k, function(v)
    if k == "sessions" or k == "recent" or k == "accounts" or k == "elsewhere" then v = v or {} end
    S[k] = v
    render()
  end)
end

local function stopRepeat()
  heldStep = 0
end

function onKey(chord, pressed)
  local nav = BY_ID[active].mod.nav
  if not nav then return end
  if chord == "Return" or chord == "KP_Enter" then
    if pressed then nav:activate() end
    return
  end
  local step = KEYS[chord]
  if not step then return end
  if not pressed then
    if heldStep == step then stopRepeat() end
    return
  end
  heldStep, repeatIn = step, REPEAT_DELAY_MS
  if nav:move(step) then render() end
end

function onFrameTick(deltaMs)
  if heldStep ~= 0 then
    repeatIn -= deltaMs
    if repeatIn <= 0 then
      repeatIn = REPEAT_STEP_MS
      local nav = BY_ID[active].mod.nav
      if nav and nav:move(heldStep) then dirty = true else stopRepeat() end
    end
  end
  if dirty then dirty = false; render() end
end

function onOpen(_context)
  isOpen = true
  loadState()
  -- Every tab resets: a pointer that left while the panel was closing never reported it.
  for _, t in ipairs(TABS) do
    if t.mod.nav then t.mod.nav:reset() end
    if t.mod.opened then t.mod.opened(ctx) end
  end
  if BY_ID[active].mod.show then BY_ID[active].mod.show(ctx) end
  noctalia.state.set("panel_open", true)
  shared.requestRefresh("open")
  panel.setWantsSecondTicks(true)
  panel.setNeedsFrameTick(true)
  render()
end

function onClose()
  isOpen = false
  stopRepeat() -- a key held while the panel closes never reports its release
  for _, t in ipairs(TABS) do if t.mod.closed then t.mod.closed(ctx) end end
  noctalia.state.set("panel_open", false)
  panel.setWantsSecondTicks(false)
  panel.setNeedsFrameTick(false)
end

-- Second ticks keep the "3m ago" ages and countdowns moving; the list tabs have neither,
-- and re-rendering hundreds of session rows every second would be wasted work.
function update()
  if active == "live" or active == "usage" then render() end
end

-- `noctalia msg plugin edward/claude-operator:panel all tab sessions` switches tabs
-- (bind it next to panel-toggle to open straight onto one).
function onIpc(event, payload)
  if event == "tab" and BY_ID[payload or ""] then ctx.setTab(payload) end
end
