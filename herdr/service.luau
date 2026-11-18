--!nonstrict
-- HerdR service: the single owner of Herdr process I/O and normalized state.
--
-- UI entries communicate only through noctalia.state. This keeps one poller and
-- one process-facing implementation even when the bar exists on several outputs.

local COMMAND_TIMEOUT_MS = 6000
local STOP_TIMEOUT_MS = 20000
-- HerdR exposes no event stream over its socket API, so the widget can only be as
-- fresh as this poll ladder. A refresh is two tiny local socket calls, so the cost
-- of a fast cadence is small: stay close to the TUI while the panel is open, while
-- an agent is mid-task or waiting on you, and still notice a fresh TUI action
-- within a few seconds when everything is idle.
local PANEL_INTERVAL_MS = 1000
local ATTENTION_INTERVAL_MS = 1500
local WORKING_INTERVAL_MS = 1500
local IDLE_INTERVAL_MS = 5000
local MAX_SESSION_BYTES = 2 * 1024 * 1024
local MAX_SNAPSHOT_BYTES = 2 * 1024 * 1024
local MAX_SESSION_FILE_BYTES = 1024 * 1024
local MAX_SESSIONS = 200
local MAX_AGENTS_PER_SESSION = 500
local MAX_MACHINES = 10
local MACHINE_TIMEOUT_MS = 10000

local STATUS_PRIORITY = {
  blocked = 1,
  done = 2,
  working = 3,
  idle = 4,
  unknown = 5,
  none = 6,
}

-- The raw agent statuses HerdR can report ("AgentStatus" in `herdr api schema`).
-- "none" is deliberately absent: it is the synthetic status this plugin gives a pane
-- that runs no agent, and it has no counter bucket, so accepting it as an input here
-- would do arithmetic on a nil field.
local AGENT_STATUSES = {
  blocked = true,
  done = true,
  working = true,
  idle = true,
  unknown = true,
}

local state = {
  available = false,
  refreshing = false,
  error = nil,
  running = 0,
  agents = 0,
  blocked = 0,
  done = 0,
  working = 0,
  idle = 0,
  unknown = 0,
  sessions = {},
  hyprland_focus = false,
  action = nil,
}

local previousByName = {}
-- Explicit user choices disambiguate terminals that share a process. Revalidate
-- against the live window/PID mapping each time; IDs are not persisted to disk.
local niriSelectedWindows = {}
local niriFocusInFlight = false
local refreshInFlight = false
local refreshAgain = false
local refreshGeneration = 0
local panelOpen = noctalia.state.get("herdr.panel_open.attached") == true
local currentInterval = 0

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function failureReason(result)
  if result == nil then
    return noctalia.tr("error.command_failed")
  end
  if result.timedOut then
    return noctalia.tr("error.command_timed_out")
  end
  noctalia.log("HerdR command failed with exit code " .. tostring(result.exitCode or "unknown"))
  return noctalia.tr("error.command_failed")
end

local function validSessionName(name)
  if type(name) ~= "string" or name == "" or #name > 64 or name == "." or name == ".." then
    return false
  end
  for index = 1, #name do
    local byte = string.byte(name, index)
    local valid = (byte >= 48 and byte <= 57)
      or (byte >= 65 and byte <= 90)
      or (byte >= 97 and byte <= 122)
      or byte == 46
      or byte == 95
      or byte == 45
    if not valid then
      return false
    end
  end
  return true
end

local function validPaneId(pane)
  if type(pane) ~= "string" or #pane > 80 then
    return false
  end
  local left, right = pane:match("^([%w_%-]+):([%w_%-]+)$")
  return left ~= nil and right ~= nil and left ~= "" and right ~= ""
end

local function basename(path)
  if type(path) ~= "string" or path == "" then
    return ""
  end
  local clean = path:gsub("/+$", "")
  return clean:match("([^/]+)$") or clean
end

local function uniqueStrings(values)
  local seen = {}
  local out = {}
  for _, value in ipairs(values or {}) do
    if type(value) == "string" and value ~= "" and seen[value] ~= true then
      seen[value] = true
      table.insert(out, value)
    end
  end
  return out
end

local function readStoppedProjects(sessionInfo)
  local sessionDir = sessionInfo.session_dir
  if type(sessionDir) ~= "string" or sessionDir == "" then
    return {}, 0
  end

  local sessionPath = sessionDir .. "/session.json"
  local info = noctalia.fileInfo(sessionPath)
  if type(info) ~= "table" or info.isDir == true or (tonumber(info.size) or 0) > MAX_SESSION_FILE_BYTES then
    return {}, 0
  end

  local raw = noctalia.readFile(sessionPath)
  if type(raw) ~= "string" or raw == "" then
    return {}, 0
  end

  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" or type(decoded.workspaces) ~= "table" then
    return {}, 0
  end

  local projects = {}
  local workspaceCount = 0
  local home = noctalia.getenv("HOME") or ""
  for _, workspace in ipairs(decoded.workspaces) do
    if type(workspace) == "table" then
      workspaceCount = workspaceCount + 1
      local label = trim(workspace.custom_name)
      if label == "" then
        local cwd = trim(workspace.identity_cwd)
        if cwd == home and home ~= "" then
          label = "~"
        else
          label = basename(cwd)
        end
      end
      if label ~= "" then
        table.insert(projects, label)
      end
    end
  end

  return uniqueStrings(projects), workspaceCount
end

local function statusOf(value)
  if AGENT_STATUSES[value] == true then
    return value
  end
  return "unknown"
end

local function snapshotCommand(sessionInfo)
  if sessionInfo.default == true then
    return { "herdr", "api", "snapshot" }
  end
  return { "herdr", "--session", sessionInfo.name, "api", "snapshot" }
end

