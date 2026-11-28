--!nonstrict
-- Storage Manager panel, in four tabs:
--   Overview      each filesystem, how full it is and what fills it
--   Usage map     walk a scanned filesystem folder by folder
--   Free up space caches, old packages, logs, trash; large and duplicate files
--   Drives        physical drives, partitions, SMART health, mount and eject
--
-- Every bit of disk work happens in helper/storagetool.py. Quick questions
-- go through common.ask (runAsync), anything that can take long or ask for a
-- password through common.job (runStream). The panel runtime stays alive
-- while the panel is closed, so a scan keeps going in the background.

local common = require("./lib/common.luau")
local size = common.size
local tr = noctalia.tr

local isOpen = false
local tab = "overview"

-- what the helper's "volumes" mode reported
local volumes = {}
local drives = {}
local volumesReady = false

-- mount -> summary of its last whole-disk scan, or false when there is none
local summaries = {}

-- the scan running now: { mount, path, files, bytes, pid, detail }
local scanning = nil

-- usage map
local mapMount = nil
local mapPath = nil
local mapView = nil
local mapLoading = false

-- cleanup
local cleanup = nil
local measuring = false
local measuredAt = 0
local busy = nil -- id of the clean / trash / mount job running now
local confirm = nil -- id of the action waiting for a second click
local largeShown = 8
local dupesShown = 4

-- drives
local health = {}
local trim = nil

-- one line of feedback under the tabs: { text, error }
local message = nil

local render

local function say(text, isError)
  message = { text = text, error = isError == true }
end

-- Every callback has a small CPU budget, and one that runs over is aborted
-- together with everything it asked the shell to do (reopening the panel,
-- say). So a callback that has just asked for the panel back never draws:
-- it marks the panel dirty, and onOpen / update() draw it. Everything else
-- (tab clicks, buttons, data arriving) draws right away, because update()
-- ticks are not guaranteed to reach an open panel.
local dirty = false
local holdDrawUntil = 0

local function rerender()
  if isOpen and noctalia.nowMs() >= holdDrawUntil then
    dirty = false
    render()
  else
    dirty = true
  end
end

noctalia.setUpdateInterval(60)

function update()
  if dirty and isOpen then
    dirty = false
    render()
  end
end

-- ------------------------------------------------------------ data loading

local function loadSummary(mount)
  common.ask({ "summary", common.scanFile(mount) }, function(data)
    if data and data.ok then
      summaries[mount] = data
    else
      summaries[mount] = false
    end
    rerender()
  end)
end

local function loadVolumes()
  common.ask({ "volumes" }, function(data)
    if data and data.volumes then
      volumes = data.volumes
      drives = data.drives or {}
      volumesReady = true
      noctalia.state.set("volumes", data)
      for _, v in ipairs(volumes) do
        if summaries[v.mount] == nil then
          loadSummary(v.mount)
        end
      end
    end
    rerender()
  end)
end

local function loadView(path)
  mapLoading = true
  mapPath = path
  common.ask({ "view", common.cacheDir(), path }, function(data)
    mapLoading = false
    if data and data.ok then
      mapView = data
    else
      mapView = nil
    end
    rerender()
  end)
end

local function measure()
  if measuring then
    return
  end
  measuring = true
  rerender()
  common.job({ "cleanup" }, nil, function(data)
    measuring = false
    measuredAt = noctalia.nowMs()
    if data and data.items then
      cleanup = data
    end
    rerender()
  end)
end

local function loadTrim()
  common.ask({ "trim-status" }, function(data)
    trim = data
    rerender()
  end)
end

local function volumeAt(mount)
  for _, v in ipairs(volumes) do
    if v.mount == mount then
      return v
    end
  end
  return nil
end

-- after anything that changes what is on disk
local function afterChange()
  loadVolumes()
  if cleanup ~= nil then
    measure()
  end
  if mapPath ~= nil then
    loadView(mapPath)
  end
end

-- ----------------------------------------------------------------- actions

local function startScan(mount, path, detail)
  if scanning ~= nil then
    return
  end
  path = path or mount
  scanning = { mount = mount, path = path, files = 0, bytes = 0, pid = nil, detail = detail }
  local args
  if detail then
    args = { "scan", path, common.detailFile(path), tostring(math.max(1, math.floor(detail))) }
  else
    args = { "scan", path, common.scanFile(mount) }
  end
  local finished = false
  local ok = common.job(args, function(line)
    if scanning == nil then
      return
    end
    local tag, a, b = string.match(line, "^(%a+) (%d+) ?(%d*)")
    if tag == "pid" then
      scanning.pid = a
    elseif tag == "p" or tag == "d" then
      scanning.files = tonumber(a) or 0
      scanning.bytes = tonumber(b) or 0
      if tag == "d" then
        finished = true
      end
      rerender()
    end
  end, function(_, code)
    local s = scanning
    scanning = nil
    if finished then
      if not detail then
        loadSummary(mount)
        if mapMount == mount and mapPath == nil then
          mapPath = mount
        end
      end
      if mapPath ~= nil then
        loadView(mapPath)
      end
    elseif s and not s.cancelled then
      say(tr("scan.stopped"), true)
    end
    rerender()
  end, 10)
  if not ok then
    scanning = nil
    say(tr("scan.stopped"), true)
  end
  rerender()
end

local function cancelScan()
  if scanning == nil then
    return
  end
  scanning.cancelled = true
  if scanning.pid then
    noctalia.runAsync({ "kill", tostring(scanning.pid) })
  end
end

-- Polkit agents (hyprpolkitagent, polkit-kde, ...) draw their password prompt
-- as an ordinary window, and no window can rise above a shell panel. So the
-- panel steps aside while a prompt may be up, and comes back with the result.
local ROOT_CLEANS = { pacman = true, orphans = true, journal = true, coredumps = true }
local steppedAside = false

