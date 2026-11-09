--!nonstrict
-- Task Warrior desktop widget: a fixed list of pending tasks on the wallpaper.
-- Pure view over the service's "tasks" state; the check button completes a task
-- (same "request" channel the panel uses) and clicking a row toggles the panel
-- for editing. Sorted by urgency, capped at the "max_tasks" setting.

local MAX_TASKS = tonumber(noctalia.getConfig("max_tasks")) or 8

local tasks = noctalia.state.get("tasks") or {}

-- ── taskwarrior dates ────────────────────────────────────────────────────────

local function parseTaskDate(s)
  if type(s) ~= "string" or #s < 16 then
    return nil
  end
  local y = tonumber(string.sub(s, 1, 4))
  local mo = tonumber(string.sub(s, 5, 6))
  local d = tonumber(string.sub(s, 7, 8))
  local h = tonumber(string.sub(s, 10, 11))
  local mi = tonumber(string.sub(s, 12, 13))
  local se = tonumber(string.sub(s, 14, 15))
  if y == nil or mo == nil or d == nil or h == nil or mi == nil or se == nil then
    return nil
  end
  return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = se })
end

local function dueColor(s)
  local due = parseTaskDate(s)
  if due == nil then
    return "on_surface_variant"
  end
  local now = os.time()
  if due < now then
    return "error"
  end
  if os.date("%Y%m%d", due) == os.date("%Y%m%d", now) then
    return "primary"
  end
  return "on_surface_variant"
end

local function formatDue(s)
  local due = parseTaskDate(s)
  if due == nil then
    return nil
  end
  local now = os.time()
  if due < now then
    return noctalia.tr("panel.due.overdue")
  end
  if os.date("%Y%m%d", due) == os.date("%Y%m%d", now) then
    return noctalia.tr("panel.due.today", { time = os.date("%H:%M", due) })
  end
  local dayDiff = math.floor((due - now) / 86400)
  if dayDiff <= 1 then
    return noctalia.tr("panel.due.tomorrow")
  end
  if dayDiff <= 7 then
    return noctalia.tr("panel.due.in-days", { days = tostring(dayDiff) })
  end
  return os.date("%d/%m", due)
end

local function priorityColor(priority)
  if priority == "H" then
    return "error"
  elseif priority == "M" then
    return "primary"
  elseif priority == "L" then
    return "tertiary"
  end
  return "primary/0"
end

-- ── list ─────────────────────────────────────────────────────────────────────

local function compareTasks(a, b)
  local ua = a.urgency or 0
  local ub = b.urgency or 0
  if ua ~= ub then
    return ua > ub
  end
  return (a.uuid or "") < (b.uuid or "")
end

local requestSeq = 0
local function doneCb(i)
  local name = "desk_done_" .. i
  getfenv()[name] = function()
    local t = tasks[i]
    if t == nil or t.uuid == nil then
      return
    end
    requestSeq += 1
    noctalia.state.set("request", { seq = "desktop-" .. requestSeq, kind = "done", uuid = t.uuid })
  end
  return name
end

local function openPanel()
  noctalia.togglePanel("asj/task-warrior:panel")
end

local function render()
  local sorted = {}
  for _, t in ipairs(tasks) do
    table.insert(sorted, t)
  end
  table.sort(sorted, compareTasks)
  tasks = sorted

  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "swords", color = "primary" }),
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold" }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({
        text = noctalia.trp("panel.header.count", #sorted),
        color = "on_surface_variant",
        fontSize = 11,
      }),
    }),
  }

  if #sorted == 0 then
    table.insert(children, ui.label({ text = noctalia.tr("panel.empty"), color = "on_surface_variant", fontSize = 12 }))
  else
    local shown = math.min(#sorted, MAX_TASKS)
    for i = 1, shown do
      local t = sorted[i]
      local meta = {}
      if t.due ~= nil then
        table.insert(meta, ui.label({ text = formatDue(t.due), color = dueColor(t.due), fontSize = 11 }))
      end
      if t.project ~= nil and t.project ~= "" then
        table.insert(meta, ui.label({ text = t.project, color = "primary", fontSize = 11, maxLines = 1 }))
      end
      local row = {
        key = t.uuid or tostring(i),
        gap = 8,
        align = "center",
      }
      if noctalia.togglePanel ~= nil then
        row.onClick = openPanel
      end
      table.insert(children, ui.row(row, {
        ui.box({ width = 4, height = 26, fill = priorityColor(t.priority), radius = 2 }),
        ui.button({ glyph = "check", variant = "ghost", onClick = doneCb(i) }),
        ui.column({ flexGrow = 1, gap = 1 }, {
          ui.label({ text = t.description or "", fontSize = 13, maxLines = 2, maxWidth = 260 }),
          ui.row({ gap = 8 }, meta),
        }),
      }))
    end
    if #sorted > shown then
      table.insert(children, ui.label({
        text = "+" .. tostring(#sorted - shown),
        color = "on_surface_variant",
        fontSize = 11,
      }))
    end
  end

  desktopWidget.render(ui.column({
    gap = 6,
    padding = 12,
    fill = "surface/0.55",
    radius = 12,
    align = "start",
  }, children))
end

noctalia.state.watch("tasks", function(value)
  tasks = type(value) == "table" and value or {}
  render()
end)

function update()
  render()
end

noctalia.setUpdateInterval(60000)
render()