-- Workspace/tab label lookups and project labels, shared by session and machine
-- snapshot normalization.
local function labelMaps(snapshot)
  local workspaceLabels = {}
  local projects = {}
  for _, workspace in ipairs(snapshot.workspaces or {}) do
    if type(workspace) == "table" and type(workspace.workspace_id) == "string" then
      local label = trim(workspace.label)
      workspaceLabels[workspace.workspace_id] = label
      if label ~= "" then
        table.insert(projects, label)
      end
    end
  end

  local tabLabels = {}
  for _, tab in ipairs(snapshot.tabs or {}) do
    if type(tab) == "table" and type(tab.tab_id) == "string" then
      local label = trim(tab.label)
      if label == tostring(tab.number or "") then
        label = ""
      end
      tabLabels[tab.tab_id] = label
    end
  end

  return workspaceLabels, tabLabels, projects
end

-- Row title preference, shared by agents and plain panes. A path with no
-- basename (a pane sitting at "/") falls back to the path itself rather than a
-- raw pane id.
local function rowTitle(entry)
  local candidates = {
    trim(entry.title),
    trim(entry.terminal_title_stripped),
    trim(entry.terminal_title),
    trim(entry.display_agent),
    trim(entry.name),
    trim(entry.agent),
  }
  for _, value in ipairs(candidates) do
    if value ~= "" then
      return value
    end
  end

  for _, path in ipairs({ trim(entry.cwd), trim(entry.foreground_cwd) }) do
    if path ~= "" then
      local name = basename(path)
      return name ~= "" and name or path
    end
  end

  return trim(entry.pane_id)
end

-- Builds the visible list for one snapshot as workspaces, each with the panes it
-- contains. A workspace with a single pane renders as one row; a workspace with
-- more than one pane renders its panes underneath it, so two panes in the same
-- workspace no longer look like two unrelated rows.
--
-- The grouping is structural (a workspace's real pane count decides whether panes
-- are listed under it), while visibility follows hide_agentless_panes: a pane with
-- no agent is only listed when that setting is off, and a workspace whose panes are
-- all hidden is skipped entirely. Panes with no agent use the "none" status, which is
-- intentionally absent from the counts so the bar rollup stays agent-based.
local function priorityOf(status)
  return STATUS_PRIORITY[status] or STATUS_PRIORITY.unknown
end

local function sortRows(rows)
  table.sort(rows, function(left, right)
    local leftPriority = priorityOf(left.status)
    local rightPriority = priorityOf(right.status)
    if leftPriority ~= rightPriority then
      return leftPriority < rightPriority
    end
    if left.seq ~= right.seq then
      return left.seq > right.seq
    end
    return left.pane < right.pane
  end)
end

local function sortWorkspaces(list)
  table.sort(list, function(left, right)
    local leftPriority = priorityOf(left.status)
    local rightPriority = priorityOf(right.status)
    if leftPriority ~= rightPriority then
      return leftPriority < rightPriority
    end
    return string.lower(left.label) < string.lower(right.label)
  end)
end

