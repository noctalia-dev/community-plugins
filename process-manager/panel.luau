--!nonstrict
-- Process Manager panel: running apps grouped by name, with their CPU and memory now, in a
-- list that scrolls. A group opens to its processes. End asks a process to stop; one that does not stop gets
-- Force end. Renders "processes.model" and sends actions on "processes.command".

local GROUP_HEIGHT = 48
local PROCESS_HEIGHT = 52
-- The list scrolls past this height.
local MAX_LIST_HEIGHT = 320
-- Every row ends in these fixed columns, so CPU and memory line up under each other.
local CPU_WIDTH = 56
local MEMORY_WIDTH = 72
local ACTION_WIDTH = 32
local INDENT = 62

local model = nil
local query = ""
local sortBy = "cpu"
local allUsers = false
local expanded = {} -- group names that are open
local icons = {} -- app icon path by name, or false when there is none
-- Looking up an icon is slow, and a render has 25 ms: a few new ones per render.
local ICONS_PER_RENDER = 4
local iconLookups = 0

local function send(command)
  command.n = noctalia.nowMs()
  noctalia.state.set("processes.command", command)
end

local render

local function memoryText(bytes)
  if bytes >= 1024 ^ 3 then
    return string.format("%.1f GB", bytes / 1024 ^ 3)
  end
  return string.format("%d MB", math.floor(bytes / 1024 ^ 2 + 0.5))
end

local function cpuText(cpu)
  return cpu >= 10 and string.format("%d%%", math.floor(cpu + 0.5)) or string.format("%.1f%%", cpu)
end

local function matches(process)
  if query == "" then
    return true
  end
  local needle = query:lower()
  return process.name:lower():find(needle, 1, true) ~= nil
    or process.args:lower():find(needle, 1, true) ~= nil
    or tostring(process.pid) == query
    or process.user:lower() == needle
end

-- Groups the visible processes by name, with totals, sorted as chosen.
local function groups()
  local byName, list = {}, {}
  for _, process in ipairs(model.processes or {}) do
    if (allUsers or process.uid == model.myUid) and matches(process) then
      local group = byName[process.name]
      if group == nil then
        group = { name = process.name, key = process.name:lower(), processes = {}, cpu = 0, memory = 0,
          stuck = false, denied = false }
        byName[process.name] = group
        table.insert(list, group)
      end
      table.insert(group.processes, process)
      group.cpu += process.cpu
      group.memory += process.memory
      group.stuck = group.stuck or process.stuck
      group.denied = group.denied or process.denied
    end
  end
  local function before(a, b)
    if sortBy == "memory" then
      return a.memory > b.memory
    elseif sortBy == "name" then
      return (a.key or a.name) < (b.key or b.name)
    end
    return a.cpu > b.cpu
  end
  table.sort(list, before)
  for _, group in ipairs(list) do
    table.sort(group.processes, before)
  end
  return list
end

local function pidsOf(processes)
  local pids = {}
  for _, process in ipairs(processes) do
    table.insert(pids, process.pid)
  end
  return pids
end

-- End, then Force end once it did not stop, and the administrator's versions of both
-- when the processes belong to someone else. Each is one glyph, so the columns stay aligned.
local function action(processes, stuck, denied)
  local pids = pidsOf(processes)
  local glyph, variant, tip, command
  if denied and model.canElevate then
    glyph, variant = "shield-x", "destructive"
    tip = stuck and "action.force_admin" or "action.end_admin"
    command = { action = stuck and "force" or "end", pids = pids, elevate = true }
  elseif stuck then
    glyph, variant, tip = "skull", "destructive", "action.force"
    command = { action = "force", pids = pids }
  else
    glyph, variant, tip = "x", "ghost", #pids > 1 and "action.end_all" or "action.end"
    command = { action = "end", pids = pids }
  end
  return ui.button({
    glyph = glyph,
    variant = variant,
    controlSize = "sm",
    width = ACTION_WIDTH,
    tooltip = noctalia.tr(tip),
    onClick = function() send(command) end,
  })
end

-- The CPU and memory columns.
local function numbers(cpu, memory, color)
  return ui.label({ text = cpuText(cpu), color = color, width = CPU_WIDTH, textAlign = "end" }),
    ui.label({ text = memoryText(memory), color = color, width = MEMORY_WIDTH, textAlign = "end" })
end

-- What the state letter means, when it explains why a process does not end.
local function stateNote(process)
  if process.state == "D" then
    return noctalia.tr("state.waiting"), "on_surface_variant"
  elseif process.state == "Z" then
    return noctalia.tr("state.zombie"), "on_surface_variant"
  elseif process.denied then
    return noctalia.tr("state.denied", { user = process.user }), "error"
  elseif process.stuck then
    return noctalia.tr("state.stuck"), "error"
  elseif process.ending then
    return noctalia.tr("state.ending"), "on_surface_variant"
  end
  return nil
end

