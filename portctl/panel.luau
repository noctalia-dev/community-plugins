--!nonstrict
-- portctl — panel entry.

-- ── Module state ──────────────────────────────────────────────────────────

local data        = noctalia.state.get("portctl_data") or { ports = {}, error = nil }
local killingPid  = nil   -- pid currently being killed (orange bullet)
local pendingKill = nil   -- slot index staged for kill (first click — shows checkmark)
local searchQuery = ""
local showTCP     = true
local showUDP     = false

-- ── Pre-declared row slot handlers ───────────────────────────────────────
-- Explicit top-level declarations so Noctalia captures them at load time.
-- Dynamic _ENV[name] = fn is skipped — Noctalia likely whitelists globals
-- via static analysis at script load, silently dropping dynamic assignments.
--
-- Kill flow (no overlay): first click stages slot (pendingKill=i, icon→check),
-- second click on same slot confirms kill.

local MAX_ROWS  = 50
local rowSlots  = {}
local rowCursor = 0

local function _doKill(i)
  local t = rowSlots[i]
  if not t or t.pid == 0 then return end
  if pendingKill == i then
    killingPid    = t.pid
    pendingKill   = nil
    noctalia.state.set("portctl_command", { action = "kill", pid = t.pid })
    render()
  else
    pendingKill = i
    render()
  end
end

local function _doCopy(i)
  local t = rowSlots[i]
  if not t or t.pid == 0 then return end
  local ok = noctalia.copyToClipboard(tostring(t.pid), "text/plain")
  if ok then noctalia.notify(noctalia.tr("title"), noctalia.tr("panel.pid_copied", { pid = tostring(t.pid) })) end
end

function _pkill1()  _doKill(1)  end  function _pcopy1()  _doCopy(1)  end
function _pkill2()  _doKill(2)  end  function _pcopy2()  _doCopy(2)  end
function _pkill3()  _doKill(3)  end  function _pcopy3()  _doCopy(3)  end
function _pkill4()  _doKill(4)  end  function _pcopy4()  _doCopy(4)  end
function _pkill5()  _doKill(5)  end  function _pcopy5()  _doCopy(5)  end
function _pkill6()  _doKill(6)  end  function _pcopy6()  _doCopy(6)  end
function _pkill7()  _doKill(7)  end  function _pcopy7()  _doCopy(7)  end
function _pkill8()  _doKill(8)  end  function _pcopy8()  _doCopy(8)  end
function _pkill9()  _doKill(9)  end  function _pcopy9()  _doCopy(9)  end
function _pkill10() _doKill(10) end  function _pcopy10() _doCopy(10) end
function _pkill11() _doKill(11) end  function _pcopy11() _doCopy(11) end
function _pkill12() _doKill(12) end  function _pcopy12() _doCopy(12) end
function _pkill13() _doKill(13) end  function _pcopy13() _doCopy(13) end
function _pkill14() _doKill(14) end  function _pcopy14() _doCopy(14) end
function _pkill15() _doKill(15) end  function _pcopy15() _doCopy(15) end
function _pkill16() _doKill(16) end  function _pcopy16() _doCopy(16) end
function _pkill17() _doKill(17) end  function _pcopy17() _doCopy(17) end
function _pkill18() _doKill(18) end  function _pcopy18() _doCopy(18) end
function _pkill19() _doKill(19) end  function _pcopy19() _doCopy(19) end
function _pkill20() _doKill(20) end  function _pcopy20() _doCopy(20) end
function _pkill21() _doKill(21) end  function _pcopy21() _doCopy(21) end
function _pkill22() _doKill(22) end  function _pcopy22() _doCopy(22) end
function _pkill23() _doKill(23) end  function _pcopy23() _doCopy(23) end
function _pkill24() _doKill(24) end  function _pcopy24() _doCopy(24) end
function _pkill25() _doKill(25) end  function _pcopy25() _doCopy(25) end
function _pkill26() _doKill(26) end  function _pcopy26() _doCopy(26) end
function _pkill27() _doKill(27) end  function _pcopy27() _doCopy(27) end
function _pkill28() _doKill(28) end  function _pcopy28() _doCopy(28) end
function _pkill29() _doKill(29) end  function _pcopy29() _doCopy(29) end
function _pkill30() _doKill(30) end  function _pcopy30() _doCopy(30) end
function _pkill31() _doKill(31) end  function _pcopy31() _doCopy(31) end
function _pkill32() _doKill(32) end  function _pcopy32() _doCopy(32) end
function _pkill33() _doKill(33) end  function _pcopy33() _doCopy(33) end
function _pkill34() _doKill(34) end  function _pcopy34() _doCopy(34) end
function _pkill35() _doKill(35) end  function _pcopy35() _doCopy(35) end
function _pkill36() _doKill(36) end  function _pcopy36() _doCopy(36) end
function _pkill37() _doKill(37) end  function _pcopy37() _doCopy(37) end
function _pkill38() _doKill(38) end  function _pcopy38() _doCopy(38) end
function _pkill39() _doKill(39) end  function _pcopy39() _doCopy(39) end
function _pkill40() _doKill(40) end  function _pcopy40() _doCopy(40) end
function _pkill41() _doKill(41) end  function _pcopy41() _doCopy(41) end
function _pkill42() _doKill(42) end  function _pcopy42() _doCopy(42) end
function _pkill43() _doKill(43) end  function _pcopy43() _doCopy(43) end
function _pkill44() _doKill(44) end  function _pcopy44() _doCopy(44) end
function _pkill45() _doKill(45) end  function _pcopy45() _doCopy(45) end
function _pkill46() _doKill(46) end  function _pcopy46() _doCopy(46) end
function _pkill47() _doKill(47) end  function _pcopy47() _doCopy(47) end
function _pkill48() _doKill(48) end  function _pcopy48() _doCopy(48) end
function _pkill49() _doKill(49) end  function _pcopy49() _doCopy(49) end
function _pkill50() _doKill(50) end  function _pcopy50() _doCopy(50) end

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

