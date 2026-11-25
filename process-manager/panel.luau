--!nonstrict
-- Process Manager panel: running apps grouped by name, with their CPU and memory now, in a
-- list that scrolls. An app with more than one process opens to them; a process opens its
-- details, with its CPU over time. End asks a process to stop; one that does not stop gets
-- Force end. Renders "processes.model" and sends actions on "processes.command".

local GROUP_HEIGHT = 48
local PROCESS_HEIGHT = 52
-- The list scrolls past this height. The scroll pads its rows by SCROLL_PAD_V above and below.
local MAX_LIST_HEIGHT = 336
local SCROLL_PAD_V = 8
local ROW_GAP = 2
-- Every row ends in these fixed columns, so CPU and memory line up under each other.
local CPU_WIDTH = 56
local MEMORY_WIDTH = 72
local ACTION_WIDTH = 32
local INDENT = 50
local CHEVRON_WIDTH = 20
-- An open app shows this many of its processes; search finds the others. Each row costs CPU
-- time to build, and a render has 25 ms.
local CHILD_LIMIT = 30
-- The name of each process state letter in the translations.
local STATES = { D = "device", I = "idle", R = "running", S = "sleeping", T = "stopped", X = "dead", Z = "zombie", t = "traced" }

local model = nil
local query = ""
local sortBy = "cpu"
local allUsers = false
local expanded = {} -- group names that are open
local detailPid = nil -- the process the details view shows
local icons = {} -- app icon path by name, or false when there is none, from the service

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

local function bytesText(bytes)
  if bytes >= 1024 ^ 2 then
    return memoryText(bytes)
  elseif bytes >= 1024 then
    return string.format("%d KB", math.floor(bytes / 1024 + 0.5))
  end
  return string.format("%d B", bytes)
end

-- Hours, minutes and seconds, with days in front once there are any.
local function elapsedText(seconds)
  seconds = math.floor(seconds)
  local days = seconds // 86400
  local clock = string.format("%02d:%02d:%02d", seconds // 3600 % 24, seconds // 60 % 60, seconds % 60)
  return days > 0 and noctalia.tr("details.days", { days = days, clock = clock }) or clock
end

local function showDetails(pid)
  detailPid = pid
  send({ action = "details", pid = pid })
  render()
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
-- when the processes belong to someone else. In the list each is one glyph, so the columns
-- stay aligned; the details view adds its name.
local function action(processes, stuck, denied, withText)
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
    text = withText and noctalia.tr(tip) or nil,
    variant = withText and variant == "ghost" and "outline" or variant,
    controlSize = "sm",
    width = not withText and ACTION_WIDTH or nil,
    tooltip = not withText and noctalia.tr(tip) or nil,
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
  return ui.row({
    key = "p" .. process.pid,
    gap = 8,
    align = "center",
    height = PROCESS_HEIGHT,
    paddingH = 4,
    radius = 8,
    onClick = function() showDetails(process.pid) end,
  }, {
    -- Indented under the group's name: the width of its chevron and icon, and the gap between.
    ui.box({ width = INDENT }),
    ui.column({ gap = 2, flexGrow = 1 }, detail),
    cpu,
    memory,
    action({ process }, process.stuck, process.denied),
  })
end

local function appIcon(name)
  local icon = icons[name] or nil
  return icon and ui.image({ path = icon, width = 22, height = 22 })
    or ui.glyph({ name = "terminal", size = 20, width = 22, color = "on_surface_variant" })
end

-- An app. One with more than one process opens to them with a click; one with a single
-- process has no chevron and opens that process's details.
local function groupRow(group)
  local single = #group.processes == 1
  local open = not single and expanded[group.name] == true
  local title = single and group.name or noctalia.tr("group.count", { name = group.name, count = #group.processes })
  local cpu, memory = numbers(group.cpu, group.memory, "on_surface")
  return ui.row({
    key = "g" .. group.name,
    gap = 8,
    align = "center",
    height = GROUP_HEIGHT,
    paddingH = 4,
    radius = 8,
    -- A light tint over the panel's own background, which may be translucent.
    fill = open and "on_surface/0.06" or "on_surface/0",
    onClick = function()
      if single then
        showDetails(group.processes[1].pid)
      else
        expanded[group.name] = not open or nil
        render()
      end
    end,
  }, {
    single and ui.box({ width = CHEVRON_WIDTH })
      or ui.glyph({ name = open and "chevron-down" or "chevron-right", size = 16, color = "on_surface_variant", width = CHEVRON_WIDTH }),
    appIcon(group.name),
    ui.label({ text = title, maxLines = 1, flexGrow = 1, color = group.stuck and "error" or "on_surface" }),
    cpu,
    memory,
    action(group.processes, group.stuck, group.denied),
  })
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

-- One fact in the details view: its name above, its value below.
local function fact(name, value, onClick)
  return ui.column({ gap = 2, flexGrow = 1, onClick = onClick }, {
    ui.label({ text = noctalia.tr("details." .. name), color = "on_surface_variant", fontSize = 11 }),
    ui.label({ text = value, maxLines = 1, color = onClick and "primary" or "on_surface" }),
  })
end

local function find(pid)
  for _, process in ipairs(model.processes) do
    if process.pid == pid then
      return process
    end
  end
  return nil
end

-- A total and its rate, or a dash when only the owner or an administrator may read it.
local function ioText(total, rate)
  if total == nil then
    return "—"
  end
  return rate and noctalia.tr("details.rate", { total = bytesText(total), rate = bytesText(rate) }) or bytesText(total)
end

-- One process: what it is doing, its CPU over time, memory, reads and writes, and its whole
-- command line, with End and Force end.
local function detailsView()
  local process = find(detailPid)
  local details = model.details
  -- Keys keep the two views from reusing each other's controls, which keep props they drop.
  local header = ui.row({ key = "details-head", gap = 8, align = "center" }, {
    ui.button({
      glyph = "arrow-left",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("details.back"),
      onClick = function()
        detailPid = nil
        send({ action = "details" })
        render()
      end,
    }),
    process and appIcon(process.name) or ui.glyph({ name = "terminal", size = 20, color = "on_surface_variant" }),
    ui.label({ text = process and process.name or "", fontWeight = "semibold", maxLines = 1, flexGrow = 1 }),
    ui.label({ text = noctalia.tr("details.pid", { pid = detailPid }), color = "on_surface_variant" }),
  })
  if process == nil or (details and details.pid == detailPid and details.gone) then
    return { header, ui.label({ text = noctalia.tr("details.gone"), color = "on_surface_variant" }) }
  end
  if details == nil or details.pid ~= detailPid then
    return { header, ui.label({ text = noctalia.tr("panel.loading"), color = "on_surface_variant" }) }
  end

  local note, noteColor = stateNote(process)
  local parent = find(process.ppid)
  local share = details.memoryShare or 0
  local children = {
    header,
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = noctalia.tr("details.cpu"), color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = cpuText(process.cpu), fontWeight = "semibold" }),
    }),
    ui.graph({ key = "cpu", height = 64, values = details.history, color = "primary", fillOpacity = 0.25 }),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = noctalia.tr("details.memory"), color = "on_surface_variant", flexGrow = 1 }),
      ui.label({
        text = noctalia.tr("details.share", { size = memoryText(process.memory), share = string.format("%.1f", share * 100) }),
        fontWeight = "semibold",
      }),
    }),
    ui.progress({ progress = math.min(share, 1), height = 6 }),
    ui.row({ gap = 12 }, {
      fact("status", STATES[process.state] and noctalia.tr("status." .. STATES[process.state]) or process.state),
      fact("elapsed", details.seconds and elapsedText(details.seconds) or "—"),
      fact("threads", tostring(details.threads or "—")),
    }),
    ui.row({ gap = 12 }, {
      fact("user", process.user),
      fact(
        "parent",
        parent and noctalia.tr("details.parent_of", { name = parent.name, pid = parent.pid }) or tostring(process.ppid),
        parent and function() showDetails(parent.pid) end or nil
      ),
    }),
    ui.row({ gap = 12 }, {
      fact("read", ioText(details.read, details.readRate)),
      fact("written", ioText(details.written, details.writeRate)),
    }),
    ui.column({ gap = 2 }, {
      ui.label({ text = noctalia.tr("details.command"), color = "on_surface_variant", fontSize = 11 }),
      ui.label({ text = details.command or process.args, fontSize = 12, maxLines = 6 }),
    }),
  }
  if details.read == nil then
    table.insert(children, ui.label({ text = noctalia.tr("details.io_hidden"), color = "on_surface_variant", fontSize = 11 }))
  end
  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.label({ text = note or "", color = noteColor or "on_surface_variant", fontSize = 11, maxLines = 2, flexGrow = 1 }),
    action({ process }, process.stuck, process.denied, true),
  }))
  return children
