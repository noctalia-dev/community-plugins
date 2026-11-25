--!nonstrict
-- Ping Monitor, grid view. Devices sit in groups; both groups and devices are reordered by dragging.
--   * drop a device on a group header (or into an empty group) to move it there; drop it on a card to put it in front of it
--   * drop a group on another group's header to put it in front of that one
-- Groups are created and renamed in the panel itself; the plugin settings only hold global preferences.
local shared = require("./shared.luau")
local store = require("./store.luau")

local M = {}
local TALL = false
function M.setTall(v) TALL = v == true end

local adding = nil                 -- nil | "pick" | "device" | "group"
local newName, newIp, newGroupName = "", "", ""
local pickedGroup = ""             -- group chosen in the device form
local editing = nil                -- index of the device being edited
local editName, editIp, editGroup = "", "", ""
local renaming = nil               -- group being renamed
local renameValue = ""
local armed = nil                  -- "d:<index>" or "g:<name>": a remove button pressed once
local err = ""

local draw

local function fmt(epoch)
  if not epoch or epoch == 0 then return "—" end
  return noctalia.formatTime("%d.%m %H:%M:%S", epoch)
end

local function changed(cfg)
  -- only tell the service to reload what was actually stored; otherwise it would reload the old list
  if not store.saveConfig(cfg) then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr(store.readonly and "save_blocked" or "save_failed"))
    return false
  end
  noctalia.state.set("cfg_rev", noctalia.nowMs())
  return true
end

local function latencyColor(ms)
  if ms == nil or noctalia.getConfig("colorize_latency") == false then return "on_surface_variant" end
  if ms < 100 then return "primary" end
  if ms < 300 then return "tertiary" end
  return "error"
end

local function latencyLabel(d)
  if d.status ~= "up" or d.latency == nil then return nil end
  return ui.label({ text = string.format("%d ms", math.floor(d.latency + 0.5)), color = latencyColor(d.latency), fontSize = 12, fontWeight = "semibold" })
end

local function groupKnown(s, name)
  for _, g in s.groups do
    if g.name == name then return true end
  end
  return false
end

local function groupOf(s, d)
  if d.group and d.group ~= "" and groupKnown(s, d.group) then return d.group end
  return ""
end