-- cancelFn names: _pcancel1.._pcancel50
local function _doCancel(i)
  if pendingKill == i then pendingKill = nil; render() end
end

function _pcancel1()  _doCancel(1)  end  function _pcancel2()  _doCancel(2)  end
function _pcancel3()  _doCancel(3)  end  function _pcancel4()  _doCancel(4)  end
function _pcancel5()  _doCancel(5)  end  function _pcancel6()  _doCancel(6)  end
function _pcancel7()  _doCancel(7)  end  function _pcancel8()  _doCancel(8)  end
function _pcancel9()  _doCancel(9)  end  function _pcancel10() _doCancel(10) end
function _pcancel11() _doCancel(11) end  function _pcancel12() _doCancel(12) end
function _pcancel13() _doCancel(13) end  function _pcancel14() _doCancel(14) end
function _pcancel15() _doCancel(15) end  function _pcancel16() _doCancel(16) end
function _pcancel17() _doCancel(17) end  function _pcancel18() _doCancel(18) end
function _pcancel19() _doCancel(19) end  function _pcancel20() _doCancel(20) end
function _pcancel21() _doCancel(21) end  function _pcancel22() _doCancel(22) end
function _pcancel23() _doCancel(23) end  function _pcancel24() _doCancel(24) end
function _pcancel25() _doCancel(25) end  function _pcancel26() _doCancel(26) end
function _pcancel27() _doCancel(27) end  function _pcancel28() _doCancel(28) end
function _pcancel29() _doCancel(29) end  function _pcancel30() _doCancel(30) end
function _pcancel31() _doCancel(31) end  function _pcancel32() _doCancel(32) end
function _pcancel33() _doCancel(33) end  function _pcancel34() _doCancel(34) end
function _pcancel35() _doCancel(35) end  function _pcancel36() _doCancel(36) end
function _pcancel37() _doCancel(37) end  function _pcancel38() _doCancel(38) end
function _pcancel39() _doCancel(39) end  function _pcancel40() _doCancel(40) end
function _pcancel41() _doCancel(41) end  function _pcancel42() _doCancel(42) end
function _pcancel43() _doCancel(43) end  function _pcancel44() _doCancel(44) end
function _pcancel45() _doCancel(45) end  function _pcancel46() _doCancel(46) end
function _pcancel47() _doCancel(47) end  function _pcancel48() _doCancel(48) end
function _pcancel49() _doCancel(49) end  function _pcancel50() _doCancel(50) end

local function portRow(entry)
  rowCursor += 1
  local slot      = rowCursor
  local hasKill   = entry.pid ~= 0
  local isKilling = (killingPid == entry.pid)
  local isPending = (pendingKill == slot)
  rowSlots[slot]  = { pid = entry.pid, port = entry.port, name = entry.name }

  local killFn   = "_pkill"   .. slot
  local copyFn   = "_pcopy"   .. slot
  local cancelFn = "_pcancel" .. slot
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
    ui.label({ text = noctalia.tr("categories." .. catName), fontSize = 11, fontWeight = "bold", color = meta.color }),
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
  for i = 1, MAX_ROWS do rowSlots[i] = nil end

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
