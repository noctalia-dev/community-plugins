--!nonstrict
local sessions = noctalia.state.get("sessions") or {}
local accounts = noctalia.state.get("accounts") or {}
local style = noctalia.getConfig("bar_style") or "dots"
local limitsMode = noctalia.getConfig("bar_limits") or "5h" -- "5h" | "7d" | "5h_7d" | "all" | "none"
local gaugeStyle = noctalia.getConfig("bar_limits_style") or "bar" -- "bar" | "ring"
local SHOWN = { ["5h"] = { ["5h"] = true }, ["7d"] = { ["7d"] = true }, ["5h_7d"] = { ["5h"] = true, ["7d"] = true } }
local COLOR = { waiting = "error", busy = "primary", idle = "on_surface_variant/0.45" }
local MAX_DOTS = 8

local function resetsIn(ms)
  local left = ms and ms > noctalia.nowMs() and math.floor((ms - noctalia.nowMs()) / 60000) or nil
  if not left then return nil end
  return left >= 1440 and `{left // 1440}d {left % 1440 // 60}h` or `{left // 60}h {left % 60}m`
end

-- Noctalia has no circular progress control and images can't follow the theme palette, so the ring
-- is a 9x9 grid of tiny boxes: cells on the circle are filled clockwise from 12 o'clock up to `progress`.
local RING_N, RING_CELL = 9, 2
local function ring(progress, color)
  local c = (RING_N - 1) / 2
  local radius = c - 0.3
  local rows = {}
  for i = 0, RING_N - 1 do
    local cells = {}
    for j = 0, RING_N - 1 do
      local dx, dy = j - c, i - c
      local fill = "#00000000"
      if math.abs(math.sqrt(dx * dx + dy * dy) - radius) < 0.55 then
        local angle = (math.atan2(dx, -dy) / (2 * math.pi)) % 1
        fill = angle < progress and color or "on_surface/0.18"
      end
      cells[#cells + 1] = ui.box({ width = RING_CELL, height = RING_CELL, radius = RING_CELL / 2, fill = fill })
    end
    rows[#rows + 1] = ui.row({ gap = 0 }, cells)
  end
  return ui.column({ gap = 0 }, rows)
end

local function severity(p) return p >= 90 and "error" or p >= 70 and "secondary" or "primary" end

-- Compact limit readouts for one account: "5h ▬▬▭ 45%" per window picked by the bar_limits setting.
local function limitNodes(account, vertical)
  local nodes = {}
  if limitsMode == "none" or not account or not account.limits then return nodes end
  for _, w in ipairs(account.limits.windows or {}) do
    if limitsMode == "all" or (SHOWN[limitsMode] and SHOWN[limitsMode][w.label]) then
      local pct = math.floor(w.percent + 0.5)
      local color = severity(pct)
      local progress = math.max(0, math.min(100, pct)) / 100
      local gauge = gaugeStyle == "ring" and ring(progress, color)
        or ui.progress({ progress = progress, width = vertical and 16 or 28, height = 4, fill = color, track = "on_surface/0.18" })
      local kids = {
        ui.label({ text = w.label, fontSize = 9, color = "on_surface_variant" }),
        gauge,
        ui.label({ text = `{pct}%`, fontSize = 10, fontWeight = "bold", color = color }),
      }
      nodes[#nodes + 1] = vertical and ui.column({ gap = 2, align = "center" }, kids) or ui.row({ gap = 3, align = "center" }, kids)
    end
  end
  return nodes
end

local function render()
  local multi = #accounts > 1
  local labels = {}
  for _, a in ipairs(accounts) do labels[a.dir] = a.label end

  local busy, waiting, rows = 0, 0, {}
  for _, s in ipairs(sessions) do
    if s.status == "busy" then busy += 1 elseif s.status == "waiting" then waiting += 1 end
    local d = s.d or {}
    local what = s.status == "waiting" and (s.waitingFor ~= "" and s.waitingFor or "needs input")
      or s.status == "busy" and (d.tool or "working") or "idle"
    local title = d.title or s.name
    rows[#rows + 1] = { multi and `[{labels[s.account] or "?"}] {title}` or title, what }
  end

  local vertical = barWidget.isVertical()
  local children = {
    ui.glyph({ name = waiting > 0 and "bell-ringing" or "brain", size = 15,
      color = waiting > 0 and "error" or busy > 0 and "primary" or "on_surface_variant" }),
  }
  local function divider()
    children[#children + 1] = ui.box({ width = vertical and 10 or 1, height = vertical and 1 or 10, fill = "outline/0.6" })
  end
  -- With several accounts, each account's group starts with a small name tag so its dots and
  -- limits can be told apart (shorten long names with the account_labels setting).
  local function accountTag(account)
    if not multi then return end
    if #children > 1 then divider() end
    children[#children + 1] = ui.row({ paddingH = 5, paddingV = 1, radius = 6, fill = "secondary/0.18", align = "center" }, {
      ui.label({ text = account.label, fontSize = 9, fontWeight = "bold", color = "secondary" }),
    })
  end
  local function addLimits(account)
    local nodes = limitNodes(account, vertical)
    if #nodes > 0 then
      if #children > 1 then divider() end
      for _, n in ipairs(nodes) do children[#children + 1] = n end
    end
  end

  if style == "counts" or #sessions > MAX_DOTS then
    if waiting > 0 then children[#children + 1] = ui.label({ text = tostring(waiting), fontSize = 11, fontWeight = "bold", color = "error" }) end
    if #sessions > 0 then
      children[#children + 1] = ui.label({ text = `{busy}/{#sessions}`, fontSize = 11, color = busy > 0 and "primary" or "on_surface_variant" })
    end
    for _, a in ipairs(accounts) do
      if multi and #limitNodes(a, vertical) > 0 then accountTag(a) end
      addLimits(a)
    end
  else
    -- One dot per session (sessions arrive sorted waiting > busy > idle); with several accounts,
    -- one group of dots per account separated by a thin divider.
    -- Each account's limits follow its own dots.
    local groups = {}
    if multi then
      for _, a in ipairs(accounts) do groups[#groups + 1] = a end
    else
      groups[1] = { dir = false, limits = accounts[1] and accounts[1].limits }
    end
    for _, account in ipairs(groups) do
      local dots = {}
      for _, s in ipairs(sessions) do
        if not account.dir or s.account == account.dir then
          dots[#dots + 1] = ui.box({ width = 7, height = 7, radius = 4, fill = COLOR[s.status] or COLOR.idle })
        end
      end
      local nodes = limitNodes(account, vertical)
      if #dots > 0 or #nodes > 0 then
        accountTag(account)
        for _, d in ipairs(dots) do children[#children + 1] = d end
        if #dots > 0 and #nodes > 0 then divider() end
        for _, n in ipairs(nodes) do children[#children + 1] = n end
      end
    end
  end
  local props = { gap = 4, align = "center" }
  barWidget.render(vertical and ui.column(props, children) or ui.row(props, children))

  if #rows == 0 then rows[1] = { "Claude", "no sessions" } end
  for _, a in ipairs(accounts) do
    for _, w in ipairs(a.limits and a.limits.windows or {}) do
      local resets = resetsIn(w.resetsAt)
      rows[#rows + 1] = { multi and `{a.label} · {w.label} limit` or `{w.label} limit`,
        `{math.floor(w.percent + 0.5)}%` .. (resets and ` · resets in {resets}` or "") }
    end
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch("sessions", function(v) sessions = v or {}; render() end)
noctalia.state.watch("accounts", function(v) accounts = v or {}; render() end)
function onClick() noctalia.togglePanel("lfdominguez/claude-sessions:panel") end
-- `noctalia msg plugin lfdominguez/claude-sessions:bar focused click` toggles the panel (e.g. from a keybind)
function onIpc(ev) if ev == "click" then onClick() end end
render()
