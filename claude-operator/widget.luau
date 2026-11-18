--!nonstrict
-- Bar widget, the switchboard at a glance: a lamp per live session (red needs you and
-- blinks, accent working, dim idle) and one nested gauge for the plan windows (5h inside
-- 7d, faint arc = where the current rate takes each by the reset), then their numbers.
-- Renders published state only; left click is a [widget.actions] default in plugin.toml.
local shared = require("./shared.luau")
local gauge = require("./gauge.luau")

local sessions = noctalia.state.get("sessions") or {}
local accounts = noctalia.state.get("accounts") or {}
local elsewhere = noctalia.state.get("elsewhere") or {}
local usage = noctalia.state.get("usage")
local pricing = noctalia.state.get("pricing")
local open = noctalia.state.get("panel_open") == true
local blinkOff = false

local function setting(key, fallback) return noctalia.getConfig(key) or fallback end

-- Short window label for the text and bar styles: "5h", "7d", or the model's initial ("F7d").
local function shortLabel(w)
  if w.kind == "session" then return "5h" end
  if w.kind == "weekly_all" then return "7d" end
  return string.sub(w.model or "?", 1, 1) .. "7d"
end

local function limitNodes(limits, vertical)
  local windows = gauge.pick(limits, setting("bar_limits", "5h_7d"))
  if #windows == 0 then return {} end
  local style = setting("bar_limits_style", "gauge")
  local nodes = {}
  local paces = {}
  for i, w in ipairs(windows) do paces[i] = shared.pace(w) end

  if style == "gauge" then
    local rings = {}
    for i, w in ipairs(windows) do
      rings[i] = { percent = w.percent, projected = paces[i].projected, role = shared.paceColor(paces[i].status, "primary") }
    end
    nodes[#nodes + 1] = ui.image({ path = gauge.image(rings), width = 22, height = 22 })
    -- "35·32%": the numbers in ring order, inside out.
    local kids = {}
    for i, w in ipairs(windows) do
      if i > 1 then kids[#kids + 1] = ui.label({ text = "·", fontSize = 11, color = "on_surface_variant" }) end
      kids[#kids + 1] = ui.label({ text = tostring(shared.round(w.percent)) .. (i == #windows and "%" or ""), fontSize = 11,
        color = shared.paceColor(paces[i].status, "on_surface") })
    end
    nodes[#nodes + 1] = ui.row({ gap = 2, align = "center" }, kids)
  else
    for i, w in ipairs(windows) do
      local kids = { ui.label({ text = shortLabel(w), fontSize = 9, color = "on_surface_variant" }) }
      if style == "bar" then
        kids[#kids + 1] = ui.progress({ progress = math.max(0, math.min(100, w.percent)) / 100,
          width = vertical and 16 or 26, height = 4, fill = shared.paceColor(paces[i].status, "primary"), track = "on_surface/0.18" })
      end
      kids[#kids + 1] = ui.label({ text = `{shared.round(w.percent)}%`, fontSize = 11, color = shared.paceColor(paces[i].status, "on_surface") })
      nodes[#nodes + 1] = vertical and ui.column({ gap = 2, align = "center" }, kids) or ui.row({ gap = 3, align = "center" }, kids)
    end
  end
  -- Last known numbers stay visible while the token is expired, dimmed. Always set: the
  -- host keeps a prop a later render leaves out, so a dimmed gauge would stay dimmed.
  for _, n in ipairs(nodes) do n.props.opacity = limits.stale and 0.5 or 1 end
  return nodes
end

local function tooltip()
  local rows = {}
  local function row(key, value) rows[#rows + 1] = { key = key, value = value } end
  for _, s in ipairs(sessions) do
    local d = s.d or {}
    row(d.title or s.name, s.status == "waiting" and ("needs you" .. (s.waitingFor ~= "" and (" · " .. s.waitingFor) or ""))
      or s.status == "busy" and (d.tool or "working") or "idle")
  end
  for _, r in ipairs(elsewhere) do
    row(r.title .. " (elsewhere)", r.category == "need_input" and ("needs you" .. (r.needs ~= "" and (" · " .. r.needs) or "")) or "remote")
  end
  if #rows == 0 then row("Claude", "no sessions running") end

  local limits = accounts[1] and accounts[1].limits
  if limits then
    row("Plan", shared.planName(limits.subscription, limits.tier))
    for _, w in ipairs(limits.windows or {}) do
      row(w.label, `{shared.round(w.percent)}%  ·  {shared.paceText(w)}`)
    end
    if limits.stale then row("Limits", `updated {shared.ago(limits.updated)} ago` .. (limits.error and ` · {limits.error}` or "")) end
  end
  if type(usage) == "table" then
    local rates = type(pricing) == "table" and pricing.rates or nil
    row("Today", `{shared.money(usage.todayCost, rates)}  ·  {shared.tokens(usage.todayTokens)} tokens`)
    row("7 days", `{shared.money(usage.d7Cost, rates)}  ·  {shared.tokens(usage.d7Tokens)} tokens`)
  end
  return rows
end

local function waitingCount()
  local n = 0
  for _, s in ipairs(sessions) do if s.status == "waiting" then n += 1 end end
  -- Remote Control sessions on other machines ring the bell but get no lamp.
  for _, r in ipairs(elsewhere) do if r.category == "need_input" then n += 1 end end
  return n
end

local function render()
  local vertical = barWidget.isVertical()
  local waiting, busy = waitingCount(), 0
  for _, s in ipairs(sessions) do if s.status == "busy" then busy += 1 end end
  -- Blink only while someone waits; otherwise a minute is enough for pace colours.
  noctalia.setUpdateInterval(waiting > 0 and 600 or 60000)
  if waiting == 0 then blinkOff = false end

  local children = {
    ui.glyph({ name = waiting > 0 and "bell-ringing" or setting("glyph", "headset"), size = 16,
      color = waiting > 0 and "error" or (open or busy > 0) and "primary" or "on_surface" }),
  }
  if setting("bar_style", "dots") == "counts" then
    if waiting > 0 then children[#children + 1] = ui.label({ text = tostring(waiting), fontSize = 11, fontWeight = "bold", color = "error" }) end
    if #sessions > 0 then
      children[#children + 1] = ui.label({ text = `{busy}/{#sessions}`, fontSize = 11, color = busy > 0 and "primary" or "on_surface_variant" })
    end
  elseif #sessions > 0 then
    children[#children + 1] = gauge.lamps(sessions, 7, blinkOff)
  end
  for _, n in ipairs(limitNodes(accounts[1] and accounts[1].limits, vertical)) do children[#children + 1] = n end

  local props = { gap = 5, align = "center" }
  barWidget.render(vertical and ui.column(props, children) or ui.row(props, children))
  barWidget.setTooltip(tooltip())
end

noctalia.state.watch("sessions", function(v) sessions = v or {}; render() end)
noctalia.state.watch("accounts", function(v) accounts = v or {}; render() end)
noctalia.state.watch("elsewhere", function(v) elsewhere = v or {}; render() end)
noctalia.state.watch("usage", function(v) usage = v; render() end)
noctalia.state.watch("pricing", function(v) pricing = v; render() end)
noctalia.state.watch("panel_open", function(v) open = v == true; render() end)
function onConfigChanged() render() end
-- `noctalia msg plugin edward/claude-operator:widget focused click` toggles the panel.
function onIpc(event) if event == "click" then noctalia.togglePanel("edward/claude-operator:panel") end end
function update()
  blinkOff = not blinkOff
  render()
end
render()
