--!nonstrict
-- The popout: real /status limits, live sessions, last 7 days of tokens.

local shared = require("./shared.luau")

local data = nil
local open = false

local function heading(text)
  return ui.label({ text = text, fontSize = 11, fontWeight = "bold", color = "on_surface_variant" })
end

local function limitBar(label, block)
  local pct = math.floor((tonumber(block.used) or 0) + 0.5)
  local accent = shared.limitColour(pct)
  return ui.column({ gap = 4 }, {
    ui.row({ align = "center" }, {
      ui.label({ text = label, fontWeight = "medium" }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = pct .. "%", fontWeight = "bold", color = accent }),
    }),
    ui.progress({ progress = math.min(pct, 100) / 100, fill = accent, track = "surface_variant", height = 6, radius = 3 }),
    ui.label({ text = shared.fmtReset(block.resets_at), fontSize = 11, color = "on_surface_variant" }),
  })
end

local function focus(window)
  if window == nil or window == "" then return end
  noctalia.runAsync({ noctalia.expandPath(shared.FOCUS), tostring(window) }, function() end)
  panel.close()
end

local function sessionRow(s)
  local state = s.state or "idle"
  return ui.row({
    key = s.session_id,
    gap = 10,
    align = "center",
    padding = 8,
    radius = 10,
    fill = "surface_variant/0.5",
    onClick = s.window and function() focus(s.window) end or nil,
    tooltip = s.window and "Focus this terminal" or nil,
  }, {
    ui.box({ width = 8, height = 8, radius = 4, fill = shared.colour(state) }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = shared.basename(s.cwd), fontWeight = "medium", maxLines = 1 }),
      ui.label({ text = shared.home(s.cwd or ""), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.column({ gap = 1, align = "end" }, {
      ui.label({ text = shared.label(state), fontSize = 11, color = shared.colour(state) }),
      ui.label({ text = shared.fmtAgo(s.ts), fontSize = 11, color = "on_surface_variant" }),
    }),
  })
end

local DAY_LETTERS = { "S", "M", "T", "W", "T", "F", "S" }

local function weekChart(week)
  local days = week.daily or {}
  local peak = 1
  for _, d in ipairs(days) do
    peak = math.max(peak, tonumber(d.tokens) or 0)
  end
  local cols = {}
  for i, d in ipairs(days) do
    local y, m, dd = string.match(d.date or "", "(%d+)-(%d+)-(%d+)")
    local wday = y and os.date("*t", os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(dd), hour = 12 })).wday or 1
    local tokens = tonumber(d.tokens) or 0
    local today = i == #days
    table.insert(cols, ui.column({
      key = d.date,
      gap = 4,
      align = "center",
      flexGrow = 1,
      tooltip = string.format("%s · %s tok · %d req", d.date or "", shared.fmtTokens(tokens), tonumber(d.requests) or 0),
    }, {
      ui.spacer({ flexGrow = 1 }),
      ui.box({ width = 18, height = math.max(3, math.floor(56 * tokens / peak)), radius = 4,
        fill = today and shared.ACCENT or (shared.ACCENT .. "/0.5") }),
      ui.label({ text = DAY_LETTERS[wday], fontSize = 10, color = today and "on_surface" or "on_surface_variant" }),
    }))
  end
  return ui.column({ gap = 8 }, {
    ui.row({ align = "center" }, {
      ui.label({ text = shared.fmtTokens(week.tokens) .. " tok", fontWeight = "bold" }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = (tonumber(week.requests) or 0) .. " req", color = "on_surface_variant" }),
    }),
    ui.row({ gap = 4, height = 76 }, cols),
  })
end

local function render()
  if not open then return end
  local d = data or {}
  local state = d.state or "idle"
  local sessions = d.sessions or {}
  local limits = d.limits or {}
  local n = #sessions

  local subtitle = string.format("%s · %d %s", shared.label(state), n, n == 1 and "session" or "sessions")
  if limits.model then
    subtitle = subtitle .. " · " .. limits.model
  end

  local body = {
    ui.row({ gap = 12, align = "center" }, {
      ui.label({ text = shared.IDLE_GLYPH, fontSize = 26, fontWeight = "bold", color = shared.colour(state) }),
      ui.column({ gap = 2 }, {
        ui.label({ text = "Claude Code", fontSize = 16, fontWeight = "bold" }),
        ui.label({ text = subtitle, fontSize = 12, color = shared.colour(state) }),
      }),
    }),
  }

  if limits.five_hour then
    table.insert(body, limitBar("Session", limits.five_hour))
    if limits.seven_day then table.insert(body, limitBar("Week", limits.seven_day)) end
    if limits.seven_day_opus then table.insert(body, limitBar("Week (Opus)", limits.seven_day_opus)) end
  else
    table.insert(body, ui.label({ text = "Limits appear once a session renders its statusline",
      fontSize = 12, color = "on_surface_variant" }))
  end

  table.insert(body, ui.separator({}))
  table.insert(body, heading("SESSIONS"))
  if n == 0 then
    table.insert(body, ui.label({ text = "No sessions running", fontSize = 12, color = "on_surface_variant" }))
  else
    local rows = {}
    for _, s in ipairs(sessions) do
      table.insert(rows, sessionRow(s))
    end
    table.insert(body, ui.scroll({ gap = 6, flexGrow = 1 }, rows))
  end

  table.insert(body, ui.separator({}))
  table.insert(body, heading("LAST 7 DAYS"))
  table.insert(body, weekChart((d.usage or {}).week or {}))

  panel.render(ui.column({ gap = 12, padding = 16 }, body))
end

local function refresh()
  shared.read(function(fresh)
    data = fresh
    render()
  end, data)
end

function onOpen()
  open = true
  panel.setWantsSecondTicks(true)
  render()
  refresh()
end

function onClose()
  open = false
end

function update()
  refresh()
end
