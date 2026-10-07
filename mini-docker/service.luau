--!nonstrict
-- Docker backend for Mini Docker. All other entries communicate with this
-- singleton through noctalia.state, keeping subprocess ownership in one place.

local snapshot = {
  available = false,
  loading = true,
  busy = false,
  containers = {},
  images = {},
  volumes = {},
  networks = {},
  runningCount = 0,
  error = "",
  updatedAt = 0,
  revision = 0,
}

local refreshGeneration = 0
local refreshPending = false
local refreshAgain = false
local actionBusy = false
local dataSignature = ""
local signatureParts = {}
local refreshAgainDetails = false
local detailsLoaded = false
local detailsStale = false

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function shellCommand(args)
  local quoted = {}
  for _, value in ipairs(args) do
    table.insert(quoted, shellQuote(value))
  end
  return table.concat(quoted, " ")
end

local function runDocker(args, callback, timeoutMs)
  local command = { "docker" }
  for _, value in ipairs(args) do
    table.insert(command, value)
  end
  return noctalia.runAsync(shellCommand(command), callback, timeoutMs or 30000)
end

-- Noctalia aborts a luau callback that exceeds its CPU budget (~40-70 decoded
-- rows), so rows are decoded a small batch per update() tick, never all in the
-- callback that received the output.
local DECODE_BATCH_ROWS = 25
local DECODE_TICK_MS = 50
local decodeQueue = {}

local function decodeLines(output, mapper, onDone)
  table.insert(decodeQueue, {
    nextLine = (tostring(output or "") .. "\n"):gmatch("(.-)\n"),
    mapper = mapper,
    onDone = onDone,
    rows = {},
  })
  noctalia.setUpdateInterval(DECODE_TICK_MS)
end

local function runDecodeBatch()
  local job = decodeQueue[1]
  local decodedRows = 0
  while decodedRows < DECODE_BATCH_ROWS do
    local line = job.nextLine()
    if line == nil then
      table.remove(decodeQueue, 1)
      job.onDone(job.rows)
      return
    end
    line = trim(line)
    if line ~= "" then
      decodedRows += 1
      local decoded, err = noctalia.json.decode(line)
      if type(decoded) == "table" then
        table.insert(job.rows, job.mapper(decoded))
      else
        noctalia.log(`mini-docker: ignored malformed Docker JSON: {err or "unknown error"}`)
      end
    end
  end
end

local function mapContainer(item)
  return {
    id = tostring(item.ID or ""),
    name = tostring(item.Names or ""),
    image = tostring(item.Image or ""),
    state = tostring(item.State or "unknown"),
    status = tostring(item.Status or ""),
    ports = tostring(item.Ports or ""),
    created = tostring(item.CreatedAt or ""),
  }
end

local function mapImage(item)
  local repository = tostring(item.Repository or "<none>")
  local tag = tostring(item.Tag or "latest")
  return {
    repository = repository,
    tag = tag,
    name = repository .. ":" .. tag,
    id = tostring(item.ID or ""),
    size = tostring(item.Size or ""),
    created = tostring(item.CreatedAt or ""),
    isRunning = false,
  }
end

local function mapVolume(item)
  return {
    name = tostring(item.Name or ""),
    driver = tostring(item.Driver or ""),
    mountpoint = tostring(item.Mountpoint or ""),
  }
end

local function mapNetwork(item)
  local name = tostring(item.Name or "")
  return {
    name = name,
    id = tostring(item.ID or ""),
    driver = tostring(item.Driver or ""),
    scope = tostring(item.Scope or ""),
    isDefault = name == "bridge" or name == "host" or name == "none",
  }
end

local function markRunningImages(images, containers)
  for _, image in ipairs(images) do
    for _, container in ipairs(containers) do
      if container.image == image.name
        or container.image == image.repository
        or container.image == image.id
        or image.id:sub(1, 12) == container.image then
        -- Docker refuses to remove an image referenced by stopped containers too.
        image.isRunning = true
        break
      end
    end
  end
end

local function publishSnapshot()
  snapshot.busy = actionBusy
  noctalia.state.set("docker_snapshot", snapshot)
end

local function updateRevision(signature)
  if signature ~= dataSignature then
    dataSignature = signature
    snapshot.revision += 1
  end
end

local function refreshIntervalMs()
  local seconds = tonumber(noctalia.getConfig("refresh_interval")) or 5
  seconds = math.max(1, math.min(30, math.floor(seconds)))
  return seconds * 1000
end

local refreshAll

