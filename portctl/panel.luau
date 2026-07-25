--!nonstrict
-- portctl — panel entry.

-- ── Module state ──────────────────────────────────────────────────────────

local data        = noctalia.state.get("portctl_data") or { ports = {}, error = nil }
local killingPid  = nil   -- pid currently being killed (orange bullet)
local pendingKill = nil   -- slot index staged for kill (first click — shows checkmark)
local searchQuery = ""
local showTCP     = true
local showUDP     = false

-- Kill flow (no overlay): first click stages slot (pendingKill=i, icon→check),
-- second click on same slot confirms kill.

local rowCursor = 0

local function killAt(slot, entry)
  if entry.pid == 0 then return end
  if pendingKill == slot then
    killingPid    = entry.pid
    pendingKill   = nil
    noctalia.state.set("portctl_command", { action = "kill", pid = entry.pid })
    render()
  else
    pendingKill = slot
    render()
  end
end

local function copyPid(entry)
  if entry.pid == 0 then return end
  local ok = noctalia.copyToClipboard(tostring(entry.pid), "text/plain")
  if ok then noctalia.notify(noctalia.tr("title"), noctalia.tr("panel.pid_copied", { pid = tostring(entry.pid) })) end
end

-- ── Category metadata ─────────────────────────────────────────────────────

local CAT_ORDER = { "Development", "Databases", "Containers", "Servers", "Cloud", "Other" }

local CAT_META = {
  Development = { color = "primary",            icon = "code"     },
  Databases   = { color = "tertiary",           icon = "database" },
  Containers  = { color = "secondary",          icon = "box"      },
  Servers     = { color = "error",              icon = "server"   },
  Cloud       = { color = "warning",            icon = "cloud"    },
  Other       = { color = "on_surface_variant", icon = "plug"     },
}

local COLOR_ACTIVE  = "#22c55e"
local COLOR_KILLING = "warning"

-- ── Filtering & grouping ──────────────────────────────────────────────────

local function filteredPorts()
  local ports = data.ports or {}
  if searchQuery == "" and showTCP and showUDP then return ports end
  local q   = searchQuery:lower()
  local out = {}
  for _, p in ipairs(ports) do
    if p.proto == "tcp" and not showTCP then continue end
    if p.proto == "udp" and not showUDP then continue end
    if searchQuery ~= "" then
      if not (tostring(p.port):find(q, 1, true)
           or p.name:lower():find(q, 1, true)
           or tostring(p.pid):find(q, 1, true)) then
        continue
      end
    end
    table.insert(out, p)
  end
  return out
end

local function groupByCategory(ports)
  local groups  = {}
  local seen    = {}
  for _, p in ipairs(ports) do
    local cat = p.category or "Other"
    if not groups[cat] then groups[cat] = {}; table.insert(seen, cat) end
    table.insert(groups[cat], p)
  end
  local ordered = {}
  for _, cat in ipairs(CAT_ORDER) do
    if groups[cat] then table.insert(ordered, cat) end
  end
  for _, cat in ipairs(seen) do
    local inOrder = false
    for _, oc in ipairs(CAT_ORDER) do if oc == cat then inOrder = true; break end end
    if not inOrder then table.insert(ordered, cat) end
  end
  return groups, ordered
end

-- ── Port row ──────────────────────────────────────────────────────────────

local function _doCancel(i)
  if pendingKill == i then pendingKill = nil; render() end
end

local function portRow(entry)
  rowCursor += 1
  local slot      = rowCursor
  local hasKill   = entry.pid ~= 0
  local isKilling = (killingPid == entry.pid)
  local isPending = (pendingKill == slot)

  local killFn = function() killAt(slot, entry) end
  local copyFn = function() copyPid(entry) end
  local cancelFn = function() _doCancel(slot) end
  local dotClr   = isKilling and COLOR_KILLING or COLOR_ACTIVE

  -- Killing state: replace entire row content with port + spinner
  if isKilling then
    return ui.row({
      align    = "center",
      gap      = 8,
      paddingH = 16,
      paddingV = 8,
    }, {
      ui.glyph({ name = "circle-filled", size = 8, color = COLOR_KILLING }),
      ui.label({ text = ":" .. tostring(entry.port), fontWeight = "bold", minWidth = 58, fontSize = 13 }),
      ui.label({ text = entry.proto:upper(), color = "on_surface_variant", fontSize = 10, minWidth = 34 }),
      ui.label({ text = noctalia.tr("panel.killing", { name = entry.name }), flexGrow = 1, fontSize = 13, color = "on_surface_variant" }),
      ui.button({ glyph = "loader-circle", variant = "ghost", disabled = true, opacity = 0.5, paddingH = 2, paddingV = 2 }),
    })
  end

  -- Pending state: row transforms to inline confirm
  if isPending then
    return ui.row({
      align    = "center",
      gap      = 8,
      paddingH = 16,
      paddingV = 8,
      fill     = "error/0.06",
    }, {
      ui.glyph({ name = "circle-filled", size = 8, color = COLOR_ACTIVE }),
      ui.label({ text = ":" .. tostring(entry.port), fontWeight = "bold", minWidth = 58, fontSize = 13 }),
      ui.label({ text = entry.proto:upper(), color = "on_surface_variant", fontSize = 10, minWidth = 34 }),
      ui.label({ text = noctalia.tr("panel.kill_confirm", { name = entry.name }), flexGrow = 1, fontSize = 13, color = "error" }),
      ui.button({ text = noctalia.tr("panel.cancel"), variant = "ghost",       onClick = cancelFn, paddingH = 6, paddingV = 2 }),
      ui.button({ text = noctalia.tr("panel.kill"),   variant = "destructive", onClick = killFn,   paddingH = 6, paddingV = 2 }),
    })
  end

  -- Normal state
  return ui.row({
    align    = "center",
    gap      = 8,
    paddingH = 16,
    paddingV = 8,
  }, {
    ui.glyph({ name = "circle-filled", size = 8, color = dotClr }),
    ui.label({ text = ":" .. tostring(entry.port), fontWeight = "bold", minWidth = 58, fontSize = 13 }),
    ui.label({ text = entry.proto:upper(), color = "on_surface_variant", fontSize = 10, minWidth = 34 }),
    ui.label({ text = entry.name, flexGrow = 1, fontSize = 13 }),
    ui.button({
      text     = "PID " .. (hasKill and tostring(entry.pid) or "—"),
      variant  = "ghost",
      fontSize = 11,
      color    = "on_surface_variant",
      onClick  = hasKill and copyFn or nil,
      paddingH = 4,
      paddingV = 2,
    }),
    ui.button({
      glyph    = "x",
      variant  = "ghost",
      onClick  = killFn,
      opacity  = hasKill and 1 or 0,
      paddingH = 2,
      paddingV = 2,
    }),
  })