end

local function listView()
  local rows, height = {}, 0
  local list = groups()
  for _, group in ipairs(list) do
    table.insert(rows, groupRow(group))
    height += GROUP_HEIGHT
    if #group.processes > 1 and expanded[group.name] then
      for i, process in ipairs(group.processes) do
        if i > CHILD_LIMIT then
          table.insert(rows, ui.label({
            key = "more" .. group.name,
            text = noctalia.tr("group.more", { count = #group.processes - CHILD_LIMIT }),
            color = "on_surface_variant",
            fontSize = 12,
            height = GROUP_HEIGHT,
          }))
          height += GROUP_HEIGHT
          break
        end
        table.insert(rows, processRow(process))
        height += PROCESS_HEIGHT
      end
    end
  end
  if #rows == 0 then
    table.insert(rows, ui.label({ text = noctalia.tr("panel.none"), color = "on_surface_variant" }))
    height = 32
  end

  local listHeight = math.min(height + ROW_GAP * (#rows - 1) + 2 * SCROLL_PAD_V, MAX_LIST_HEIGHT)
  return {
    ui.row({ key = "list-head", gap = 8, align = "center" }, {
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
    ui.row({ key = "sort", gap = 6, align = "center" }, {
      sortButton("cpu"),
      sortButton("memory"),
      sortButton("name"),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = noctalia.trp("panel.apps", #list), color = "on_surface_variant" }),
    }),
    -- A scroll keeps the height of its first content, so it fills a column of the list's
    -- height (DESIGN.md, section 6.3).
    ui.column({ key = "list", height = listHeight }, {
      ui.scroll({ key = "list", flexGrow = 1, gap = ROW_GAP }, rows),
    }),
  }
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
  panel.render(ui.column({ gap = 12, padding = 16 }, detailPid and detailsView() or listView()))
end

noctalia.state.watch("processes.model", function(value)
  model = value
  render()
end)

noctalia.state.watch("processes.icons", function(value)
  icons = type(value) == "table" and value or {}
  render()
end)

function onOpen(_context)
  detailPid = nil
  send({ action = "open" })
  render()
end

function onClose()
  send({ action = "close" })
end