-- The bar widget only needs the container list, so the periodic refresh skips
-- images/volumes/networks; `withDetails` (panel open, manual refresh, after an
-- action) also loads them.
refreshAll = function(withDetails)
  withDetails = withDetails == true or detailsStale
  if refreshPending then
    refreshAgain = true
    refreshAgainDetails = refreshAgainDetails or withDetails
    return
  end

  refreshPending = true
  refreshAgain = false
  refreshAgainDetails = false
  refreshGeneration += 1
  local generation = refreshGeneration

  if not noctalia.commandExists("docker") then
    snapshot.available = false
    snapshot.loading = false
    snapshot.error = noctalia.tr("result.docker_missing")
    snapshot.containers = {}
    snapshot.images = {}
    snapshot.volumes = {}
    snapshot.networks = {}
    snapshot.runningCount = 0
    detailsStale = detailsStale or detailsLoaded
    detailsLoaded = false
    refreshPending = false
    updateRevision("docker-missing:" .. snapshot.error)
    publishSnapshot()
    return
  end

  snapshot.loading = true
  publishSnapshot()

  local containers = {}
  local details = {}

  local function recordResult(kind, result)
    signatureParts[kind] = table.concat({
      tostring(result and result.exitCode or -1),
      tostring(result and result.stdout or ""),
      tostring(result and result.stderr or ""),
    }, "\0")
  end

  local function finish(containerResult)
    if generation ~= refreshGeneration then
      return
    end
    if containerResult == nil or containerResult.exitCode ~= 0 then
      snapshot.available = false
      snapshot.error = trim(containerResult and containerResult.stderr)
      if snapshot.error == "" then
        snapshot.error = noctalia.tr("result.docker_unreachable")
      end
      snapshot.containers = {}
      snapshot.images = {}
      snapshot.volumes = {}
      snapshot.networks = {}
      snapshot.runningCount = 0
      detailsStale = detailsStale or detailsLoaded
      detailsLoaded = false
    else
      local runningCount = 0
      for _, container in ipairs(containers) do
        if container.state == "running" then
          runningCount += 1
        end
      end
      if withDetails then
        local images = details.images or {}
        markRunningImages(images, containers)
        snapshot.images = images
        snapshot.volumes = details.volumes or {}
        snapshot.networks = details.networks or {}
        detailsLoaded = true
        detailsStale = false
      end
      snapshot.available = true
      snapshot.error = ""
      snapshot.containers = containers
      snapshot.runningCount = runningCount
      snapshot.updatedAt = os.time()
    end

    snapshot.loading = false
    refreshPending = false
    updateRevision(table.concat({
      signatureParts.containers or "",
      signatureParts.images or "",
      signatureParts.volumes or "",
      signatureParts.networks or "",
    }, "\1"))
    publishSnapshot()
    if refreshAgain then
      refreshAll(refreshAgainDetails)
    end
  end

  local function launch(kind, args, callback)
    local started = runDocker(args, function(result)
      if generation ~= refreshGeneration then return end
      recordResult(kind, result)
      callback(result)
    end)
    if not started then
      local result = { exitCode = -1, stdout = "", stderr = "could not start Docker", timedOut = false }
      recordResult(kind, result)
      callback(result)
    end
  end

  local function decode(output, mapper, callback)
    decodeLines(output, mapper, function(rows)
      if generation ~= refreshGeneration then return end
      callback(rows)
    end)
  end

  local detailSteps = {
    { kind = "images", args = { "images", "--format", "{{json .}}" }, mapper = mapImage },
    { kind = "volumes", args = { "volume", "ls", "--format", "{{json .}}" }, mapper = mapVolume },
    { kind = "networks", args = { "network", "ls", "--format", "{{json .}}" }, mapper = mapNetwork },
  }

  local function runDetailStep(containerResult, index)
    local step = detailSteps[index]
    if step == nil then
      finish(containerResult)
      return
    end
    launch(step.kind, step.args, function(result)
      if result.exitCode ~= 0 then
        runDetailStep(containerResult, index + 1)
        return
      end
      decode(result.stdout, step.mapper, function(rows)
        details[step.kind] = rows
        runDetailStep(containerResult, index + 1)
      end)
    end)
  end

  launch("containers", { "ps", "-a", "--format", "{{json .}}" }, function(containerResult)
    if containerResult.exitCode ~= 0 then
      finish(containerResult)
      return
    end
    decode(containerResult.stdout, mapContainer, function(rows)
      containers = rows
      if withDetails then
        runDetailStep(containerResult, 1)
      else
        finish(containerResult)
      end
    end)
  end)
end

local function actionResult(command, ok, message, extra)
  local result = {
    requestId = command.requestId,
    action = command.action,
    ok = ok,
    message = message or "",
  }
  if type(extra) == "table" then
    for key, value in pairs(extra) do
      result[key] = value
    end
  end
  noctalia.state.set("docker_action_result", result)
end

local function finishAction(command, result)
  actionBusy = false
  local ok = result ~= nil and result.exitCode == 0 and not result.timedOut
  local message = trim(ok and result.stdout or (result and result.stderr))
  if message == "" then
    message = ok and noctalia.tr("result.success") or noctalia.tr("result.failed", { error = "unknown error" })
  end
  actionResult(command, ok, message)
  if ok then
    noctalia.notify(noctalia.tr("title"), message)
  else
    noctalia.notifyError(noctalia.tr("title"), message)
  end
  publishSnapshot()
  refreshAll(detailsLoaded)