-- chips for choosing a group in a form; `current` is the chosen name, `pick` is called with the new one
local function groupChips(s, prefix, current, pick)
  local chips = {
    ui.button({ key = prefix .. "-none", text = noctalia.tr("panel.no_group"), controlSize = "sm",
      variant = current == "" and "primary" or "outline", onClick = function() pick(""); draw() end }),
  }
  for i, g in s.groups do
    table.insert(chips, ui.button({ key = prefix .. "-g" .. i, text = g.name, controlSize = "sm",
      variant = current == g.name and "primary" or "outline", onClick = function() pick(g.name); draw() end }))
  end
  -- chips flow in rows of three
  local rows = {}
  for i = 1, #chips, 3 do
    local row = {}
    for j = i, math.min(i + 2, #chips) do table.insert(row, chips[j]) end
    table.insert(rows, ui.row({ gap = 6 }, row))
  end
  return ui.column({ gap = 6 }, rows)
end

-- ---------------------------------------------------------------------------- device card

local function deviceCard(s, d, index)
  local color = shared.color(d.status)
  local intervalOptions = {}
  for _, v in store.INTERVALS do
    table.insert(intervalOptions, v .. " " .. noctalia.tr("panel.sec"))
  end

  if editing == index then
    return ui.column({ key = "dev-" .. d.ip .. "-edit", gap = 8, padding = 12, flexGrow = 1, fill = "surface_container", radius = 12 }, {
      ui.input({ key = "edit-name-" .. index, placeholder = noctalia.tr("panel.name"), value = editName, controlSize = "sm", onChange = function(v) editName = v end }),
      ui.input({ key = "edit-ip-" .. index, placeholder = noctalia.tr("panel.address"), value = editIp, controlSize = "sm", onChange = function(v) editIp = v end }),
      groupChips(s, "edit", editGroup, function(g) editGroup = g end),
      ui.row({ gap = 8 }, {
        ui.button({
          text = noctalia.tr("panel.save"), glyph = "check", variant = "primary", controlSize = "sm",
          onClick = function()
            local host = store.normalizeHost(editIp)
            if not host then err = noctalia.tr("panel.bad_host"); draw(); return end
            local cfg = store.loadConfig()
            local dev = cfg.devices[index]
            if dev then dev.ip = host; dev.name = editName or ""; dev.group = editGroup or "" end
            editing = nil; err = ""
            changed(cfg)
            draw()
          end,
        }),
        ui.button({ text = noctalia.tr("panel.cancel"), variant = "ghost", controlSize = "sm",
          onClick = function() editing = nil; err = ""; draw() end }),
      }),
    })
  end

  local bars = {}
  local now = math.floor(noctalia.nowMs() / 1000)
  for i = s.days - 1, 0, -1 do
    local t = now - i * 86400
    local online = d.history[noctalia.formatTime("%Y-%m-%d", t)] == true
    table.insert(bars, ui.column({ gap = 2, align = "center", width = 14 }, {
      ui.box({ fill = online and "primary" or "outline_variant", radius = 2, width = 11, height = online and 18 or 5 }),
      ui.label({ text = noctalia.formatTime("%-d", t), color = "on_surface_variant", fontSize = 7 }),
    }))
  end

  local key = "d:" .. index
  local removeArmed = armed == key
  local named = d.name and d.name ~= ""
  local status = noctalia.tr(d.status == "up" and "status.up" or (d.status == "down" and "status.down" or "status.checking"))

  return ui.column({ key = "dev-" .. d.ip, gap = 8, padding = 12, flexGrow = 1, fill = "surface_container", radius = 12 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.dragSource({
        key = "grip-" .. d.ip, dragType = "device", payload = "d:" .. index, previewAncestor = 2, liftFromLayout = true,
        width = 14, height = 26,
      }, { ui.glyph({ name = "grip-vertical", size = 14, color = "on_surface_variant" }) }),
      ui.box({ fill = color, radius = 5, width = 10, height = 10 }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = named and d.name or d.ip, fontWeight = "semibold", fontSize = 14 }),
        ui.label({ text = named and d.ip or "", color = "on_surface_variant", fontSize = 11, visible = named }),
      }),
      ui.column({ gap = 1, align = "end" }, {
        ui.label({ text = status, color = color, fontSize = 12, fontWeight = "semibold" }),
        latencyLabel(d) or ui.label({ text = "", fontSize = 12 }),
      }),
    }),
    ui.row({ gap = 2, justify = "start" }, bars),
    ui.label({ text = noctalia.tr("panel.last_ping") .. " " .. fmt(d.lastPing), color = "on_surface_variant", fontSize = 11 }),
    ui.separator({}),
    ui.row({ gap = 4, align = "center" }, {
      ui.select({
        options = intervalOptions, selectedIndex = store.intervalIndex(d.interval) - 1, controlSize = "sm", width = 116,
        onChange = function(i)
          local cfg = store.loadConfig()
          local dev = cfg.devices[index]
          if dev then dev.interval = store.INTERVALS[(tonumber(i) or 2) + 1] or 15 end
          changed(cfg)
        end,
      }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({
        glyph = d.sound == false and "bell-off" or "bell", variant = "ghost", controlSize = "sm",
        onClick = function()
          local cfg = store.loadConfig()
          local dev = cfg.devices[index]
          if dev then dev.sound = (dev.sound == false) end
          changed(cfg)
          draw()
        end,
      }),
      ui.button({
        glyph = "pencil", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.edit"),
        onClick = function()
          editing = index; armed = nil; err = ""
          editName = d.name or ""; editIp = d.ip or ""; editGroup = groupOf(s, d)
          draw()
        end,
      }),
      ui.button({
        glyph = "trash", variant = removeArmed and "destructive" or "ghost", controlSize = "sm",
        text = removeArmed and noctalia.tr("panel.confirm_remove") or nil,
        tooltip = noctalia.tr("panel.remove"),
        onClick = function()
          if removeArmed then
            local cfg = store.loadConfig()
            table.remove(cfg.devices, index)
            armed = nil
            changed(cfg)
          else
            armed = key
          end
          draw()
        end,
      }),
    }),
  })