local function stepAside()
  if isOpen then
    steppedAside = true
    -- onClose may arrive late (or after the job is already done), so the
    -- panel counts itself closed right away
    isOpen = false
    panel.close()
  end
end

local function comeBack()
  if steppedAside then
    steppedAside = false
    if not isOpen then
      -- the rest of this callback must not draw, or an overrun would take
      -- the reopen request down with it
      holdDrawUntil = noctalia.nowMs() + 500
      noctalia.togglePanel(common.PANEL)
    end
  end
end

local function runClean(id, label)
  if busy ~= nil then
    return
  end
  busy = id
  confirm = nil
  message = nil
  rerender()
  if ROOT_CLEANS[id] then
    stepAside()
  end
  common.job({ "clean", id }, nil, function(data)
    busy = nil
    comeBack()
    if data and data.ok then
      say(tr("clean.done", { freed = size(data.freed) }))
    elseif data and data.error == "cancelled" then
      message = nil
    else
      say(tr("clean.failed", { error = data and data.error or tr("common.no_answer") }), true)
    end
    afterChange()
    rerender()
  end)
end

local function trashPath(path)
  if busy ~= nil then
    return
  end
  busy = "trash:" .. path
  confirm = nil
  rerender()
  common.job({ "trash", path }, nil, function(data)
    busy = nil
    if data and data.ok then
      say(tr("trash.done", { name = common.basename(path) }))
      common.ask({ "forget", common.cacheDir(), path }, function()
        for _, v in ipairs(volumes) do
          loadSummary(v.mount)
        end
        afterChange()
      end)
    else
      say(tr("trash.failed", { name = common.basename(path) }), true)
    end
    rerender()
  end)
end

-- udisks asks for a password for internal drives, not for removable ones
local function udisks(args, label, mayAsk)
  if busy ~= nil then
    return
  end
  busy = "udisks:" .. label
  message = nil
  rerender()
  if mayAsk then
    stepAside()
  end
  common.job(args, nil, function(data)
    busy = nil
    comeBack()
    if not (data and data.ok) then
      say(tr("drives.udisks_failed", { error = data and data.error or tr("common.no_answer") }), true)
    end
    loadVolumes()
    rerender()
  end)
end

local function checkHealth(dev)
  if busy ~= nil then
    return
  end
  busy = "health:" .. dev
  rerender()
  stepAside()
  common.job({ "health", dev }, nil, function(data)
    busy = nil
    comeBack()
    health[dev] = data or { ok = false, error = tr("common.no_answer") }
    rerender()
  end)
end

local function setTrim(on)
  if busy ~= nil then
    return
  end
  busy = "trim"
  rerender()
  stepAside()
  common.job({ "trim-set", on and "on" or "off" }, nil, function(data)
    busy = nil
    comeBack()
    if data then
      trim = data
      if not data.ok and data.error ~= "cancelled" and data.error ~= "" then
        say(tr("clean.failed", { error = data.error }), true)
      end
    end
    rerender()
  end)
end

local function openMap(mount, path)
  tab = "map"
  mapMount = mount
  mapView = nil
  if summaries[mount] then
    loadView(path or mount)
  else
    mapPath = nil
  end
  rerender()
end

-- ------------------------------------------------------------- UI pieces

local function sectionTitle(text, sub)
  local kids = {
    ui.label({ text = string.upper(text), fontSize = 11, fontWeight = "bold", color = "primary" }),
  }
  if sub and sub ~= "" then
    table.insert(kids, ui.label({ text = sub, fontSize = 12, color = "on_surface_variant", maxLines = 3 }))
  end
  return ui.column({ gap = 3, padding = 2 }, kids)
end

local function card(props, children)
  props.fill = props.fill or "surface_container"
  props.radius = props.radius or 12
  props.padding = props.padding or 14
  props.gap = props.gap or 8
  return ui.column(props, children)
end

local function small(text, color)
  return ui.label({ text = text, fontSize = 12, color = color or "on_surface_variant", maxLines = 2 })
end

local function iconButton(glyph, tooltipText, onClick, enabled)
  return ui.button({
    glyph = glyph,
    variant = "ghost",
    controlSize = "sm",
    tooltip = tooltipText,
    enabled = enabled ~= false,
    onClick = onClick,
  })
end

-- a bar split into what fills the disk, then free space
local function stackedBar(parts, total, height)
  local boxes = {}
  local used = 0
  for _, p in ipairs(parts) do
    if p.value > 0 and total > 0 then
      used += p.value
      table.insert(boxes, ui.box({ fill = p.color, height = height, width = 1, flexGrow = math.max(1, p.value / total * 1000) }))
    end
  end
  local rest = math.max(0, total - used)
  if rest > 0 then
    table.insert(boxes, ui.box({ fill = "on_surface/0.10", height = height, width = 1, flexGrow = math.max(1, rest / total * 1000) }))
  end
  return ui.row({ height = height, radius = height / 2, clip = true, gap = 0 }, boxes)
end

local function legendChip(color, text)
  return ui.row({ gap = 5, align = "center" }, {
    ui.box({ width = 9, height = 9, radius = 5, fill = color }),
    ui.label({ text = text, fontSize = 11, color = "on_surface_variant" }),
  })
end

-- rows of chips, so a long legend wraps by hand
local function chipRows(chips, perRow)
  local rows = {}
  local cur = {}
  for _, c in ipairs(chips) do
    table.insert(cur, c)
    if #cur >= perRow then
      table.insert(rows, ui.row({ gap = 14 }, cur))
      cur = {}
    end
  end
  if #cur > 0 then
    table.insert(rows, ui.row({ gap = 14 }, cur))
  end
  return ui.column({ gap = 4 }, rows)