end

local function validContainerName(name)
  return name == "" or name:match("^[%w][%w_.-]*$") ~= nil
end

local function validPort(port)
  local number = tonumber(port)
  return number ~= nil and number >= 1 and number <= 65535 and math.floor(number) == number
end

local function inspectImage(command)
  if actionBusy then
    actionResult(command, false, noctalia.tr("result.command_busy"))
    return
  end
  actionBusy = true
  publishSnapshot()
  local started = runDocker({ "image", "inspect", "--format", "{{json .Config.ExposedPorts}}", tostring(command.image or "") }, function(result)
    actionBusy = false
    local port = nil
    if result and result.exitCode == 0 then
      local decoded = noctalia.json.decode(trim(result.stdout))
      if type(decoded) == "table" then
        for key in pairs(decoded) do
          port = tostring(key):match("^(%d+)/")
          if port ~= nil then
            break
          end
        end
      end
    end
    actionResult(command, result ~= nil and result.exitCode == 0, trim(result and result.stderr), { exposedPort = port })
    publishSnapshot()
  end)
  if not started then
    actionBusy = false
    actionResult(command, false, "could not start Docker")
    publishSnapshot()
  end
end

local function executeAction(command)
  if type(command) ~= "table" or type(command.action) ~= "string" then
    return
  end
  if command.action == "refresh" then
    refreshAll(command.details == true)
    return
  end
  if command.action == "inspect_image" then
    inspectImage(command)
    return
  end
  if actionBusy then
    actionResult(command, false, noctalia.tr("result.command_busy"))
    return
  end

  local args = nil
  if command.action == "start_container" then
    args = { "start", tostring(command.id or "") }
  elseif command.action == "stop_container" then
    args = { "stop", tostring(command.id or "") }
  elseif command.action == "restart_container" then
    args = { "restart", tostring(command.id or "") }
  elseif command.action == "remove_container" then
    args = { "rm", tostring(command.id or "") }
  elseif command.action == "remove_image" then
    args = { "rmi", tostring(command.id or "") }
  elseif command.action == "remove_volume" then
    args = { "volume", "rm", tostring(command.name or "") }
  elseif command.action == "remove_network" then
    local name = tostring(command.name or "")
    if name == "bridge" or name == "host" or name == "none" then
      actionResult(command, false, noctalia.tr("panel.default_network"))
      return
    end
    args = { "network", "rm", tostring(command.id or "") }
  elseif command.action == "run_image" then
    local image = trim(command.image)
    local name = trim(command.name)
    local network = trim(command.network)
    local port = trim(command.port)
    if image == "" then
      actionResult(command, false, noctalia.tr("result.failed", { error = "missing image" }))
      return
    end
    if not validContainerName(name) then
      actionResult(command, false, noctalia.tr("run_form.invalid_name"))
      return
    end
    if port ~= "" and not validPort(port) then
      actionResult(command, false, noctalia.tr("run_form.invalid_port"))
      return
    end
    args = { "run", "-d" }
    if name ~= "" then
      table.insert(args, "--name")
      table.insert(args, name)
    end
    if type(command.environment) == "table" then
      for _, env in ipairs(command.environment) do
        local key = tostring(env):match("^([^=]+)=") or ""
        if key:match("^[A-Za-z_][A-Za-z0-9_]*$") == nil then
          actionResult(command, false, noctalia.tr("run_form.invalid_environment", { line = tostring(env) }))
          return
        end
        table.insert(args, "-e")
        table.insert(args, tostring(env))
      end
    end
    if port ~= "" then
      table.insert(args, "-p")
      table.insert(args, port .. ":" .. port)
    end
    if network ~= "" and network ~= "bridge" then
      table.insert(args, "--network")
      table.insert(args, network)
    end
    table.insert(args, image)
  end

  if args == nil then
    actionResult(command, false, `Unknown Docker action: {command.action}`)
    return
  end

  actionBusy = true
  publishSnapshot()
  local launched = runDocker(args, function(result) finishAction(command, result) end, 60000)
  if not launched then
    actionBusy = false
    actionResult(command, false, noctalia.tr("result.failed", { error = "could not start Docker" }))
    publishSnapshot()
  end
end

noctalia.state.watch("docker_command", executeAction)
noctalia.setUpdateInterval(refreshIntervalMs())
refreshAll()

function update()
  if #decodeQueue > 0 then
    runDecodeBatch()
    if #decodeQueue == 0 then
      noctalia.setUpdateInterval(refreshIntervalMs())
    end
    return
  end
  refreshAll()
end

function onConfigChanged()
  if #decodeQueue == 0 then
    noctalia.setUpdateInterval(refreshIntervalMs())
  end
  refreshAll()
end

function onIpc(event, _payload)
  if event == "refresh" then
    refreshAll(detailsLoaded)
  end
end