end

-- ---------------------------------------------------------------------------- drops

-- a device dropped on a card goes in front of it and into its group
local function dropDeviceBefore(payload, ip)
  if string.sub(payload or "", 1, 2) ~= "d:" then return end
  local from = tonumber(string.sub(payload, 3))
  local cfg = store.loadConfig()
  local dev = from and cfg.devices[from]
  if not dev then return end
  local to, group = nil, ""
  for i, x in cfg.devices do
    if x.ip == ip then to = i; group = x.group or "" end
  end
  if not to or to == from then return end
  table.remove(cfg.devices, from)
  if to > from then to = to - 1 end
  dev.group = group
  table.insert(cfg.devices, to, dev)
  changed(cfg)
  draw()
end

-- value is "group:<name>" ("group:" = the ungrouped section)
local function dropOnGroup(payload, value)
  local kind, index = string.sub(payload or "", 1, 1), tonumber(string.sub(payload or "", 3))
  if not index then return end
  local name = string.sub(value, 7)
  local cfg = store.loadConfig()
  if kind == "d" then
    store.moveDeviceToGroup(cfg, index, name)
  elseif kind == "g" then
    store.moveGroup(cfg, index, name)
  else
    return
  end
  changed(cfg)
  draw()
end

-- ---------------------------------------------------------------------------- sections

local function groupHeader(s, g, index, count)
  local name = g.name
  if renaming == name then
    return ui.row({ key = "ghead-" .. name, gap = 8, align = "center" }, {
      ui.input({ key = "rename-" .. name, value = renameValue, controlSize = "sm", flexGrow = 1,
        onChange = function(v) renameValue = v end,
        onSubmit = function() end }),
      ui.button({ glyph = "check", variant = "primary", controlSize = "sm", onClick = function()
        local cfg = store.loadConfig()
        if not store.renameGroup(cfg, name, renameValue) then err = noctalia.tr("panel.bad_group") else err = ""; changed(cfg) end
        renaming = nil
        draw()
      end }),
      ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = function() renaming = nil; err = ""; draw() end }),
    })
  end
  local key = "g:" .. name
  local removeArmed = armed == key
  local folded = g.collapsed == true
  return ui.dropZone({
    key = "gdrop-" .. name, accepts = { "device", "group" }, value = "group:" .. name, direction = "column",
    onDrop = function(payload, value) dropOnGroup(payload, value) end,
  }, {
    ui.row({ key = "ghead-" .. name, gap = 8, align = "center", padding = 4 }, {
      ui.dragSource({
        key = "ggrip-" .. name, dragType = "group", payload = "g:" .. index, previewAncestor = 1, liftFromLayout = true,
        width = 14, height = 24,
      }, { ui.glyph({ name = "grip-vertical", size = 14, color = "on_surface_variant" }) }),
      ui.button({
        key = "gfold-" .. name, glyph = folded and "chevron-right" or "chevron-down", text = name, variant = "ghost", controlSize = "sm",
        contentAlign = "start", flexGrow = 1,
        onClick = function()
          local cfg = store.loadConfig()
          store.setCollapsed(cfg, name, not folded)
          changed(cfg)
          draw()
        end,
      }),
      ui.label({ text = tostring(count), color = "on_surface_variant", fontSize = 12 }),
      ui.button({ glyph = "pencil", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.rename"),
        onClick = function() renaming = name; renameValue = name; err = ""; draw() end }),
      ui.button({
        glyph = "trash", variant = removeArmed and "destructive" or "ghost", controlSize = "sm",
        text = removeArmed and noctalia.tr("panel.confirm_remove") or nil, tooltip = noctalia.tr("panel.remove_group"),
        onClick = function()
          if removeArmed then
            local cfg = store.loadConfig()
            store.removeGroup(cfg, name)
            armed = nil
            changed(cfg)
          else
            armed = key
          end
          draw()
        end,
      }),
    }),
  })