end

local function confirmBox(id, title, body, actionText, onYes)
  return ui.column({ gap = 8, fill = "error/0.08", radius = 10, padding = 10 }, {
    ui.label({ text = title, fontWeight = "bold", color = "on_surface" }),
    small(body),
    ui.row({ gap = 8, justify = "end" }, {
      ui.button({ text = tr("common.cancel"), variant = "ghost", controlSize = "sm", onClick = function()
        confirm = nil
        rerender()
      end }),
      ui.button({ text = actionText, variant = "destructive", controlSize = "sm", onClick = onYes }),
    }),
  })
end

local function scanLine(mount)
  if scanning and scanning.mount == mount and not scanning.detail then
    local text = scanning.files > 0
        and tr("scan.progress", { files = common.count(scanning.files), bytes = size(scanning.bytes) })
      or tr("scan.starting")
    return ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "loader-2", size = 14, color = "primary" }),
      ui.label({ text = text, fontSize = 12, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
      ui.button({ text = tr("scan.stop"), glyph = "player-stop", variant = "outline", controlSize = "sm", onClick = cancelScan }),
    })
  end
  local s = summaries[mount]
  local text
  if s then
    text = tr("scan.done", { files = common.count(s.files), ago = common.ago(s.time) })
    if (tonumber(s.errors) or 0) > 0 then
      text ..= "  ·  " .. tr("scan.unreadable", { n = common.count(s.errors) })
    end
  else
    text = tr("scan.hint")
  end
  local buttons = {
    ui.label({ text = text, fontSize = 12, color = "on_surface_variant", flexGrow = 1, maxLines = 2 }),
  }
  if s and tab ~= "map" then
    table.insert(buttons, ui.button({ text = tr("map.open"), glyph = "chart-treemap", variant = "ghost", controlSize = "sm", onClick = function()
      openMap(mount)
    end }))
  end
  table.insert(buttons, ui.button({
    text = s and tr("scan.again") or tr("scan.scan"),
    glyph = "search",
    variant = s and "outline" or "primary",
    controlSize = "sm",
    enabled = scanning == nil,
    onClick = function()
      startScan(mount)
    end,
  }))
  return ui.row({ gap = 8, align = "center" }, buttons)
end

-- --------------------------------------------------------------- overview

