--!nonstrict
-- panel.luau
-- Window shown when clicking the bar widget: a form to add an IP,
-- hostname or link (with an optional description field below it), and
-- the list of monitored hosts — each with its label (if set), a status
-- pill, response time in ms (when online), a drag handle to reorder, and
-- a remove button (with confirmation).

local ips = {} -- { {ip=, label=, status=, latency_ms=}, ... }
local draftIp = ""
local draftLabel = ""
local draftKey = 0
local draftError = ""
local pendingDelete = nil
local showAddForm = false

local DRAG_TYPE = "ip-monitor-host"

local STATUS_COLORS = {
  up       = { fill = "#2e7d32", text = "#ffffff" },
  down     = { fill = "#c62828", text = "#ffffff" },
  checking = { fill = "#5f6368", text = "#ffffff" },
}

local render

-- Accepts an IP, a plain hostname, or a link (http://..., https://...)
-- and returns just the host — scheme, port, path and query are dropped.
-- Same logic as service.luau (duplicated here just to give immediate
-- feedback in the field).
local function extractHost(raw)
  local s = noctalia.string.trim(raw or "")
  s = s:gsub("^%a[%w+.-]*://", "")
  s = s:match("^([^/%?#]+)") or s
  s = s:match("^([^:]+)") or s
  return s
end

local function isValidIPv4(host)
  local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then
    return false
  end
  for _, n in ipairs({ a, b, c, d }) do
    local num = tonumber(n)
    if num == nil or num < 0 or num > 255 then
      return false
    end
  end
  return true
end

local function isValidHostname(host)
  if host == "" or #host > 253 then
    return false
  end
  local labelCount = 0
  for label in host:gmatch("[^%.]+") do
    labelCount = labelCount + 1
    if #label == 0 or #label > 63 then
      return false
    end
    if not label:match("^%w[%w%-]*%w$") and not label:match("^%w$") then
      return false
    end
  end
  return labelCount > 0
end

local function normalizeHost(raw)
  local host = extractHost(raw)
  if host == "" then
    return nil
  end
  if isValidIPv4(host) or isValidHostname(host) then
    return host
  end
  return nil
end

local STATUS_TR_KEY = {
  up       = "panel.status_online",
  down     = "panel.status_offline",
  checking = "panel.status_checking",
}

local function latencyColor(ms)
  if ms < 100 then
    return "#2e7d32" -- green
  elseif ms < 300 then
    return "#f2b705" -- yellow
  else
    return "#c62828" -- red
  end
end

local function pill(status)
  local colors = STATUS_COLORS[status] or STATUS_COLORS.checking
  local label = noctalia.tr(STATUS_TR_KEY[status] or "panel.status_checking")
  return ui.row({
    fill     = colors.fill,
    radius   = 8,
    paddingH = 8,
    paddingV = 2,
    align    = "center",
    justify  = "center",
  }, {
    ui.label({ text = label, fontSize = 11, fontWeight = "bold", color = colors.text }),
  })
end

-- Thin strip between rows (and before the first / after the last) that
-- accepts a dropped host, indicating where it will land.
local function insertionZone(index)
  return ui.dropZone({
    key          = "gap-" .. index,
    accepts      = { DRAG_TYPE },
    value        = tostring(index),
    onDrop       = "onIpDropped",
    height       = 3,
    radius       = 4,
    expandOnDrag = true,
    hitSlop      = 24,
  })
end

function onIpDropped(payload, value)
  local insertAt = tonumber(value)
  if type(payload) ~= "string" or payload == "" or insertAt == nil then
    return
  end
  noctalia.state.set("ip_monitor.cmd", { op = "reorder", ip = payload, index = insertAt })
end

local function hostRow(item)
  local id = item.ip
  local deleting = pendingDelete == id

  local actions
  if deleting then
    actions = ui.row({ gap = 4, align = "center" }, {
      ui.button({
        glyph       = "check",
        variant     = "destructive",
        controlSize = "sm",
        tooltip     = noctalia.tr("panel.tooltip_confirm_remove"),
        onClick     = function()
          noctalia.state.set("ip_monitor.cmd", { op = "remove", ip = id })
          pendingDelete = nil
          render()
        end,
      }),
      ui.button({
        glyph       = "close",
        variant     = "ghost",
        controlSize = "sm",
        tooltip     = noctalia.tr("panel.tooltip_cancel"),
        onClick     = function()
          pendingDelete = nil
          render()
        end,
      }),
    })
  else
    actions = ui.button({
      glyph       = "trash",
      variant     = "ghost",
      controlSize = "sm",
      tooltip     = noctalia.tr("panel.tooltip_remove"),
      onClick     = function()
        pendingDelete = id
        render()
      end,
    })
  end

  -- Left column: label (if set) in bold + host as a caption; without a
  -- label, the host becomes the main text.
  local infoChildren = {}
  local hasLabel = item.label ~= nil and item.label ~= ""
  if hasLabel then
    table.insert(infoChildren, ui.label({ text = item.label, fontWeight = "bold", fontSize = 13 }))
    table.insert(infoChildren, ui.label({ text = item.ip, color = "on_surface_variant", fontSize = 10 }))
  else
    table.insert(infoChildren, ui.label({ text = item.ip, fontWeight = "bold", fontSize = 13 }))
  end

  -- Right column: status pill + response time in ms (only while online
  -- and when the measurement exists).
  local statusChildren = { pill(item.status) }
  if item.status == "up" and item.latency_ms ~= nil then
    local color = "on_surface_variant"
    if noctalia.getConfig("colorize_latency") ~= false then
      color = latencyColor(item.latency_ms)
    end
    table.insert(statusChildren, ui.label({
      text     = tostring(item.latency_ms) .. " ms",
      fontSize = 10,
      color    = color,
    }))
  end

  return ui.row({
    key     = "ip-" .. id,
    gap     = 8,
    padding = 10,
    radius  = 8,
    fill    = "surface_variant/0.35",
    align   = "center",
    justify = "space_between",
  }, {
    ui.dragSource({
      key             = "grip-" .. id,
      dragType        = DRAG_TYPE,
      payload         = id,
      previewAncestor = 1,
      liftFromLayout  = true,
      width           = 20,
      height          = 20,
      align           = "center",
      justify         = "center",
      tooltip         = noctalia.tr("panel.tooltip_drag"),
    }, {
      ui.glyph({ name = "menu-2", size = 14, color = "on_surface_variant" }),
    }),
    ui.column({ flexGrow = 1, gap = 1 }, infoChildren),
    ui.column({ align = "end", gap = 2 }, statusChildren),
    actions,
  })
end

local function emptyState()
  return ui.column({ gap = 10, align = "center", padding = 32, flexGrow = 1, justify = "center" }, {
    ui.glyph({ name = "activity", size = 32, color = "outline" }),
    ui.label({ text = noctalia.tr("panel.empty"), color = "outline" }),
  })
end

render = function()
  local body

  if #ips == 0 then
    body = emptyState()
  else
    local rows = {}
    for i, item in ipairs(ips) do
      table.insert(rows, insertionZone(i))
      table.insert(rows, hostRow(item))
    end
    table.insert(rows, insertionZone(#ips + 1))
    body = ui.scroll({ gap = 6, flexGrow = 1 }, rows)
  end

  local column = {}

  table.insert(column, ui.row({ align = "center", justify = "space_between" }, {
    ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
    ui.button({
      glyph       = showAddForm and "minus" or "plus",
      variant     = showAddForm and "primary" or "ghost",
      controlSize = "sm",
      tooltip     = showAddForm and noctalia.tr("panel.tooltip_close_form") or noctalia.tr("panel.tooltip_add_host"),
      onClick     = function()
        showAddForm = not showAddForm
        if not showAddForm then
          draftIp = ""
          draftLabel = ""
          draftError = ""
          draftKey += 1
        end
        render()
      end,
    }),
    ui.button({
      glyph       = "refresh",
      variant     = "ghost",
      controlSize = "sm",
      tooltip     = noctalia.tr("panel.tooltip_check_now"),
      onClick     = function() noctalia.state.set("ip_monitor.cmd", { op = "refresh" }) end,
    }),
    ui.button({
      glyph       = "close",
      variant     = "ghost",
      controlSize = "sm",
      onClick     = function() panel.close() end,
    }),
  }))

  if showAddForm then
    table.insert(column, ui.row({
      gap     = 6,
      align   = "center",
      padding = 8,
      radius  = 8,
      fill    = "surface_variant/0.35",
    }, {
      ui.column({ flexGrow = 1, gap = 6 }, {
        ui.input({
          key         = "add-ip-" .. draftKey,
          value       = draftIp,
          placeholder = noctalia.tr("panel.add_placeholder"),
          onChange    = function(value) draftIp = value; draftError = "" end,
          onSubmit    = "onAdd",
        }),
        ui.input({
          key         = "add-label-" .. draftKey,
          value       = draftLabel,
          placeholder = noctalia.tr("panel.add_label_placeholder"),
          onChange    = function(value) draftLabel = value end,
          onSubmit    = "onAdd",
        }),
        (draftError ~= "" and ui.label({ text = draftError, color = "#e05252", fontSize = 11 }) or nil),
      }),
      ui.button({ glyph = "plus", variant = "primary", controlSize = "sm", tooltip = noctalia.tr("panel.tooltip_add"), onClick = "onAdd" }),
    }))
  end

  table.insert(column, body)

  panel.render(ui.column({ gap = 8, padding = 8, flexGrow = 1 }, column))
end

function onAdd()
  local host = normalizeHost(draftIp)
  if noctalia.string.trim(draftIp) == "" then
    return
  end
  if host == nil then
    draftError = noctalia.tr("panel.invalid_format")
    showAddForm = true
    render()
    return
  end

  local label = noctalia.string.trim(draftLabel)
  draftIp = ""
  draftLabel = ""
  draftKey += 1
  draftError = ""
  showAddForm = false
  noctalia.state.set("ip_monitor.cmd", { op = "add", ip = host, label = label })
  render()
end

function onOpen(_context)
  ips = noctalia.state.get("ip_monitor.statuses") or {}
  pendingDelete = nil
  draftIp = ""
  draftLabel = ""
  draftError = ""
  draftKey += 1
  showAddForm = false
  render()
end

noctalia.state.watch("ip_monitor.statuses", function(value)
  ips = (type(value) == "table") and value or {}

  if pendingDelete ~= nil then
    local stillThere = false
    for _, item in ipairs(ips) do
      if item.ip == pendingDelete then
        stillThere = true
        break
      end
    end
    if not stillThere then
      pendingDelete = nil
    end
  end

  render()
end)