end

local function ungroupedHeader(count)
  return ui.dropZone({
    key = "gdrop-none", accepts = { "device", "group" }, value = "group:", direction = "column",
    onDrop = function(payload, value) dropOnGroup(payload, value) end,
  }, {
    ui.row({ key = "ghead-none", gap = 8, align = "center", padding = 4 }, {
      ui.label({ text = noctalia.tr("panel.no_group"), fontWeight = "semibold", fontSize = 13, flexGrow = 1 }),
      ui.label({ text = tostring(count), color = "on_surface_variant", fontSize = 12 }),
    }),
  })
end

local function cardsRows(s, list, prefix)
  local cols = tonumber(noctalia.getConfig("columns")) or 2
  local rows, row = {}, {}
  for _, e in list do
    table.insert(row, ui.dropZone({
      key = "drop-" .. e.d.ip, accepts = { "device" }, value = "before:" .. e.d.ip, direction = "column", flexGrow = 1,
      onDrop = function(payload, value) dropDeviceBefore(payload, string.sub(value, 8)) end,
    }, { deviceCard(s, e.d, e.i) }))
    if #row == cols then table.insert(rows, ui.row({ key = prefix .. "-r" .. e.i, gap = 10, align = "start" }, row)); row = {} end
  end
  if #row > 0 then
    while #row < cols do table.insert(row, ui.spacer({ flexGrow = 1 })) end
    table.insert(rows, ui.row({ key = prefix .. "-rl", gap = 10, align = "start" }, row))
  end
  return rows
end

-- ---------------------------------------------------------------------------- forms

local function addForm(s)
  if adding == nil then return nil end
  if adding == "pick" then
    return ui.row({ key = "add-pick", gap = 8 }, {
      ui.button({ text = noctalia.tr("panel.add_device"), glyph = "device-desktop", variant = "outline", controlSize = "sm", flexGrow = 1,
        onClick = function() adding = "device"; draw() end }),
      ui.button({ text = noctalia.tr("panel.add_group"), glyph = "folder-plus", variant = "outline", controlSize = "sm", flexGrow = 1,
        onClick = function() adding = "group"; draw() end }),
    })
  end
  if adding == "group" then
    local submit = function()
      local cfg = store.loadConfig()
      local name = store.addGroup(cfg, newGroupName)
      if not name then err = noctalia.tr("panel.bad_group"); draw(); return end
      newGroupName = ""; err = ""; adding = nil
      changed(cfg)
      draw()
    end
    return ui.column({ key = "add-group", gap = 8, padding = 12, fill = "surface_container", radius = 12 }, {
      ui.input({ key = "new-group-name", placeholder = noctalia.tr("panel.group_name"), value = newGroupName, controlSize = "md",
        onChange = function(v) newGroupName = v end, onSubmit = submit }),
      ui.button({ text = noctalia.tr("panel.add_button"), glyph = "plus", variant = "primary", controlSize = "md", onClick = submit }),
    })
  end
  local submit = function()
    local host = store.normalizeHost(newIp)
    if not host then err = noctalia.tr("panel.bad_host"); draw(); return end
    local cfg = store.loadConfig()
    for _, dev in cfg.devices do
      if dev.ip == host then err = noctalia.tr("panel.duplicate"); draw(); return end
    end
    table.insert(cfg.devices, { name = newName or "", ip = host, group = pickedGroup or "", interval = 15, sound = true })
    newName, newIp, pickedGroup = "", "", ""
    err = ""; adding = nil
    changed(cfg)
    draw()
  end
  return ui.column({ key = "add-device", gap = 8, padding = 12, fill = "surface_container", radius = 12 }, {
    ui.input({ key = "new-name", placeholder = noctalia.tr("panel.name"), value = newName, controlSize = "md", onChange = function(v) newName = v end }),
    ui.input({ key = "new-ip", placeholder = noctalia.tr("panel.address"), value = newIp, controlSize = "md",
      onChange = function(v) newIp = v end, onSubmit = submit }),
    groupChips(s, "new", pickedGroup, function(g) pickedGroup = g end),
    ui.button({ text = noctalia.tr("panel.add_button"), glyph = "plus", variant = "primary", controlSize = "md", onClick = submit }),
  })