local function volumeCard(v)
  local total = (tonumber(v.used) or 0) + (tonumber(v.avail) or 0)
  local pct = common.freePercent(v)
  local limit = tonumber(noctalia.getConfig("low_space_percent")) or 10
  local low = pct < limit
  local s = summaries[v.mount]

  local parts = {}
  local chips = {}
  if s and s.atMount and s.cats then
    local counted = 0
    for _, c in ipairs(common.CATS) do
      local b = tonumber(s.cats[c]) or 0
      if b > 0 then
        counted += b
        table.insert(parts, { value = b, color = common.CAT_COLOR[c] })
        if b >= total / 200 then
          table.insert(chips, legendChip(common.CAT_COLOR[c], tr("cat." .. c) .. "  " .. size(b)))
        end
      end
    end
    -- what the scan could not see (other users, root-only folders)
    local hidden = (tonumber(v.used) or 0) - counted
    if hidden > total / 200 then
      table.insert(parts, { value = hidden, color = "#495057" })
      table.insert(chips, legendChip("#495057", tr("cat.restricted") .. "  " .. size(hidden)))
    end
  else
    table.insert(parts, { value = tonumber(v.used) or 0, color = low and "error" or "primary" })
  end

  local sub = v.mount .. "  ·  " .. v.fstype .. "  ·  " .. v.device
  if v.readonly then
    sub ..= "  ·  " .. tr("overview.readonly")
  end

  local head = ui.row({ gap = 10, align = "center" }, {
    ui.glyph({ name = v.removable and "usb" or (v.root and "device-desktop" or "database"), size = 20, color = low and "error" or "primary" }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = v.name, fontSize = 15, fontWeight = "bold" }),
      ui.label({ text = sub, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.column({ gap = 1, align = "end" }, {
      ui.label({ text = tr("overview.free", { free = size(v.avail) }), fontWeight = "bold", color = low and "error" or "on_surface" }),
      ui.label({ text = tr("overview.of", { size = size(total) }), fontSize = 11, color = "on_surface_variant" }),
    }),
    iconButton("folder-open", tr("common.open"), function()
      common.openFolder(v.mount)
    end),
  })

  local kids = { head, stackedBar(parts, total, 12) }
  if #chips > 0 then
    table.insert(kids, chipRows(chips, 4))
  end
  table.insert(kids, scanLine(v.mount))
  return card({ key = "vol-" .. v.mount }, kids)
end

local function overviewTab()
  local kids = {}
  if not volumesReady then
    table.insert(kids, small(tr("common.loading")))
  end
  if cleanup ~= nil then
    local total = 0
    for _, it in ipairs(cleanup.items) do
      if it.id ~= "downloads" and it.id ~= "othercaches" then
        total += tonumber(it.size) or 0
      end
    end
    if total > 64 * 1024 * 1024 then
      table.insert(kids, card({ fill = "primary/0.10" }, {
        ui.row({ gap = 10, align = "center" }, {
          ui.glyph({ name = "sparkles", size = 18, color = "primary" }),
          ui.label({ text = tr("overview.reclaim", { size = size(total) }), flexGrow = 1, maxLines = 2 }),
          ui.button({ text = tr("tabs.clean"), variant = "primary", controlSize = "sm", onClick = function()
            tab = "clean"
            rerender()
          end }),
        }),
      }))
    end
  end
  for _, v in ipairs(volumes) do
    table.insert(kids, volumeCard(v))
  end
  return kids
end

-- -------------------------------------------------------------- usage map

local function mapRow(item, parentSize)
  local isDir = item.t == 1
  local glyph = isDir and (item.u and "lock" or "folder") or (common.KIND_GLYPH[item.k] or "file")
  local color = isDir and "primary" or common.kindColor(item.k)
  local sub
  if isDir then
    if item.u then
      sub = tr("map.not_allowed")
    else
      sub = tr("map.files", { n = common.count(item.f) })
    end
  else
    sub = tr("map.changed", { ago = common.ago(item.m) })
  end
  local frac = parentSize > 0 and item.s / parentSize or 0
  local confirmId = "trash:" .. item.p

  local row = ui.row({
    key = "m-" .. item.p,
    gap = 10,
    align = "center",
    padding = 8,
    radius = 8,
    fill = "surface_container",
    onClick = (isDir and not item.u) and function()
      confirm = nil
      loadView(item.p)
      rerender()
    end or nil,
  }, {
    ui.glyph({ name = glyph, size = 18, color = color }),
    ui.column({ gap = 3, flexGrow = 1 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = item.n, fontWeight = "medium", flexGrow = 1, maxLines = 1 }),
        ui.label({ text = size(item.s), fontWeight = "bold" }),
      }),
      ui.row({ gap = 8, align = "center" }, {
        ui.progress({ progress = math.min(1, frac), fill = common.kindColor(item.k), height = 4, width = 1, flexGrow = 1 }),
        ui.label({ text = string.format("%d%%", math.floor(frac * 100 + 0.5)), fontSize = 11, color = "on_surface_variant", width = 34, textAlign = "end" }),
      }),
      ui.label({ text = sub, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    iconButton("folder-search", tr("common.reveal"), function()
      noctalia.revealPath(item.p)
    end),
    iconButton("copy", tr("common.copy_path"), function()
      noctalia.copyToClipboard(item.p, "text/plain")
      say(tr("common.copied"))
      rerender()
    end),
    iconButton("trash", tr("trash.move"), function()
      confirm = confirmId
      rerender()
    end, busy == nil),
  })
  if confirm == confirmId then
    return ui.column({ key = "mc-" .. item.p, gap = 6 }, {
      row,
      confirmBox(confirmId, tr("trash.confirm_title"), tr("trash.confirm_body", { name = item.n, size = size(item.s) }), tr("trash.move_short"), function()
        trashPath(item.p)
      end),
    })
  end
  return row
end

local function mapTab()
  local kids = {}
  if #volumes == 0 then
    table.insert(kids, small(tr("common.loading")))
    return kids
  end
  if mapMount == nil then
    for _, v in ipairs(volumes) do
      if summaries[v.mount] then
        mapMount = v.mount
        break
      end
    end
    mapMount = mapMount or volumes[1].mount
  end

  local names = {}
  local selected = 0
  for i, v in ipairs(volumes) do
    table.insert(names, v.name .. "  (" .. v.mount .. ")")
    if v.mount == mapMount then
      selected = i - 1
    end
  end
  table.insert(kids, ui.row({ gap = 8, align = "center" }, {
    ui.select({ options = names, selectedIndex = selected, controlSize = "sm", flexGrow = 1, onChange = function(index)
      local v = volumes[(tonumber(index) or 0) + 1]
      if v then
        confirm = nil
        openMap(v.mount)
      end
    end }),
  }))
  table.insert(kids, card({ padding = 10 }, { scanLine(mapMount) }))

  local s = summaries[mapMount]
  if not s then
    return kids
  end
  if mapPath == nil then
    loadView(mapMount)
  end
  if mapView == nil then
    table.insert(kids, small(mapLoading and tr("common.loading") or tr("map.missing")))
    return kids
  end
  local v = mapView

  -- breadcrumbs
  local crumbs = {}
  if #v.crumbs > 1 then
    table.insert(crumbs, iconButton("arrow-up", tr("map.up"), function()
      loadView(v.crumbs[#v.crumbs - 1].p)
      rerender()
    end))
  end
  local first = math.max(1, #v.crumbs - 4)
  for i = first, #v.crumbs do
    local c = v.crumbs[i]
    if i > first then
      table.insert(crumbs, ui.glyph({ name = "chevron-right", size = 12, color = "on_surface_variant" }))
    end
    local label = c.n
    if i == 1 and volumeAt(c.p) then
      label = volumeAt(c.p).name
    end
    table.insert(crumbs, ui.button({
      text = label,
      variant = i == #v.crumbs and "secondary" or "ghost",
      controlSize = "sm",
      onClick = function()
        loadView(c.p)
        rerender()
      end,
    }))
  end
  table.insert(kids, ui.row({ gap = 2, align = "center" }, crumbs))

  table.insert(kids, ui.row({ gap = 8, align = "center", paddingH = 4 }, {
    ui.label({ text = tr("map.total", { size = size(v.size), files = common.count(v.files) }), fontWeight = "bold", flexGrow = 1 }),
    iconButton("folder-open", tr("common.open"), function()
      common.openFolder(v.path)
    end),
  }))

  if v.unreadable then
    table.insert(kids, small(tr("map.not_allowed_long")))
  end
  if #v.kids == 0 and v.rest == 0 and not v.unreadable and (tonumber(v.files) or 0) == 0 then
    table.insert(kids, small(tr("map.empty")))
  end

  for _, item in ipairs(v.kids) do
    table.insert(kids, mapRow(item, v.size))
  end

  local canCloser = (v.closer or (#v.kids == 0 and (tonumber(v.files) or 0) > 0)) and not (v.detailed and v.root == v.path)
  if v.rest > 0 or canCloser then
    local detailBusy = scanning and scanning.detail and scanning.path == v.path
    local restKids = {
      ui.glyph({ name = "files", size = 18, color = "on_surface_variant" }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = tr("map.rest", { n = common.count(math.max(v.restCount, v.files - #v.kids)) }), maxLines = 1 }),
        ui.label({ text = detailBusy and tr("map.closer_busy") or tr("map.rest_sub"), fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.label({ text = size(v.rest > 0 and v.rest or v.size), fontWeight = "bold" }),
    }
    if canCloser then
      table.insert(restKids, ui.button({ text = tr("map.closer"), glyph = "zoom-in", variant = "outline", controlSize = "sm", enabled = scanning == nil, onClick = function()
        startScan(mapMount, v.path, v.size)
      end }))
    end
    table.insert(kids, ui.row({ key = "rest", gap = 10, align = "center", padding = 8, radius = 8, fill = "surface_container/0.5" }, restKids))
  end
  return kids
end

-- ------------------------------------------------------------- free space

local CACHE_IDS = {
  thumbnails = true, pip = true, yay = true, paru = true, npm = true, yarn = true, bun = true, gobuild = true,
  nodegyp = true, cargo = true, gradle = true, maven = true, electron = true, composer = true, shaders = true,
  shadersdb = true,
}

local function cleanItemView(it)
  local id = it.id
  local title, body, glyph, actionText, confirmTitle, confirmBody
  local action = "clean"
  local needsRoot = it.root == true

  if id == "trash" then
    if (tonumber(it.count) or 0) == 0 and (tonumber(it.size) or 0) == 0 then
      return nil
    end
    glyph = "trash"
    title = tr("clean.trash.title")
    body = tr("clean.trash.body", { n = common.count(it.count) })
    actionText = tr("clean.trash.action")
    confirmTitle = tr("clean.trash.confirm_title")
    confirmBody = tr("clean.trash.confirm_body")
  elseif string.sub(id, 1, 6) == "cache:" then
    local cid = string.sub(id, 7)
    if not CACHE_IDS[cid] then
      return nil
    end
    glyph = "box"
    title = tr("cache." .. cid .. ".title")
    body = tr("cache." .. cid .. ".body") .. " " .. tr("clean.cache.body")
    actionText = tr("clean.cache.action")
    confirmTitle = tr("clean.cache.confirm_title", { name = title })
    confirmBody = tr("cache." .. cid .. ".body") .. " " .. tr("clean.cache.confirm_body")
  elseif id == "pacman" then
    glyph = "package"
    title = tr("clean.pacman.title")
    body = tr("clean.pacman.body", { old = common.count(it.old), gone = common.count(it.gone) })
    actionText = tr("clean.pacman.action")
    confirmTitle = tr("clean.pacman.confirm_title")
    confirmBody = tr("clean.pacman.confirm_body")
  elseif id == "orphans" then
    if (tonumber(it.count) or 0) == 0 then
      return nil
    end
    local names = {}
    for i, n in ipairs(it.names or {}) do
      if i > 6 then
        table.insert(names, "…")
        break
      end
      table.insert(names, n.n)
    end
    glyph = "package-off"
    title = tr("clean.orphans.title")
    body = tr("clean.orphans.body", { n = common.count(it.count), names = table.concat(names, ", ") })
    actionText = tr("clean.orphans.action")
    confirmTitle = tr("clean.orphans.confirm_title", { n = common.count(it.count) })
    confirmBody = tr("clean.orphans.confirm_body")
  elseif id == "journal" then
    glyph = "notes"
    title = tr("clean.journal.title")
    body = tr("clean.journal.body", { total = size(it.total), keep = size(it.keep) })
    actionText = tr("clean.journal.action")
    confirmTitle = tr("clean.journal.confirm_title")
    confirmBody = tr("clean.journal.confirm_body", { keep = size(it.keep) })
  elseif id == "coredumps" then
    glyph = "bug"
    title = tr("clean.coredumps.title")
    body = tr("clean.coredumps.body", { n = common.count(it.count) })
    actionText = tr("clean.coredumps.action")
    confirmTitle = tr("clean.coredumps.confirm_title")
    confirmBody = tr("clean.coredumps.confirm_body")
  elseif id == "flatpak" then
    if (tonumber(it.count) or 0) == 0 then
      return nil
    end
    glyph = "apps"
    title = tr("clean.flatpak.title")
    body = tr("clean.flatpak.body", { n = common.count(it.count) })
    actionText = tr("clean.flatpak.action")
    confirmTitle = tr("clean.flatpak.confirm_title")
    confirmBody = tr("clean.flatpak.confirm_body")
  elseif id == "othercaches" then
    local top = {}
    for _, t in ipairs(it.top or {}) do
      table.insert(top, t.n .. " (" .. size(t.s) .. ")")
    end
    glyph = "folder"
    title = tr("clean.othercaches.title")
    body = tr("clean.othercaches.body", { list = table.concat(top, ", ") })
    action = "show"
  elseif id == "downloads" then
    if (tonumber(it.count) or 0) == 0 then
      return nil
    end
    glyph = "download"
    title = tr("clean.downloads.title")
    body = tr("clean.downloads.body", { n = common.count(it.count), days = it.days or 90 })
    action = "show"
  else
    return nil
  end
  if (tonumber(it.size) or 0) <= 0 then
    return nil
  end
  if needsRoot then
    body ..= " " .. tr("clean.asks_password")
  end

  local running = busy == id
  local button
  if action == "show" then
    button = ui.button({ text = tr("common.show"), glyph = "folder-open", variant = "outline", controlSize = "sm", onClick = function()
      common.openFolder(it.path or common.cacheDir())
    end })
  else
    button = ui.button({
      text = running and tr("common.working") or actionText,
      variant = "outline",
      controlSize = "sm",
      enabled = busy == nil and not (needsRoot and cleanup and cleanup.pkexec == false),
      onClick = function()
        confirm = id
        rerender()
      end,
    })
  end

  local kids = {
    ui.row({ gap = 12, align = "center" }, {
      ui.glyph({ name = glyph, size = 20, color = "primary" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.row({ gap = 8 }, {
          ui.label({ text = title, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
          ui.label({ text = size(it.size), fontWeight = "bold", color = "primary" }),
        }),
        ui.label({ text = body, fontSize = 12, color = "on_surface_variant", maxLines = 4 }),
      }),
      button,
    }),
  }
  if confirm == id then
    table.insert(kids, confirmBox(id, confirmTitle, confirmBody, actionText, function()
      runClean(id)
    end))
  end
  return card({ key = "c-" .. id, padding = 12 }, kids)
end

local function fileRow(f, sub)
  local confirmId = "trash:" .. f.p
  local row = ui.row({ key = "f-" .. f.p, gap = 10, align = "center", padding = 8, radius = 8, fill = "surface_container" }, {
    ui.glyph({ name = common.KIND_GLYPH[f.k] or "file", size = 18, color = common.kindColor(f.k) }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = common.basename(f.p), fontWeight = "medium", maxLines = 1 }),
      ui.label({ text = sub or (common.dirname(f.p) .. "  ·  " .. tr("map.changed", { ago = common.ago(f.m) })), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.label({ text = size(f.s), fontWeight = "bold" }),
    iconButton("folder-search", tr("common.reveal"), function()
      noctalia.revealPath(f.p)
    end),
    iconButton("trash", tr("trash.move"), function()
      confirm = confirmId
      rerender()
    end, busy == nil),
  })
  if confirm == confirmId then
    return ui.column({ key = "fc-" .. f.p, gap = 6 }, {
      row,
      confirmBox(confirmId, tr("trash.confirm_title"), tr("trash.confirm_body", { name = common.basename(f.p), size = size(f.s) }), tr("trash.move_short"), function()
        trashPath(f.p)
      end),
    })
  end
  return row
end

local function collectLarge()
  local all = {}
  local seen = {}
  for _, s in pairs(summaries) do
    if s and s.large then
      for _, f in ipairs(s.large) do
        if not seen[f.p] then
          seen[f.p] = true
          table.insert(all, f)
        end
      end
    end
  end
  table.sort(all, function(a, b)
    return a.s > b.s
  end)
  return all
end

local function collectDupes()
  local all = {}
  for _, s in pairs(summaries) do
    if s and s.dupes then
      for _, g in ipairs(s.dupes) do
        table.insert(all, g)
      end
    end
  end
  table.sort(all, function(a, b)
    return a.waste > b.waste
  end)
  return all
end

local function moreButton(shown, total, onMore, onLess)
  if total <= shown and shown <= 8 then
    return nil
  end
  local kids = {}
  if shown > 8 then
    table.insert(kids, ui.button({ text = tr("common.show_fewer"), variant = "ghost", controlSize = "sm", onClick = onLess }))
  end
  if total > shown then
    table.insert(kids, ui.button({ text = tr("common.show_more", { n = math.min(10, total - shown) }), variant = "ghost", controlSize = "sm", onClick = onMore }))
  end
  return ui.row({ gap = 8, justify = "center" }, kids)
end

local function cleanTab()
  local kids = {}
  local total = 0
  local cards = {}
  if cleanup ~= nil then
    for _, it in ipairs(cleanup.items) do
      local c = cleanItemView(it)
      if c then
        table.insert(cards, c)
        if it.id ~= "downloads" and it.id ~= "othercaches" then
          total += tonumber(it.size) or 0
        end
      end
    end
  end

  local intro
  if measuring and cleanup == nil then
    intro = tr("clean.measuring")
  elseif cleanup == nil then
    intro = tr("clean.waiting")
  elseif total > 0 then
    intro = tr("clean.intro", { size = size(total) })
  else
    intro = tr("clean.nothing")
  end
  table.insert(kids, ui.row({ gap = 8, align = "center" }, {
    ui.column({ gap = 3, flexGrow = 1 }, {
      ui.label({ text = string.upper(tr("clean.section")), fontSize = 11, fontWeight = "bold", color = "primary" }),
      ui.label({ text = intro, fontSize = 12, color = "on_surface_variant", maxLines = 3 }),
    }),
    ui.button({ text = measuring and tr("clean.measuring_short") or tr("clean.measure"), glyph = "refresh", variant = "ghost", controlSize = "sm", enabled = not measuring, onClick = measure }),
  }))
  if cleanup and cleanup.pkexec == false then
    table.insert(kids, small(tr("clean.no_pkexec"), "error"))
  end
  for _, c in ipairs(cards) do
    table.insert(kids, c)
  end

  -- large files
  local large = collectLarge()
  table.insert(kids, ui.box({ height = 6 }))
  if #large == 0 then
    table.insert(kids, sectionTitle(tr("large.section"), tr("large.need_scan")))
  else
    table.insert(kids, sectionTitle(tr("large.section"), tr("large.sub")))
    for i = 1, math.min(largeShown, #large) do
      table.insert(kids, fileRow(large[i]))
    end
    local more = moreButton(largeShown, #large, function()
      largeShown += 10
      rerender()
    end, function()
      largeShown = 8
      rerender()
    end)
    if more then
      table.insert(kids, more)
    end
  end

  -- duplicates
  local dupes = collectDupes()
  if #dupes > 0 then
    local waste = 0
    for _, g in ipairs(dupes) do
      waste += g.waste
    end
    table.insert(kids, ui.box({ height = 6 }))
    table.insert(kids, sectionTitle(tr("dupes.section"), tr("dupes.sub", { size = size(waste) })))
    for i = 1, math.min(dupesShown, #dupes) do
      local g = dupes[i]
      local rows = {
        ui.label({
          text = tr("dupes.group", { n = #g.files, name = common.basename(g.files[1].p), size = size(g.waste) }),
          fontWeight = "bold",
          maxLines = 2,
        }),
      }
      for j, f in ipairs(g.files) do
        local sub = common.dirname(f.p) .. "  ·  " .. (j == 1 and tr("dupes.oldest") or "") .. tr("map.changed", { ago = common.ago(f.m) })
        table.insert(rows, fileRow(f, sub))
      end
      table.insert(kids, card({ key = "dg-" .. g.files[1].p, padding = 10, gap = 6, fill = "surface_container/0.5" }, rows))
    end
    local more = moreButton(dupesShown, #dupes, function()
      dupesShown += 5
      rerender()
    end, function()
      dupesShown = 4
      rerender()
    end)
    if more then
      table.insert(kids, more)
    end
  end
  return kids
end

-- ----------------------------------------------------------------- drives

local SYSTEM_MOUNTS = { ["/"] = true, ["/boot"] = true, ["/efi"] = true, ["/boot/efi"] = true, ["/home"] = true, ["/var"] = true, ["/usr"] = true }

local function healthView(dev)
  local h = health[dev]
  local checking = busy == "health:" .. dev
  local kids = {}
  local line, color
  if checking then
    line, color = tr("health.asking"), "on_surface_variant"
  elseif h == nil then
    line, color = tr("health.unchecked"), "on_surface_variant"
  elseif not h.ok then
    line, color = h.error == "cancelled" and tr("health.unchecked") or tr("health.error", { error = h.error or "" }), "on_surface_variant"
  elseif h.passed == false then
    line, color = tr("health.failing"), "error"
  else
    local bits = {}
    if h.passed == true then
      table.insert(bits, tr("health.healthy"))
    elseif h.note then
      table.insert(bits, h.note)
    end
    if h.wear ~= nil then
      table.insert(bits, tr("health.worn", { n = h.wear }))
    end
    if h.written ~= nil and h.written > 0 then
      table.insert(bits, tr("health.written", { size = size(h.written) }))
    end
    if h.hours ~= nil then
      table.insert(bits, tr("health.hours", { n = common.count(h.hours) }))
    end
    if h.mediaErrors ~= nil and h.mediaErrors > 0 then
      table.insert(bits, tr("health.media_errors", { n = common.count(h.mediaErrors) }))
    end
    if h.spare ~= nil then
      table.insert(bits, tr("health.spare", { n = h.spare }))
    end
    line = table.concat(bits, "  ·  ")
    color = ((h.mediaErrors or 0) > 0 or (h.wear or 0) >= 80) and "error" or "primary"
  end
  table.insert(kids, ui.glyph({ name = (h and h.ok and h.passed == false) and "alert-triangle" or "heart-rate-monitor", size = 16, color = color }))
  table.insert(kids, ui.label({ text = line, fontSize = 12, color = color, flexGrow = 1, maxLines = 2 }))
  table.insert(kids, ui.button({
    text = h and tr("health.again") or tr("health.check"),
    variant = "ghost",
    controlSize = "sm",
    enabled = busy == nil,
    onClick = function()
      checkHealth(dev)
    end,
  }))
  return ui.row({ gap = 8, align = "center", padding = 8, radius = 8, fill = "surface_container_high" }, kids)
end

local function partRow(d, p)
  local mounted = #(p.mounts or {}) > 0
  local title = p.label ~= "" and p.label or (p.partlabel ~= "" and p.partlabel or p.name)
  local sub = p.name .. "  ·  " .. (p.fstype ~= "" and p.fstype or tr("drives.no_fs")) .. "  ·  " .. size(p.size)
  if mounted then
    sub ..= "  ·  " .. table.concat(p.mounts, ", ")
  end
  local info = {
    ui.label({ text = title, fontWeight = "medium", maxLines = 1 }),
    ui.label({ text = sub, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
  }
  if (tonumber(p.fssize) or -1) > 0 then
    table.insert(info, ui.progress({ progress = math.min(1, p.used / p.fssize), height = 4, width = 1, flexGrow = 1 }))
  end
  local kids = { ui.column({ gap = 3, flexGrow = 1 }, info) }
  local systemish = false
  for _, m in ipairs(p.mounts or {}) do
    if SYSTEM_MOUNTS[m] or m == "[SWAP]" then
      systemish = true
    end
  end
  if mounted and not systemish then
    table.insert(kids, iconButton("folder-open", tr("common.open"), function()
      common.openFolder(p.mounts[1])
    end))
    table.insert(kids, ui.button({ text = tr("drives.unmount"), variant = "ghost", controlSize = "sm", enabled = busy == nil, onClick = function()
      udisks({ "udisks", "unmount", p.path }, p.path, not d.removable)
    end }))
  elseif not mounted and p.fstype ~= "" and p.fstype ~= "swap" and p.fstype ~= "crypto_LUKS" and p.fstype ~= "LVM2_member" then
    table.insert(kids, ui.button({ text = tr("drives.mount"), variant = "outline", controlSize = "sm", enabled = busy == nil, onClick = function()
      udisks({ "udisks", "mount", p.path }, p.path, not d.removable)
    end }))
  end
  return ui.row({ key = "p-" .. p.path, gap = 8, align = "center", padding = 8, radius = 8, fill = "surface_container_high" }, kids)
end

local function driveCard(d)
  local kind
  if d.removable then
    kind = tr("drives.removable")
  elseif d.tran == "nvme" then
    kind = tr("drives.nvme")
  elseif d.rota then
    kind = tr("drives.hdd")
  else
    kind = tr("drives.ssd")
  end
  local sub = kind .. "  ·  " .. size(d.size)
  if d.tran ~= "" and d.tran ~= "nvme" then
    sub ..= "  ·  " .. string.upper(d.tran)
  end
  if (tonumber(d.temp) or -1) >= 0 then
    sub ..= "  ·  " .. string.format("%d°C", math.floor(d.temp + 0.5))
  end
  local title = d.model ~= "" and d.model or (d.vendor ~= "" and d.vendor or d.name)

  local head = {
    ui.glyph({ name = d.removable and "usb" or (d.rota and "disc" or "cpu"), size = 22, color = "primary" }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = title, fontSize = 15, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = d.path .. "  ·  " .. sub, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
  }
  if d.removable then
    table.insert(head, ui.button({ text = tr("drives.eject"), glyph = "player-eject", variant = "outline", controlSize = "sm", enabled = busy == nil, onClick = function()
      confirm = "eject:" .. d.path
      rerender()
    end }))
  end

  local kids = { ui.row({ gap = 10, align = "center" }, head) }
  if confirm == "eject:" .. d.path then
    local mountedParts = {}
    for _, p in ipairs(d.parts or {}) do
      if #(p.mounts or {}) > 0 then
        table.insert(mountedParts, p.path)
      end
    end
    table.insert(kids, confirmBox(confirm, tr("drives.eject_title", { name = title }), tr("drives.eject_body"), tr("drives.eject"), function()
      confirm = nil
      local args = { "eject", d.path }
      for _, p in ipairs(mountedParts) do
        table.insert(args, p)
      end
      udisks(args, d.path)
    end))
  end
  table.insert(kids, healthView(d.path))
  for _, p in ipairs(d.parts or {}) do
    table.insert(kids, partRow(d, p))
  end
  return card({ key = "d-" .. d.path }, kids)
end

local function drivesTab()
  local kids = {}
  if not volumesReady then
    table.insert(kids, small(tr("common.loading")))
  end
  for _, d in ipairs(drives) do
    table.insert(kids, driveCard(d))
  end
  if trim and trim.known then
    table.insert(kids, card({}, {
      ui.row({ gap = 12, align = "center" }, {
        ui.column({ gap = 2, flexGrow = 1 }, {
          ui.label({ text = tr("drives.trim_title"), fontWeight = "bold" }),
          small(tr("drives.trim_body")),
        }),
        ui.toggle({ checked = trim.enabled == true, enabled = busy == nil, onChange = function(value)
          setTrim(value == "true")
        end }),
      }),
    }))
  end
  table.insert(kids, card({}, {
    ui.row({ gap = 12, align = "center" }, {
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = tr("drives.settings_title"), fontWeight = "bold" }),
        small(tr("drives.settings_body")),
      }),
      ui.button({ text = tr("drives.settings_open"), glyph = "settings", variant = "outline", controlSize = "sm", onClick = function()
        noctalia.openSettings()
      end }),
    }),
  }))
  return kids
end

-- ------------------------------------------------------------------ frame

local TABS = {
  { id = "overview", glyph = "chart-pie" },
  { id = "map", glyph = "chart-treemap" },
  { id = "clean", glyph = "sparkles" },
  { id = "drives", glyph = "server-2" },
}

render = function()
  local tabButtons = {}
  for _, t in ipairs(TABS) do
    table.insert(tabButtons, ui.button({
      key = "tab-" .. t.id,
      text = tr("tabs." .. t.id),
      glyph = t.glyph,
      variant = tab == t.id and "primary" or "ghost",
      controlSize = "sm",
      flexGrow = 1,
      onClick = function()
        tab = t.id
        confirm = nil
        if t.id == "clean" and not measuring and (cleanup == nil or noctalia.nowMs() - measuredAt > 10 * 60 * 1000) then
          measure()
        end
        if t.id == "drives" then
          loadTrim()
        end
        rerender()
      end,
    }))
  end

  local body
  if tab == "map" then
    body = mapTab()
  elseif tab == "clean" then
    body = cleanTab()
  elseif tab == "drives" then
    body = drivesTab()
  else
    body = overviewTab()
  end

  local top = {
    ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = "database", size = 22, color = "primary" }),
      ui.label({ text = tr("panel.title"), fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
      iconButton("refresh", tr("common.refresh"), function()
        message = nil
        afterChange()
        loadTrim()
      end),
      iconButton("x", tr("common.close"), function()
        panel.close()
      end),
    }),
    ui.row({ gap = 4, padding = 4, radius = 12, fill = "surface_container" }, tabButtons),
  }
  if message then
    table.insert(top, ui.row({ gap = 8, align = "center", paddingH = 10, paddingV = 6, radius = 8, fill = message.error and "error/0.12" or "primary/0.12" }, {
      ui.glyph({ name = message.error and "alert-circle" or "circle-check", size = 14, color = message.error and "error" or "primary" }),
      ui.label({ text = message.text, fontSize = 12, flexGrow = 1, maxLines = 2 }),
      iconButton("x", tr("common.dismiss"), function()
        message = nil
        rerender()
      end),
    }))
  end
  table.insert(top, ui.scroll({ key = "body-" .. tab, flexGrow = 1, gap = 10 }, body))

  panel.render(ui.column({ gap = 12, flexGrow = 1 }, top))
end

function onOpen(context)
  isOpen = true
  if context == "clean" or context == "map" or context == "drives" or context == "overview" then
    tab = context
  end
  render()
  loadVolumes()
  if tab == "drives" then
    loadTrim()
  end
  if not measuring and (cleanup == nil or noctalia.nowMs() - measuredAt > 10 * 60 * 1000) then
    measure()
  end
end

function onClose()
  isOpen = false
  confirm = nil
end

function onIpc(event, payload)
  if event == "scan" then
    local mount = (payload ~= nil and payload ~= "") and payload or "/"
    startScan(mount)
  elseif event == "measure" then
    measure()
  end
end