local function processRow(process)
  local note, noteColor = stateNote(process)
  local detail = {
    ui.label({ text = process.args ~= "" and process.args or process.name, maxLines = 1, fontSize = 12 }),
    ui.label({
      text = note or noctalia.tr("process.detail", { pid = process.pid, user = process.user }),
      color = noteColor or "on_surface_variant",
      fontSize = 11,
      maxLines = 1,
    }),
  }
  local cpu, memory = numbers(process.cpu, process.memory, "on_surface_variant")
  return ui.row({ key = "p" .. process.pid, gap = 8, align = "center", height = PROCESS_HEIGHT, paddingH = 4 }, {
    -- Indented under the group's name: the width of its chevron and icon, and the gap between.
    ui.box({ width = INDENT }),
    ui.column({ gap = 2, flexGrow = 1 }, detail),
    cpu,
    memory,
    action({ process }, process.stuck, process.denied),
  })
end

local function groupRow(group)
  local open = expanded[group.name] == true
  if icons[group.name] == nil and iconLookups < ICONS_PER_RENDER then
    iconLookups += 1
    icons[group.name] = noctalia.appIconPath(group.name, 24) or false
  end
  local icon = icons[group.name] or nil
  local title = #group.processes > 1 and noctalia.tr("group.count", { name = group.name, count = #group.processes })
    or group.name
  local children = {
    ui.button({
      glyph = open and "chevron-down" or "chevron-right",
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        expanded[group.name] = not open or nil
        render()
      end,
    }),
    icon and ui.image({ path = icon, width = 22, height = 22 })
      or ui.glyph({ name = "terminal", size = 20, color = "on_surface_variant" }),
    ui.label({ text = title, maxLines = 1, flexGrow = 1, color = group.stuck and "error" or "on_surface" }),
  }
  local cpu, memory = numbers(group.cpu, group.memory, "on_surface")
  table.insert(children, cpu)
  table.insert(children, memory)
  table.insert(children, action(group.processes, group.stuck, group.denied))
  return ui.row({
    key = "g" .. group.name,
    gap = 8,
    align = "center",
    height = GROUP_HEIGHT,
    paddingH = 4,
    radius = 8,
    -- A light tint over the panel's own background, which may be translucent.
    fill = open and "on_surface/0.06" or "on_surface/0",
  }, children)
end

local function sortButton(value)
  local active = sortBy == value
  return ui.button({
    text = noctalia.tr("sort." .. value),
    variant = active and "secondary" or "ghost",
    selected = active,
    controlSize = "sm",
    onClick = function()
      sortBy = value
      render()
    end,
  })
end

render = function()
  if model == nil or model.processes == nil then
    panel.render(ui.column({ padding = 16 }, {
      ui.label({ text = noctalia.tr("panel.loading"), color = "on_surface_variant" }),
    }))
    return
  end
  if not model.ready then
    panel.render(ui.column({ padding = 16 }, {
      ui.label({ text = noctalia.tr("panel.no_ps"), color = "on_surface_variant" }),
    }))
    return
  end

  local rows, height = {}, 0
  iconLookups = 0
  local list = groups()
  for _, group in ipairs(list) do
    table.insert(rows, groupRow(group))
    height += GROUP_HEIGHT
    if expanded[group.name] then
      for _, process in ipairs(group.processes) do
        table.insert(rows, processRow(process))
        height += PROCESS_HEIGHT
      end
    end
  end
  if #rows == 0 then
    table.insert(rows, ui.label({ text = noctalia.tr("panel.none"), color = "on_surface_variant" }))
    height = 32
  end

  local listHeight = math.min(height + 2 * #rows, MAX_LIST_HEIGHT)
  panel.render(ui.column({ gap = 12, padding = 16 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "list-details", size = 20, color = "primary" }),
      ui.label({ text = noctalia.tr("panel.title"), fontWeight = "semibold", flexGrow = 1 }),
      ui.button({
        text = noctalia.tr("panel.all_users"),
        variant = allUsers and "secondary" or "ghost",
        selected = allUsers,
        controlSize = "sm",
        onClick = function()
          allUsers = not allUsers
          render()
        end,
      }),
    }),
    ui.input({
      key = "search",
      value = query,
      placeholder = noctalia.tr("panel.search"),
      focus = true,
      onChange = function(text)
        query = noctalia.string.trim(text)
        render()
      end,
    }),
    ui.row({ gap = 6, align = "center" }, {
      sortButton("cpu"),
      sortButton("memory"),
      sortButton("name"),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = noctalia.trp("panel.apps", #list), color = "on_surface_variant" }),
    }),
    -- A scroll keeps the height of its first content, so it fills a column of the list's
    -- height (DESIGN.md, section 6.3).
    ui.column({ height = listHeight }, {
      ui.scroll({ key = "list", flexGrow = 1, gap = 2 }, rows),
    }),
  }))
end

noctalia.state.watch("processes.model", function(value)
  model = value
  render()
end)

function onOpen(_context)
  send({ action = "open" })
  render()
end

function onClose()
  send({ action = "close" })
end