end

-- ---------------------------------------------------------------------------- draw

draw = function()
  local s = shared.snapshot()
  s.groups = s.groups or {}

  local byGroup = {}
  for i, d in s.devices do
    local g = groupOf(s, d)
    byGroup[g] = byGroup[g] or {}
    table.insert(byGroup[g], { d = d, i = i })
  end

  local body = {}
  for gi, g in s.groups do
    local list = byGroup[g.name] or {}
    table.insert(body, groupHeader(s, g, gi, #list))
    if g.collapsed ~= true then
      if #list == 0 then
        table.insert(body, ui.dropZone({
          key = "gempty-" .. g.name, accepts = { "device" }, value = "group:" .. g.name, direction = "column", height = 44,
          onDrop = function(payload, value) dropOnGroup(payload, value) end,
        }, { ui.label({ text = noctalia.tr("panel.group_empty"), color = "on_surface_variant", fontSize = 12, textAlign = "center" }) }))
      else
        for _, r in cardsRows(s, list, "g" .. gi) do table.insert(body, r) end
      end
    end
  end
  local loose = byGroup[""] or {}
  if #loose > 0 or #s.groups == 0 then
    if #s.groups > 0 then table.insert(body, ungroupedHeader(#loose)) end
    for _, r in cardsRows(s, loose, "none") do table.insert(body, r) end
  end

  local kids = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "server", size = 18, color = shared.color(shared.overall(s.devices)) }),
      ui.label({ text = "Ping Monitor", fontWeight = "bold", fontSize = 15, flexGrow = 1 }),
      ui.button({ glyph = "settings", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.settings"),
        onClick = function() noctalia.openSettings() end }),
      ui.button({ glyph = adding and "x" or "plus", variant = adding and "outline" or "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.add"),
        onClick = function() adding = (adding == nil) and "pick" or nil; err = ""; draw() end }),
      ui.label({ text = noctalia.tr("panel.sound"), color = "on_surface_variant", fontSize = 12 }),
      ui.toggle({
        checked = not s.muted,
        onChange = function(on)
          local cfg = store.loadConfig()
          cfg.muted = not (on == "true" or on == true)
          changed(cfg)
          draw()
        end,
      }),
    }),
  }
  local form = addForm(s)
  if form then table.insert(kids, form) end
  if err ~= "" then table.insert(kids, ui.label({ text = err, color = "error", fontSize = 12 })) end
  if #s.devices == 0 and #s.groups == 0 then
    table.insert(kids, ui.label({ text = noctalia.tr("panel.empty"), color = "on_surface_variant", fontSize = 12 }))
  end
  if TALL then
    table.insert(kids, ui.scroll({ gap = 8, flexGrow = 1 }, body))
  else
    table.insert(kids, ui.column({ gap = 8 }, body))
  end
  panel.render(ui.column(TALL and { gap = 10, padding = 16, height = 640 } or { gap = 10, padding = 16 }, kids))
end

function M.onOpen()
  armed = nil
  draw()
end

function M.watch()
  noctalia.state.watch("snap", function() draw() end)
end

return M