local function collectWorkspaces(snapshot, workspaceLabels, tabLabels)
  local counts = { blocked = 0, done = 0, working = 0, idle = 0, unknown = 0 }
  -- Default true: a pane running no agent stays hidden unless the user opts in.
  -- The switch is declared on the bar widget, so read it from shared plugin state.
  local hideAgentless = true
  local sharedSettings = noctalia.state.get("herdr.settings")
  if type(sharedSettings) == "table" and sharedSettings.hide_agentless_panes == false then
    hideAgentless = false
  end

  local sourceAgents = type(snapshot.agents) == "table" and snapshot.agents or {}
  local sourcePanes = type(snapshot.panes) == "table" and snapshot.panes or {}

  -- Pass 1: every agent counts toward the rollup, and the highest-priority agent on a
  -- pane becomes that pane's status and title.
  local agentByPane = {}
  local agentCount = 0
  for _, agent in ipairs(sourceAgents) do
    if type(agent) == "table" then
      local status = statusOf(agent.agent_status)
      counts[status] = counts[status] + 1
      agentCount = agentCount + 1

      local paneId = trim(agent.pane_id)
      if paneId ~= "" then
        local current = agentByPane[paneId]
        if current == nil then
          agentByPane[paneId] = {
            status = status,
            seq = tonumber(agent.state_change_seq) or 0,
            title = rowTitle(agent),
            workspace = trim(agent.workspace_id),
            tab = trim(agent.tab_id),
            agents = 1,
          }
        else
          current.agents = current.agents + 1
          if priorityOf(status) < priorityOf(current.status) then
            current.status = status
            current.seq = tonumber(agent.state_change_seq) or 0
            current.title = rowTitle(agent)
            current.workspace = trim(agent.workspace_id)
            current.tab = trim(agent.tab_id)
          end
        end
      end
    end
  end

  -- Pass 2: panes carry the workspace and tab identity, so they build the groups.
  local order = {}
  local groups = {}
  local function groupFor(workspaceId)
    local group = groups[workspaceId]
    if group == nil then
      group = {
        id = workspaceId,
        label = workspaceLabels[workspaceId] or "",
        status = "none",
        agents = 0,
        panes = 0,
        children = {},
      }
      groups[workspaceId] = group
      table.insert(order, group)
    end
    return group
  end

  local function addPane(paneId, workspaceId, label, tab, title, status, seq, agents)
    local group = groupFor(workspaceId)
    group.panes = group.panes + 1
    group.agents = group.agents + (agents or 0)
    table.insert(group.children, {
      pane = paneId,
      tab = tab,
      title = title,
      status = status,
      seq = seq,
      label = label,
    })
  end

  local covered = {}
  for _, pane in ipairs(sourcePanes) do
    if type(pane) == "table" then
      local paneId = trim(pane.pane_id)
      if paneId ~= "" then
        local workspaceId = trim(pane.workspace_id)
        local tab = tabLabels[trim(pane.tab_id)] or ""
        local agent = agentByPane[paneId]
        if agent ~= nil then
          covered[paneId] = true
          addPane(paneId, workspaceId, agent.title, tab, agent.title, agent.status, agent.seq, agent.agents)
        elseif hideAgentless == false then
          addPane(paneId, workspaceId, rowTitle(pane), tab, rowTitle(pane), "none", 0, 0)
        end
      end
    end
  end

  -- An agent whose pane is missing from the pane list still has to show up.
  for paneId, agent in pairs(agentByPane) do
    if covered[paneId] ~= true then
      local workspaceId = agent.workspace ~= "" and agent.workspace or paneId
      addPane(paneId, workspaceId, agent.title, tabLabels[agent.tab] or "", agent.title, agent.status, agent.seq, agent.agents)
    end
  end

  -- Pass 3: drop what has nothing to show, name the leftovers, sort, and cap.
  local list = {}
  local total = 0
  for _, group in ipairs(order) do
    if #group.children > 0 then
      sortRows(group.children)
      local first = group.children[1]
      group.status = first.status
      if group.label == "" then
        group.label = first.tab ~= "" and first.tab or (first.title ~= "" and first.title or group.id)
      end
      total = total + #group.children
      table.insert(list, group)
    end
  end

  sortWorkspaces(list)

  local over = total - MAX_AGENTS_PER_SESSION
  while over > 0 and #list > 0 do
    local group = list[#list]
    table.remove(group.children)
    over = over - 1
    if #group.children == 0 then
      table.remove(list)
    end
  end

  return list, counts, agentCount
end

local function normalizeSnapshot(sessionInfo, decoded)
  local result = type(decoded) == "table" and decoded.result or nil
  local snapshot = type(result) == "table" and result.snapshot or nil
  if type(snapshot) ~= "table" then
    return nil, noctalia.tr("error.bad_snapshot")
  end

  local workspaceLabels, tabLabels, projects = labelMaps(snapshot)
  local groups, counts, agentCount = collectWorkspaces(snapshot, workspaceLabels, tabLabels)

  return {
    name = sessionInfo.name,
    running = true,
    is_default = sessionInfo.default == true,
    version = trim(snapshot.version),
    projects = uniqueStrings(projects),
    workspaces = type(snapshot.workspaces) == "table" and #snapshot.workspaces or 0,
    agents = agentCount,
    blocked = counts.blocked,
    done = counts.done,
    working = counts.working,
    idle = counts.idle,
    unknown = counts.unknown,
    workspace_list = groups,
    stale = false,
    error = nil,
    window = nil,
  }, nil
end

-- Other machines saved in HerdR ("herdr machine list"). Their sessions are only
-- reachable over the socket API, so they are read as extra rows and cached between
-- fetches. When show_other_machines is enabled, their agent states count toward the
-- bar rollup and panel summary just like local sessions.
local machineCache = {}

local function machineSnapshotCommand(machine)
  return { "herdr", "--machine", machine.id, "api", "snapshot" }
end

local function emptyMachineRow(machine, reason)
  return {
    name = machine.label,
    remote = true,
    machine = machine.id,
    target = machine.target,
    running = true,
    is_default = false,
    version = "",
    projects = {},
    workspaces = 0,
    agents = 0,
    blocked = 0,
    done = 0,
    working = 0,
    idle = 0,
    unknown = 0,
    workspace_list = {},
    stale = true,
    error = reason,
    window = nil,
  }
end

local function fallbackMachineRow(machine)
  local previous = machineCache[machine.id]
  if type(previous) ~= "table" then
    return emptyMachineRow(machine, noctalia.tr("error.machine_failed"))
  end

  local row = {}
  for key, value in pairs(previous) do
    row[key] = value
  end
  row.stale = true
  row.error = noctalia.tr("error.machine_failed")
  return row
end

local function normalizeMachineSnapshot(machine, decoded)
  local result = type(decoded) == "table" and decoded.result or nil
  local snapshot = type(result) == "table" and result.snapshot or nil
  if type(snapshot) ~= "table" then
    return nil
  end

  local workspaceLabels, tabLabels, projects = labelMaps(snapshot)
  local groups, counts, agentCount = collectWorkspaces(snapshot, workspaceLabels, tabLabels)

  local row = emptyMachineRow(machine, nil)
  row.version = trim(snapshot.version)
  row.projects = uniqueStrings(projects)
  row.workspaces = type(snapshot.workspaces) == "table" and #snapshot.workspaces or 0
  row.agents = agentCount
  row.blocked = counts.blocked
  row.done = counts.done
  row.working = counts.working
  row.idle = counts.idle
  row.unknown = counts.unknown
  row.workspace_list = groups
  row.stale = false
  row.error = nil
  return row
end

local function fetchMachines(generation, done)
  local started = noctalia.runAsync({ "herdr", "machine", "list", "--json" }, function(result)
    if generation ~= refreshGeneration then
      done()
      return
    end

    local decoded = nil
    if result.exitCode == 0 and not result.timedOut then
      decoded = noctalia.json.decode(result.stdout or "")
    end

    local machines = {}
    if type(decoded) == "table" then
      for _, machine in ipairs(decoded) do
        if type(machine) == "table" and machine.enabled ~= false
          and type(machine.id) == "string" and machine.id ~= "" and #machine.id <= 128 then
          local label = trim(machine.label)
          if label == "" then
            label = machine.id
          end
          table.insert(machines, {
            id = machine.id,
            label = label,
            target = trim(machine.target),
          })
          if #machines >= MAX_MACHINES then
            break
          end
        end
      end
    else
      noctalia.log("HerdR machine list could not be read")
    end

    if #machines == 0 then
      machineCache = {}
      done()
      return
    end

    local outstanding = #machines
    local resolved = {}

    local function machineDone()
      outstanding = outstanding - 1
      if outstanding > 0 then
        return
      end
      if generation == refreshGeneration then
        machineCache = resolved
      end
      done()
    end

    for _, machine in ipairs(machines) do
      local launched = noctalia.runAsync(machineSnapshotCommand(machine), function(snapshotResult)
        if generation ~= refreshGeneration then
          machineDone()
          return
        end

        local row = nil
        if snapshotResult.exitCode == 0 and not snapshotResult.timedOut then
          row = normalizeMachineSnapshot(machine, noctalia.json.decode(snapshotResult.stdout or ""))
        end

        resolved[machine.id] = row or fallbackMachineRow(machine)
        machineDone()
      end, MACHINE_TIMEOUT_MS)

      if not launched then
        resolved[machine.id] = fallbackMachineRow(machine)
        machineDone()
      end
    end
  end, MACHINE_TIMEOUT_MS)

  if not started then
    done()
  end
end

local function stoppedRow(sessionInfo)
  local projects, workspaceCount = readStoppedProjects(sessionInfo)
  return {
    name = sessionInfo.name,
    running = false,
    is_default = sessionInfo.default == true,
    version = "",
    projects = projects,
    workspaces = workspaceCount,
    agents = 0,
    blocked = 0,
    done = 0,
    working = 0,
    idle = 0,
    unknown = 0,
    workspace_list = {},
    stale = false,
    error = nil,
    window = nil,
  }
end

local function staleRow(sessionInfo, reason)
  local previous = previousByName[sessionInfo.name]
  if type(previous) ~= "table" then
    local row = stoppedRow(sessionInfo)
    row.running = true
    row.stale = true
    row.error = reason
    return row
  end

  local row = {}
  for key, value in pairs(previous) do
    row[key] = value
  end
  row.running = true
  row.is_default = sessionInfo.default == true
  row.stale = true
  row.error = reason
  row.window = nil
  return row
end

local function sessionFromArgs(args)
  if type(args) ~= "string" or args == "" then
    return nil
  end

  local words = {}
  for word in args:gmatch("%S+") do
    table.insert(words, word)
  end

  for index, word in ipairs(words) do
    local executable = word:match("([^/]+)$") or word
    if executable == "herdr" then
      local name = "default"
      local command = nil
      local cursor = index + 1

      while cursor <= #words do
        local token = words[cursor]
        if token == "--remote" or token:match("^%-%-remote=") then
          return nil
        elseif token == "--handoff" then
          cursor = cursor + 1
        elseif token == "--session" then
          name = words[cursor + 1] or ""
          cursor = cursor + 2
        else
          local inline = token:match("^%-%-session=(.+)$")
          if inline ~= nil then
            name = inline
            cursor = cursor + 1
          elseif token == "session" and words[cursor + 1] == "attach" then
            name = words[cursor + 2] or ""
            command = "attach"
            break
          else
            command = token
            break
          end
        end
      end

      -- Short-lived API commands are not attached terminal clients.
      if (command ~= nil and command ~= "attach") or not validSessionName(name) then
        return nil
      end
      return name
    end
  end

  return nil
end

local function parentPid(pid)
  if type(pid) ~= "string" or pid:match("^%d+$") == nil then
    return nil
  end
  local stat = noctalia.readFile("/proc/" .. pid .. "/stat")
  if type(stat) ~= "string" then
    return nil
  end
  return stat:match("^%d+ %b() %S (%d+)")
end

local function detectHyprlandWindows(callback)
  local canFocus = noctalia.commandExists("hyprctl") and noctalia.commandExists("ps")
  state.hyprland_focus = canFocus
  if not canFocus then
    callback({})
    return
  end

  local started = noctalia.runAsync({ "hyprctl", "clients", "-j" }, function(clientResult)
    if clientResult.exitCode ~= 0 or clientResult.timedOut then
      callback({})
      return
    end

    local clients = noctalia.json.decode(clientResult.stdout or "")
    if type(clients) ~= "table" then
      callback({})
      return
    end

    local windowsByPid = {}
    for _, client in ipairs(clients) do
      if type(client) == "table" and tonumber(client.pid) ~= nil and type(client.address) == "string" then
        local workspace = type(client.workspace) == "table" and trim(client.workspace.name) or ""
        windowsByPid[tostring(math.floor(tonumber(client.pid)))] = {
          address = client.address,
          workspace = workspace,
        }
      end
    end

    if next(windowsByPid) == nil then
      callback({})
      return
    end

    local psStarted = noctalia.runAsync({ "ps", "-C", "herdr", "-o", "pid=,args=" }, function(psResult)
      if psResult.exitCode ~= 0 or psResult.timedOut then
        callback({})
        return
      end

      local windows = {}
      for line in tostring(psResult.stdout or ""):gmatch("[^\r\n]+") do
        local pid, args = line:match("^%s*(%d+)%s+(.+)$")
        local sessionName = sessionFromArgs(args)
        if sessionName ~= nil and windows[sessionName] == nil then
          local ancestor = pid
          for _ = 0, 12 do
            local window = windowsByPid[ancestor]
            if window ~= nil then
              windows[sessionName] = window
              break
            end
            local parent = parentPid(ancestor)
            if parent == nil or parent == "0" or parent == "1" or parent == ancestor then
              break
            end
            ancestor = parent
          end
        end
      end

      callback(windows)
    end, COMMAND_TIMEOUT_MS)

    if not psStarted then
      callback({})
    end
  end, COMMAND_TIMEOUT_MS)

  if not started then
    callback({})
  end
end

local function useNiri()
  return trim(noctalia.getenv("NIRI_SOCKET")) ~= "" and noctalia.commandExists("niri")
end

local function detectNiriWindows(callback)
  state.hyprland_focus = false
  if not noctalia.commandExists("ps") then
    callback({}, "error.command_failed")
    return
  end

  local started = noctalia.runAsync({ "niri", "msg", "--json", "windows" }, function(result)
    local clients = result.exitCode == 0 and not result.timedOut
      and noctalia.json.decode(result.stdout or "") or nil
    if type(clients) ~= "table" then
      callback({}, "error.command_failed")
      return
    end

    local windowsByPid = {}
    local titlesById = {}
    for _, client in ipairs(clients) do
      local pid = type(client) == "table" and tonumber(client.pid) or nil
      local id = type(client) == "table" and tonumber(client.id) or nil
      if pid ~= nil and pid > 0 and pid == math.floor(pid)
        and id ~= nil and id >= 0 and id == math.floor(id) and id <= 9007199254740991 then
        local key = string.format("%.0f", pid)
        if windowsByPid[key] == nil then
          windowsByPid[key] = {}
        end
        -- Ghostty and other terminals can own several windows in one process.
        local windowId = string.format("%.0f", id)
        windowsByPid[key][windowId] = true
        titlesById[windowId] = type(client.title) == "string" and trim(client.title) or ""
      end
    end

    if next(windowsByPid) == nil then
      callback({})
      return
    end

    local psStarted = noctalia.runAsync({ "ps", "-C", "herdr", "-o", "pid=,args=" }, function(psResult)
      if psResult.timedOut or (psResult.exitCode ~= 0 and psResult.exitCode ~= 1) then
        callback({}, "error.command_failed")
        return
      end
      local windows = {}
      for line in tostring(psResult.stdout or ""):gmatch("[^\r\n]+") do
        local pid, args = line:match("^%s*(%d+)%s+(.+)$")
        local name = sessionFromArgs(args)
        if name ~= nil then
          local ancestor = pid
          for _ = 0, 12 do
            if windowsByPid[ancestor] ~= nil then
              local candidate = windowsByPid[ancestor]
              -- One session can have clients under different terminal PIDs.
              -- Collect every candidate before validating a remembered choice.
              if windows[name] == nil then
                windows[name] = { compositor = "niri", ids = {} }
              end
              for id in pairs(candidate) do
                windows[name].ids[id] = true
              end
              break
            end
            local parent = parentPid(ancestor)
            if parent == nil or parent == "0" or parent == "1" or parent == ancestor then
              break
            end
            ancestor = parent
          end
        end
      end

      -- Herdr 0.9.5 defaults to "{hostname}: {workspace}". Reuse the workspace
      -- labels already polled by this service; no title changes or extra IPC.
      local hostname = trim(noctalia.readFile("/proc/sys/kernel/hostname"))
      local expectedTitles = {}
      if hostname ~= "" then
        for _, session in ipairs(state.sessions or {}) do
          if session.remote ~= true then
            local titles = {}
            for _, project in ipairs(session.projects or {}) do
              titles[hostname .. ": " .. project] = true
            end
            expectedTitles[session.name] = titles
          end
        end
      end

      local function hasSession(title, name)
        local escaped = name:gsub("(%W)", "%%%1")
        return title:find("%f[%w_.%-]" .. escaped .. "%f[^%w_.%-]") ~= nil
      end

      local function titleScore(name, id)
        local title = titlesById[id] or ""
        local lower = string.lower(title)
        local marked = lower == "herdr" or lower:match("^herdr[%s:%[%(%-]") ~= nil
        local body = marked and trim(title:sub(6):gsub("^[%s:%-]+", "")) or title
        local exact = expectedTitles[name] ~= nil and expectedTitles[name][body] == true
        local named = marked and hasSession(title, name)
        if not exact and not marked then return 0 end
        -- A generic "herdr" title cannot identify a session when its terminal
        -- process also hosts another session. Require a distinct session title.
        for other, candidate in pairs(windows) do
          if other ~= name and candidate.ids[id] then
            if exact then
              if expectedTitles[other] and expectedTitles[other][body] then return 0 end
            elseif not named or hasSession(title, other) then
              return 0
            end
          end
        end
        return (exact or named) and 2 or 1
      end

      for name, window in pairs(windows) do
        local selected = niriSelectedWindows[name]
        if selected ~= nil and window.ids[selected] then
          window.id = selected
        else
          -- Polling can observe incomplete process/window lists. Only a click
          -- may invalidate a remembered choice after checking fresh candidates.
          local preferred, bestScore, matches = nil, 0, 0
          for id in pairs(window.ids) do
            local score = titleScore(name, id)
            if score > bestScore then
              preferred, bestScore, matches = id, score, 1
            elseif score > 0 and score == bestScore then
              matches = matches + 1
            end
          end
          local count = 0
          for id in pairs(window.ids) do
            window.id = id
            count = count + 1
          end
          if matches == 1 then window.id = preferred end
          window.ambiguous = matches ~= 1 and count > 1
        end
      end
      callback(windows)
    end, COMMAND_TIMEOUT_MS)
    if not psStarted then
      callback({}, "error.command_failed")
    end
  end, COMMAND_TIMEOUT_MS)
  if not started then
    callback({}, "error.command_failed")
  end
end

local function detectSessionWindows(callback)
  if useNiri() then
    detectNiriWindows(callback)
  else
    detectHyprlandWindows(callback)
  end
end

local function chooseInterval()
  if panelOpen then
    return PANEL_INTERVAL_MS
  end
  if (state.blocked or 0) > 0 or (state.done or 0) > 0 then
    return ATTENTION_INTERVAL_MS
  end
  if (state.working or 0) > 0 then
    return WORKING_INTERVAL_MS
  end
  return IDLE_INTERVAL_MS
end

local function updateInterval()
  local wanted = chooseInterval()
  if wanted ~= currentInterval then
    currentInterval = wanted
    noctalia.setUpdateInterval(wanted)
  end
end

local function publish()
  noctalia.state.set("herdr.state", state)
  updateInterval()
end

local function recomputeTotals()
  state.running = 0
  state.agents = 0
  state.blocked = 0
  state.done = 0
  state.working = 0
  state.idle = 0
  state.unknown = 0

  previousByName = {}
  for _, session in ipairs(state.sessions or {}) do
    -- Remote rows count toward the rollup too, so an agent waiting on another
    -- machine still raises the bar badge. They are excluded from previousByName,
    -- which only backs the stale-snapshot fallback for local sessions.
    if session.remote ~= true then
      previousByName[session.name] = session
    end
    if session.running == true then
      state.running = state.running + 1
    end
    state.agents = state.agents + (tonumber(session.agents) or 0)
    state.blocked = state.blocked + (tonumber(session.blocked) or 0)
    state.done = state.done + (tonumber(session.done) or 0)
    state.working = state.working + (tonumber(session.working) or 0)
    state.idle = state.idle + (tonumber(session.idle) or 0)
    state.unknown = state.unknown + (tonumber(session.unknown) or 0)
  end
end

local function sortSessions(sessions)
  table.sort(sessions, function(left, right)
    if (left.remote == true) ~= (right.remote == true) then
      return left.remote ~= true
    end
    if left.is_default ~= right.is_default then
      return left.is_default == true
    end
    if left.running ~= right.running then
      return left.running == true
    end
    return string.lower(left.name) < string.lower(right.name)
  end)
end

-- Remote rows are re-appended from the cache on every refresh so a skipped
-- machine poll never blanks them out of the list.
local function appendMachineRows(sessions)
  if noctalia.getConfig("show_other_machines") ~= true then
    return
  end
  for _, row in pairs(machineCache) do
    table.insert(sessions, row)
  end
end

local function finishRefresh(generation, sessions)
  detectSessionWindows(function(windows)
    if generation ~= refreshGeneration then
      return
    end

    for _, session in ipairs(sessions) do
      if session.remote ~= true then
        session.window = windows[session.name]
      end
    end

    appendMachineRows(sessions)
    sortSessions(sessions)
    state.available = true
    state.refreshing = false
    state.error = nil
    state.sessions = sessions
    recomputeTotals()
    refreshInFlight = false
    publish()

    if refreshAgain then
      refreshAgain = false
      refresh()
    end
  end)
end

function refresh()
  if refreshInFlight then
    refreshAgain = true
    return
  end

  local available = noctalia.commandExists("herdr")
  state.available = available
  if not available then
    state.refreshing = false
    state.error = noctalia.tr("error.herdr_missing")
    state.sessions = {}
    recomputeTotals()
    publish()
    return
  end

  refreshInFlight = true
  refreshGeneration = refreshGeneration + 1
  local generation = refreshGeneration
  state.refreshing = true
  state.error = nil
  publish()

  local started = noctalia.runAsync({ "herdr", "session", "list", "--json" }, function(result)
    if generation ~= refreshGeneration then
      return
    end

    if result.exitCode ~= 0 or result.timedOut then
      state.refreshing = false
      state.error = failureReason(result)
      refreshInFlight = false
      publish()
      return
    end

    local stdout = result.stdout or ""
    if #stdout > MAX_SESSION_BYTES then
      state.refreshing = false
      state.error = noctalia.tr("error.session_list_too_large")
      refreshInFlight = false
      publish()
      return
    end

    local decoded = noctalia.json.decode(stdout)
    local rawSessions = type(decoded) == "table" and decoded.sessions or nil
    if type(rawSessions) ~= "table" then
      state.refreshing = false
      state.error = noctalia.tr("error.bad_session_list")
      refreshInFlight = false
      publish()
      return
    end

    local sessions = {}
    local pending = 0

    local function snapshotDone()
      pending = pending - 1
      if pending == 0 then
        finishRefresh(generation, sessions)
      end
    end

    if noctalia.getConfig("show_other_machines") == true then
      pending = pending + 1
      fetchMachines(generation, snapshotDone)
    elseif next(machineCache) ~= nil then
      machineCache = {}
    end

    local count = 0
    for _, info in ipairs(rawSessions) do
      if count >= MAX_SESSIONS then
        break
      end
      if type(info) == "table" and validSessionName(info.name) then
        count = count + 1
        if info.running == true then
          pending = pending + 1
          local launched = noctalia.runAsync(snapshotCommand(info), function(snapshotResult)
            if generation ~= refreshGeneration then
              return
            end

            if snapshotResult.exitCode ~= 0 or snapshotResult.timedOut then
              table.insert(sessions, staleRow(info, failureReason(snapshotResult)))
              snapshotDone()
              return
            end

            local snapshotOut = snapshotResult.stdout or ""
            if #snapshotOut > MAX_SNAPSHOT_BYTES then
              table.insert(sessions, staleRow(info, noctalia.tr("error.snapshot_too_large")))
              snapshotDone()
              return
            end

            local snapshotJson = noctalia.json.decode(snapshotOut)
            local normalized, parseError = normalizeSnapshot(info, snapshotJson)
            if normalized == nil then
              table.insert(sessions, staleRow(info, parseError))
            else
              table.insert(sessions, normalized)
            end
            snapshotDone()
          end, COMMAND_TIMEOUT_MS)

          if not launched then
            table.insert(sessions, staleRow(info, noctalia.tr("error.command_failed")))
            pending = pending - 1
          end
        else
          table.insert(sessions, stoppedRow(info))
        end
      end
    end

    if pending == 0 then
      finishRefresh(generation, sessions)
    end
  end, COMMAND_TIMEOUT_MS)

  if not started then
    refreshInFlight = false
    state.refreshing = false
    state.error = noctalia.tr("error.command_failed")
    publish()
  end
end

local function setAction(status, sessionName, message)
  state.action = {
    status = status,
    session = sessionName,
    message = message,
  }
  publish()
end

local function setFocusAction(status, sessionName, message)
  -- Stop/delete and validation errors may finish while a picker is still open.
  -- Only the focus operation itself owns this lock.
  if status ~= "busy" then
    niriFocusInFlight = false
  end
  setAction(status, sessionName, message)
end

local function sessionRow(name)
  for _, session in ipairs(state.sessions or {}) do
    if session.name == name then
      return session
    end
  end
  return nil
end

local function runInHerdrTerminal(sessionName)
  local command = "herdr"
  if sessionName ~= "default" then
    command = "herdr --session " .. sessionName
  end

  if noctalia.runInTerminal(command) then
    setFocusAction("success", sessionName, noctalia.tr("action.opened"))
    refresh()
  else
    local reason = noctalia.tr("error.no_terminal")
    setFocusAction("error", sessionName, reason)
    noctalia.notifyError(noctalia.tr("notify.action_failed"), reason)
  end
end

local function luaString(value)
  local text = tostring(value or "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub('"', '\\"')
  text = text:gsub("\n", "\\n")
  text = text:gsub("\r", "\\r")
  text = text:gsub("\t", "\\t")
  return '"' .. text .. '"'
end

local function focusWindowOrOpen(sessionName, continuing)
  if useNiri() then
    if niriFocusInFlight and not continuing then
      return
    end
    niriFocusInFlight = true
    -- Re-resolve at click time: a terminal may have closed since the last poll.
    detectNiriWindows(function(windows, errorKey)
      local window = windows[sessionName]
      if errorKey ~= nil then
        local reason = noctalia.tr(errorKey)
        setFocusAction("error", sessionName, reason)
        noctalia.notifyError(noctalia.tr("notify.action_failed"), reason)
        return
      end
      local selected = niriSelectedWindows[sessionName]
      if selected ~= nil and (window == nil or not window.ids[selected]) then
        niriSelectedWindows[sessionName] = nil
      end
      if window ~= nil and window.ambiguous then
        local prompt = noctalia.tr("action.pick_window", { session = sessionName })
        setFocusAction("busy", sessionName, prompt)
        noctalia.notify(noctalia.tr("notify.pick_window"), prompt)
        local function pickFailed(key, detail)
          noctalia.log("HerdR Niri picker: " .. detail)
          local reason = noctalia.tr(key)
          setFocusAction("error", sessionName, reason)
          noctalia.notifyError(noctalia.tr("notify.action_failed"), reason)
        end
        local picking = noctalia.runAsync({ "niri", "msg", "--json", "pick-window" }, function(result)
          if result.timedOut or result.exitCode ~= 0 then
            pickFailed("error.niri_picker_failed", "exit=" .. tostring(result.exitCode)
              .. ", timedOut=" .. tostring(result.timedOut == true))
            return
          end
          -- Niri returns JSON null when Escape cancels the picker or a click
          -- does not select an application window. That is not a plugin error.
          local raw = trim(result.stdout)
          if raw == "null" then
            setFocusAction("cancelled", sessionName, noctalia.tr("action.selection_cancelled"))
            return
          end
          local picked = noctalia.json.decode(raw)
          local id = type(picked) == "table" and tonumber(picked.id) or nil
          local selected = id ~= nil and id >= 0 and id == math.floor(id)
            and id <= 9007199254740991 and string.format("%.0f", id) or nil
          if selected == nil then
            pickFailed("error.niri_picker_failed", "invalid selected-window response")
            return
          end
          -- Recheck against all live clients after the selection, not the
          -- potentially stale PID/window snapshot taken before it.
          detectNiriWindows(function(current, validationError)
            local candidates = current[sessionName]
            if validationError ~= nil then
              pickFailed(validationError, "could not revalidate selected window")
            elseif candidates == nil or not candidates.ids[selected] then
              noctalia.log("HerdR Niri picker: selected window is outside session candidates")
              setFocusAction("cancelled", sessionName, noctalia.tr("action.selection_cancelled"))
              noctalia.notify("Herdr", noctalia.tr("error.ambiguous_niri_window"))
            else
              niriSelectedWindows[sessionName] = selected
              focusWindowOrOpen(sessionName, true)
            end
          end)
        end, 60000)
        if not picking then
          pickFailed("error.niri_picker_failed", "could not start picker")
        end
        return
      end
      if window == nil then
        runInHerdrTerminal(sessionName)
        return
      end
      local function focusFailed()
        local reason = noctalia.tr("error.niri_focus_failed")
        setFocusAction("error", sessionName, reason)
        noctalia.notifyError(noctalia.tr("notify.action_failed"), reason)
      end
      local started = noctalia.runAsync(
        { "niri", "msg", "action", "focus-window", "--id", window.id },
        function(result)
          if result.exitCode == 0 and not result.timedOut then
            setFocusAction("success", sessionName, noctalia.tr("action.focused"))
            refresh()
          else
            -- Do not create duplicate terminals on an IPC error. Refresh/retry
            -- can discover whether the original window has since closed.
            focusFailed()
          end
        end,
        COMMAND_TIMEOUT_MS
      )
      if not started then
        focusFailed()
      end
    end)
    return
  end
  local row = sessionRow(sessionName)
  local window = type(row) == "table" and row.window or nil
  if type(window) ~= "table" or type(window.address) ~= "string"
    or window.address:match("^0x[%da-fA-F]+$") == nil then
    runInHerdrTerminal(sessionName)
    return
  end

  local function focusAddress()
    local expression = "hl.dsp.focus({ window = " .. luaString("address:" .. window.address) .. " })"
    local started = noctalia.runAsync(
      { "hyprctl", "dispatch", expression },
      function(result)
        if result.exitCode == 0 and not result.timedOut then
          setFocusAction("success", sessionName, noctalia.tr("action.focused"))
          refresh()
        else
          runInHerdrTerminal(sessionName)
        end
      end,
      COMMAND_TIMEOUT_MS
    )
    if not started then
      runInHerdrTerminal(sessionName)
    end
  end

  if type(window.workspace) == "string" and window.workspace ~= "" then
    local expression = "hl.dsp.focus({ workspace = " .. luaString(window.workspace) .. " })"
    local started = noctalia.runAsync(
      { "hyprctl", "dispatch", expression },
      function(result)
        if result.exitCode == 0 and not result.timedOut then
          focusAddress()
        else
          runInHerdrTerminal(sessionName)
        end
      end,
      COMMAND_TIMEOUT_MS
    )
    if not started then
      focusAddress()
    end
  else
    focusAddress()
  end
end

local function focusAgent(sessionName, pane)
  if useNiri() and niriFocusInFlight then
    return
  end
  if not validPaneId(pane) then
    setFocusAction("error", sessionName, noctalia.tr("error.invalid_target"))
    return
  end

  if useNiri() then
    niriFocusInFlight = true
  end

  local argv
  if sessionName == "default" then
    argv = { "herdr", "agent", "focus", pane }
  else
    argv = { "herdr", "--session", sessionName, "agent", "focus", pane }
  end

  setFocusAction("busy", sessionName, noctalia.tr("action.focusing"))
  local started = noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      local reason = failureReason(result)
      setFocusAction("error", sessionName, reason)
      noctalia.notifyError(noctalia.tr("notify.action_failed"), reason)
      refresh()
      return
    end
    focusWindowOrOpen(sessionName, true)
  end, COMMAND_TIMEOUT_MS)

  if not started then
    local reason = noctalia.tr("error.command_failed")
    setFocusAction("error", sessionName, reason)
    noctalia.notifyError(noctalia.tr("notify.action_failed"), reason)
  end
end

local function stopSession(sessionName)
  setAction("busy", sessionName, noctalia.tr("action.stopping"))
  local started = noctalia.runAsync(
    { "herdr", "session", "stop", sessionName, "--json" },
    function(result)
      if result.exitCode ~= 0 or result.timedOut then
        local reason = failureReason(result)
        setAction("error", sessionName, reason)
        noctalia.notifyError(noctalia.tr("notify.action_failed"), reason)
      else
        setAction("success", sessionName, noctalia.tr("action.stopped"))
      end
      refresh()
    end,
    STOP_TIMEOUT_MS
  )

  if not started then
    local reason = noctalia.tr("error.command_failed")
    setAction("error", sessionName, reason)
    noctalia.notifyError(noctalia.tr("notify.action_failed"), reason)
  end
end

local function deleteSession(sessionName)
  if sessionName == "default" then
    setAction("error", sessionName, noctalia.tr("error.default_delete"))
    return
  end

  setAction("busy", sessionName, noctalia.tr("action.deleting"))
  local started = noctalia.runAsync(
    { "herdr", "session", "delete", sessionName, "--json" },
    function(result)
      if result.exitCode ~= 0 or result.timedOut then
        local reason = failureReason(result)
        setAction("error", sessionName, reason)
        noctalia.notifyError(noctalia.tr("notify.action_failed"), reason)
      else
        setAction("success", sessionName, noctalia.tr("action.deleted"))
      end
      refresh()
    end,
    COMMAND_TIMEOUT_MS
  )

  if not started then
    local reason = noctalia.tr("error.command_failed")
    setAction("error", sessionName, reason)
    noctalia.notifyError(noctalia.tr("notify.action_failed"), reason)
  end
end

noctalia.state.watch("herdr.panel_open.attached", function(value)
  local wasOpen = panelOpen
  panelOpen = value == true
  updateInterval()
  if panelOpen and not wasOpen then
    refresh()
  end
end)

noctalia.state.watch("herdr.command", function(command)
  if type(command) ~= "table" then
    return
  end

  local action = command.action
  if niriFocusInFlight and (action == "focus_agent" or action == "open_session") then
    return
  end
  if action == "refresh" then
    state.action = nil
    publish()
    refresh()
    return
  end

  local sessionName = command.session
  if not validSessionName(sessionName) then
    setAction("error", tostring(sessionName or ""), noctalia.tr("error.invalid_session"))
    return
  end

  local row = sessionRow(sessionName)
  if row == nil and action ~= "open_session" then
    setAction("error", sessionName, noctalia.tr("error.session_disappeared"))
    refresh()
    return
  end

  if action == "open_session" then
    setFocusAction("busy", sessionName, noctalia.tr("action.opening"))
    focusWindowOrOpen(sessionName)
  elseif action == "focus_agent" then
    focusAgent(sessionName, command.pane)
  elseif action == "stop_session" and row.running == true then
    stopSession(sessionName)
  elseif action == "delete_session" and row.running ~= true then
    deleteSession(sessionName)
  end
end)

-- The bar widget owns the display settings and republishes them here, so a change
-- in the widget sheet has to rebuild the rows the panel is reading.
noctalia.state.watch("herdr.settings", function()
  refresh()
end)

function update()
  refresh()
end

function onConfigChanged()
  if noctalia.getConfig("show_other_machines") ~= true then
    machineCache = {}
  end
  refresh()
end

state.available = noctalia.commandExists("herdr")
state.hyprland_focus = noctalia.commandExists("hyprctl") and noctalia.commandExists("ps")
publish()
refresh()