end

-- ── Category section ──────────────────────────────────────────────────────

local function catSection(catName, ports)
  local meta = CAT_META[catName] or CAT_META.Other
  local rows = {}

  table.insert(rows, ui.row({
    align    = "center",
    gap      = 6,
    paddingH = 16,
    paddingV = 7,
    fill     = "surface_container/0.4",
  }, {
    ui.glyph({ name = meta.icon, size = 12, color = meta.color }),
    ui.label({ text = noctalia.tr("categories." .. catName:lower()), fontSize = 11, fontWeight = "bold", color = meta.color }),
    ui.label({ text = tostring(#ports), fontSize = 10, color = meta.color .. "/0.6" }),
  }))

  for _, p in ipairs(ports) do
    table.insert(rows, portRow(p))
  end

  return ui.column({ gap = 0 }, rows)
end

-- ── Main render ───────────────────────────────────────────────────────────

function render()
  data = noctalia.state.get("portctl_data") or data

  rowCursor = 0

  local ports = filteredPorts()
  noctalia.state.set("portctl_visible_count", #ports)

  local header = ui.row({
    align    = "center",
    gap      = 6,
    paddingH = 10,
    paddingV = 10,
  }, {
    ui.input({
      key         = "search",
      placeholder = noctalia.tr("panel.search_placeholder"),
      flexGrow    = 1,
      onChange    = "onSearchChange",
    }),
    ui.toggle({ checked = showTCP, onChange = "onToggleTCP" }),
    ui.label({ text = noctalia.tr("panel.tcp"), fontSize = 10, color = "on_surface_variant" }),
    ui.toggle({ checked = showUDP, onChange = "onToggleUDP" }),
    ui.label({ text = noctalia.tr("panel.udp"), fontSize = 10, color = "on_surface_variant" }),
    ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefresh" }),
    ui.button({ glyph = "x",       variant = "ghost", onClick = "onClose"   }),
  })

  local body
  if data.error then
    body = ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 12 }, {
      ui.glyph({ name = "alert-circle", size = 36, color = "error" }),
      ui.label({ text = data.error, color = "on_surface_variant", textAlign = "center", fontSize = 13 }),
    })
  elseif #ports == 0 then
    local msg = searchQuery ~= ""
      and noctalia.tr("panel.no_results", { query = searchQuery })
      or  noctalia.tr("panel.no_ports")
    body = ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 12 }, {
      ui.glyph({ name = "plug-off", size = 36, color = "on_surface_variant" }),
      ui.label({ text = msg, color = "on_surface_variant", fontSize = 13 }),
    })
  else
    local groups, order = groupByCategory(ports)
    local sections = {}
    for i, cat in ipairs(order) do
      table.insert(sections, catSection(cat, groups[cat]))
      if i < #order then
        table.insert(sections, ui.separator({ thickness = 1, color = "outline_variant" }))
      end
    end
    body = ui.scroll({ flexGrow = 1 }, {
      ui.column({ gap = 0 }, sections),
    })
  end

  panel.render(ui.column({ flexGrow = 1, gap = 0 }, {
    header,
    ui.separator({ thickness = 1, color = "outline_variant" }),
    body,
  }))
end

-- ── Global handlers ───────────────────────────────────────────────────────

function onSearchChange(value)
  searchQuery  = value or ""
  pendingKill  = nil
  render()
end

function onToggleTCP(value)
  showTCP     = value ~= "false"
  pendingKill = nil
  render()
end

function onToggleUDP(value)
  showUDP     = value ~= "false"
  pendingKill = nil
  render()
end

function onRefresh()
  pendingKill = nil
  noctalia.state.set("portctl_refresh", os.time())
end

function onClose()
  panel.close()
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────

function onOpen(_ctx)
  killingPid  = nil
  pendingKill = nil
  searchQuery = ""
  noctalia.state.set("portctl_refresh", os.time())
  render()
end

noctalia.state.watch("portctl_data", function(d)
  if not d then return end
  data        = d
  killingPid  = nil
  pendingKill = nil
  render()
end)

render()
