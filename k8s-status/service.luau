--!nonstrict
-- Kubernetes status backend: nodes, pods, deployments via kubectl.

local STATE_KEY = "k8s_snapshot"
local COMMAND_KEY = "k8s_command"
local RESULT_KEY = "k8s_action_result"

local snapshot = {
  available = false,
  loading = true,
  busy = false,
  context = "",
  nodes = {},
  pods = {},
  deployments = {},
  namespaces = {},
  readyNodes = 0,
  nodeCount = 0,
  problemPods = 0,
  podCount = 0,
  deployCount = 0,
  error = "",
  updatedAt = 0,
  revision = 0,
}

local refreshGeneration = 0
local refreshPending = false
local refreshAgain = false
local refreshStartedAt = 0
local actionBusy = false
local dataSignature = ""
local prevNotReady = {} -- name -> true
local STUCK_REFRESH_SEC = 90

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

local function expand(path)
  return noctalia.expandPath(trim(path))
end

local function kubectlBin()
  local bin = trim(noctalia.getConfig("kubectl_bin"))
  if bin == "" then
    return "kubectl"
  end
  return bin
end

local function refreshIntervalMs()
  local seconds = tonumber(noctalia.getConfig("refresh_interval")) or 15
  seconds = math.max(5, math.min(120, math.floor(seconds)))
  return seconds * 1000
end

local function baseKubectlArgs()
  local args = { kubectlBin() }
  local kubeconfig = trim(noctalia.getConfig("kubeconfig"))
  if kubeconfig ~= "" then
    table.insert(args, "--kubeconfig")
    table.insert(args, expand(kubeconfig))
  end
  local context = trim(noctalia.getConfig("context"))
  if context ~= "" then
    table.insert(args, "--context")
    table.insert(args, context)
  end
  return args
end

local function nsArgs(args)
  local ns = trim(noctalia.getConfig("namespace"))
  if ns ~= "" then
    table.insert(args, "-n")
    table.insert(args, ns)
  else
    table.insert(args, "-A")
  end
  return args
end

local function nowSec()
  if type(noctalia.nowMs) == "function" then
    local ms = noctalia.nowMs()
    if type(ms) == "number" and ms > 0 then
      return math.floor(ms / 1000)
    end
  end
  return os.time()
end

local function runKubectl(args, callback, timeoutMs)
  local cmd = shellCommand(args)
  local started = noctalia.runAsync(cmd, function(result)
    if type(callback) == "function" then
      local ok, err = pcall(callback, result)
      if not ok then
        noctalia.log(`k8s-status: kubectl callback failed: {tostring(err)}`)
      end
    end
  end, timeoutMs or 45000)
  if not started and type(callback) == "function" then
    -- Ensure callers always get a callback so refresh cannot hang forever.
    callback({
      exitCode = -1,
      stdout = "",
      stderr = "could not start kubectl",
      timedOut = false,
    })
  end
  return started
end

local function updateRevision(signature)
  if signature ~= dataSignature then
    dataSignature = signature
    snapshot.revision += 1
  end
end

local function publishSnapshot()
  snapshot.busy = actionBusy
  noctalia.state.set(STATE_KEY, snapshot)
end

local function actionResult(command, ok, message, extra)
  local result = {
    requestId = command and command.requestId or "",
    action = command and command.action or "",
    ok = ok,
    message = message or "",
  }
  if type(extra) == "table" then
    for key, value in pairs(extra) do
      result[key] = value
    end
  end
  noctalia.state.set(RESULT_KEY, result)
end

local function notifyOk(message)
  noctalia.notify(noctalia.tr("title"), message)
end

local function notifyErr(message)
  noctalia.notifyError(noctalia.tr("title"), message)
end

local function isProblemPhase(phase)
  phase = tostring(phase or "")
  if phase == "Running" or phase == "Succeeded" or phase == "Completed" then
    return false
  end
  return true
end

local function parseReady(ready)
  -- "1/1" or "0/1"
  local have, want = tostring(ready or ""):match("^(%d+)/(%d+)$")
  if have and want then
    return tonumber(have) or 0, tonumber(want) or 0
  end
  return 0, 0
end

-- jsonpath with tab separators (reliable under shell quoting)
-- Use plain strings so shell quoting of jsonpath=... stays simple.
local NODE_JSONPATH = '{range .items[*]}{.metadata.name}{"|"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"|"}{.status.nodeInfo.kubeletVersion}{"|"}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{end}{"\\n"}{end}'

local DEPLOY_JSONPATH = '{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.status.readyReplicas}{"|"}{.status.replicas}{"|"}{.status.availableReplicas}{"\\n"}{end}'

local NS_JSONPATH = '{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"\\n"}{end}'

local function splitLines(text)
  local lines = {}
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    line = trim(line)
    if line ~= "" then
      table.insert(lines, line)
    end
  end
  return lines
end

local function splitFields(line)
  local parts = {}
  -- prefer pipe separators from jsonpath; fall back to tabs
  local sep = line:find("|", 1, true) and "|" or "\t"
  for part in (line .. sep):gmatch("(.-)" .. (sep == "|" and "|" or "\t")) do
    table.insert(parts, part)
  end
  return parts
end

local function parseNodes(stdout)
  local nodes = {}
  for _, line in ipairs(splitLines(stdout)) do
    local parts = splitFields(line)
    local name = parts[1] or ""
    local readyRaw = parts[2] or ""
    local version = parts[3] or ""
    local ip = parts[4] or ""
    local ready = readyRaw == "True"
    if name ~= "" then
      table.insert(nodes, {
        id = name,
        name = name,
        ready = ready,
        status = ready and "Ready" or "NotReady",
        version = version,
        ip = ip,
        roles = "",
      })
    end
  end
  table.sort(nodes, function(a, b)
    return a.name < b.name
  end)
  return nodes
end

local function parsePodsWide(stdout)
  -- fallback parser for: kubectl get pods -A --no-headers
  -- NS NAME READY STATUS RESTARTS AGE [NODE ...]
  local pods = {}
  for _, line in ipairs(splitLines(stdout)) do
    local fields = {}
    for f in line:gmatch("%S+") do
      table.insert(fields, f)
    end
    if #fields >= 5 then
      local ns = fields[1]
      local name = fields[2]
      local ready = fields[3]
      local status = fields[4]
      local restarts = fields[5]
      -- if restarts looks like "(", merge
      local idx = 6
      if restarts:match("^%d+$") and fields[6] and fields[6]:match("^%(") then
        -- skip age tokens that are part of restart age? actually format is:
        -- restarts can be "0" or "6" then "(20d" "ago)" then AGE
        -- get pods: RESTARTS is one column "6 (20d ago)" in wide? default is single token or with paren
        while fields[idx] and not fields[idx]:match("^%d+[dhms]") and fields[idx] ~= "<none>" and idx < #fields do
          if fields[idx]:match("^%(") or fields[idx]:match("ago%)") or fields[idx] == "ago)" then
            idx += 1
          else
            break
          end
        end
      end
      -- after restarts comes AGE then optional NODE for -o wide
      local age = fields[idx] or ""
      local node = fields[idx + 1] or ""
      local have, want = parseReady(ready)
      local restartsNum = tonumber((restarts:match("^(%d+)"))) or 0
      local problem = isProblemPhase(status) or (want > 0 and have < want) or restartsNum > 5
      table.insert(pods, {
        id = ns .. "/" .. name,
        namespace = ns,
        name = name,
        ready = ready,
        readyHave = have,
        readyWant = want,
        status = status,
        restarts = restartsNum,
        age = age,
        node = node,
        problem = problem,
      })
    end
  end
  return pods
end

local function parsePodsSimple(stdout)
  local pods = {}
  for _, line in ipairs(splitLines(stdout)) do
    local parts = splitFields(line)
    local ns = parts[1] or ""
    local name = parts[2] or ""
    local phase = parts[3] or ""
    local node = parts[4] or ""
    if ns ~= "" and name ~= "" then
      local problem = isProblemPhase(phase)
      table.insert(pods, {
        id = ns .. "/" .. name,
        namespace = ns,
        name = name,
        ready = problem and "0/?" or "?/?",
        readyHave = 0,
        readyWant = 0,
        status = phase,
        restarts = 0,
        age = "",
        node = node,
        problem = problem,
      })
    end
  end
  return pods
end

local function parseDeploys(stdout)
  local items = {}
  for _, line in ipairs(splitLines(stdout)) do
    local parts = splitFields(line)
    local ns = parts[1] or ""
    local name = parts[2] or ""
    -- jsonpath may emit empty fields for nil replicas
    local ready = tonumber(parts[3]) or 0
    local desired = tonumber(parts[4]) or 0
    local available = tonumber(parts[5]) or 0
    if ns ~= "" and name ~= "" then
      local problem = desired > 0 and ready < desired
      table.insert(items, {
        id = ns .. "/" .. name,
        namespace = ns,
        name = name,
        ready = ready,
        desired = desired,
        available = available,
        problem = problem,
      })
    end
  end
  table.sort(items, function(a, b)
    if a.problem ~= b.problem then
      return a.problem
    end
    if a.namespace == b.namespace then
      return a.name < b.name
    end
    return a.namespace < b.namespace
  end)
  return items
end

local function parseNamespaces(stdout)
  local items = {}
  for _, line in ipairs(splitLines(stdout)) do
    local parts = splitFields(line)
    local name = parts[1] or ""
    local phase = parts[2] or ""
    if name ~= "" then
      table.insert(items, { id = name, name = name, phase = phase })
    end
  end
  table.sort(items, function(a, b)
    return a.name < b.name
  end)
  return items
end

local function checkNotReadyNotifications(nodes)
  if noctalia.getConfig("notify_on_not_ready") == false then
    return
  end
  local current = {}
  for _, node in ipairs(nodes) do
    if not node.ready then
      current[node.name] = true
      if not prevNotReady[node.name] then
        notifyErr(noctalia.tr("result.node_not_ready", { name = node.name }))
      end
    end
  end
  prevNotReady = current
end

local refreshAll

local function forceUnstick(reason)
  noctalia.log(`k8s-status: {reason}`)
  refreshPending = false
  refreshStartedAt = 0
  snapshot.loading = false
  if snapshot.error == "" and not snapshot.available then
    snapshot.error = reason
  end
  publishSnapshot()
end

refreshAll = function()
  -- Recover from hung refreshes (callback never fired / stuck pending).
  if refreshPending and refreshStartedAt > 0 and (nowSec() - refreshStartedAt) >= STUCK_REFRESH_SEC then
    forceUnstick("refresh timed out")
  end
  if refreshPending then
    refreshAgain = true
    return
  end
  refreshPending = true
  refreshAgain = false
  refreshStartedAt = nowSec()
  refreshGeneration += 1
  local generation = refreshGeneration

  if not noctalia.commandExists(kubectlBin()) then
    snapshot.available = false
    snapshot.loading = false
    snapshot.error = noctalia.tr("result.kubectl_missing")
    snapshot.nodes = {}
    snapshot.pods = {}
    snapshot.deployments = {}
    snapshot.namespaces = {}
    snapshot.readyNodes = 0
    snapshot.nodeCount = 0
    snapshot.problemPods = 0
    snapshot.podCount = 0
    snapshot.deployCount = 0
    refreshPending = false
    refreshStartedAt = 0
    updateRevision("kubectl-missing")
    publishSnapshot()
    return
  end

  -- Only show "Querying cluster…" when we have never loaded data.
  if not snapshot.available then
    snapshot.loading = true
    publishSnapshot()
  end

  local function doneRefresh()
    if generation ~= refreshGeneration then
      return
    end
    refreshPending = false
    refreshStartedAt = 0
    if refreshAgain then
      refreshAgain = false
      refreshAll()
    end
  end

  local function fail(err)
    if generation ~= refreshGeneration then
      return
    end
    snapshot.available = false
    snapshot.loading = false
    snapshot.error = trim(err) ~= "" and trim(err) or noctalia.tr("result.unreachable")
    updateRevision("err:" .. snapshot.error)
    publishSnapshot()
    doneRefresh()
  end

  local function applySuccess(ctx, nodes, pods, deploys, namespaces)
    if generation ~= refreshGeneration then
      return
    end
    local readyCount = 0
    for _, n in ipairs(nodes) do
      if n.ready then
        readyCount += 1
      end
    end
    local problemCount = 0
    for _, p in ipairs(pods) do
      if p.problem then
        problemCount += 1
      end
    end
    pcall(checkNotReadyNotifications, nodes)

    snapshot.available = true
    snapshot.loading = false
    snapshot.error = ""
    snapshot.context = ctx or ""
    snapshot.nodes = nodes
    snapshot.pods = pods
    snapshot.deployments = deploys
    snapshot.namespaces = namespaces
    snapshot.readyNodes = readyCount
    snapshot.nodeCount = #nodes
    snapshot.problemPods = problemCount
    snapshot.podCount = #pods
    snapshot.deployCount = #deploys
    snapshot.updatedAt = nowSec()

    updateRevision(table.concat({
      snapshot.context,
      tostring(readyCount),
      tostring(#nodes),
      tostring(problemCount),
      tostring(#pods),
      tostring(#deploys),
    }, "|"))
    publishSnapshot()
    doneRefresh()
  end

  -- Parallel queries (pending counter) — avoids deep nesting and partial hangs.
  local bag = {
    context = "",
    nodesOut = nil,
    nodesErr = nil,
    podsOut = "",
    deploysOut = "",
    nsOut = "",
  }
  local pending = 5
  local finished = false

  local function finishOne()
    if generation ~= refreshGeneration or finished then
      return
    end
    pending -= 1
    if pending > 0 then
      return
    end
    finished = true

    if bag.nodesOut == nil then
      fail(bag.nodesErr or "nodes failed")
      return
    end

    local okN, nodesOrErr = pcall(parseNodes, bag.nodesOut)
    local nodes = (okN and nodesOrErr) or {}
    if not okN then
      noctalia.log(`k8s-status: parseNodes: {tostring(nodesOrErr)}`)
      nodes = {}
    end

    local pods = {}
    local okP, podsOrErr = pcall(parsePodsWide, bag.podsOut)
    if okP and type(podsOrErr) == "table" then
      pods = podsOrErr
    elseif not okP then
      noctalia.log(`k8s-status: parsePods: {tostring(podsOrErr)}`)
    end
    table.sort(pods, function(a, b)
      if a.problem ~= b.problem then
        return a.problem
      end
      if a.namespace == b.namespace then
        return a.name < b.name
      end
      return a.namespace < b.namespace
    end)

    local deploys = {}
    local okD, depOrErr = pcall(parseDeploys, bag.deploysOut)
    if okD and type(depOrErr) == "table" then
      deploys = depOrErr
    end

    local namespaces = {}
    local okNs, nsOrErr = pcall(parseNamespaces, bag.nsOut)
    if okNs and type(nsOrErr) == "table" then
      namespaces = nsOrErr
    end

    applySuccess(bag.context, nodes, pods, deploys, namespaces)
  end

  -- context
  local ctxArgs = baseKubectlArgs()
  table.insert(ctxArgs, "config")
  table.insert(ctxArgs, "current-context")
  runKubectl(ctxArgs, function(ctxResult)
    if generation ~= refreshGeneration then
      return
    end
    if ctxResult and ctxResult.exitCode == 0 then
      bag.context = trim(ctxResult.stdout)
    else
      local configured = trim(noctalia.getConfig("context"))
      bag.context = configured ~= "" and configured or ""
    end
    finishOne()
  end, 15000)

  -- nodes (required)
  local nodeArgs = baseKubectlArgs()
  table.insert(nodeArgs, "get")
  table.insert(nodeArgs, "nodes")
  table.insert(nodeArgs, "-o")
  table.insert(nodeArgs, "jsonpath=" .. NODE_JSONPATH)
  runKubectl(nodeArgs, function(nodeResult)
    if generation ~= refreshGeneration then
      return
    end
    if nodeResult and nodeResult.exitCode == 0 and not nodeResult.timedOut then
      bag.nodesOut = nodeResult.stdout or ""
    else
      local err = ""
      if nodeResult then
        err = trim(nodeResult.stderr)
        if err == "" then
          err = trim(nodeResult.stdout)
        end
        if nodeResult.timedOut then
          err = err ~= "" and err or "nodes timed out"
        end
      end
      bag.nodesErr = err ~= "" and err or "nodes failed"
      bag.nodesOut = nil
    end
    finishOne()
  end, 30000)

  -- pods
  local podArgs = baseKubectlArgs()
  table.insert(podArgs, "get")
  table.insert(podArgs, "pods")
  nsArgs(podArgs)
  table.insert(podArgs, "--no-headers")
  runKubectl(podArgs, function(podResult)
    if generation ~= refreshGeneration then
      return
    end
    if podResult and podResult.exitCode == 0 then
      bag.podsOut = podResult.stdout or ""
    end
    finishOne()
  end, 45000)

  -- deployments
  local deployArgs = baseKubectlArgs()
  table.insert(deployArgs, "get")
  table.insert(deployArgs, "deploy")
  nsArgs(deployArgs)
  table.insert(deployArgs, "-o")
  table.insert(deployArgs, "jsonpath=" .. DEPLOY_JSONPATH)
  runKubectl(deployArgs, function(deployResult)
    if generation ~= refreshGeneration then
      return
    end
    if deployResult and deployResult.exitCode == 0 then
      bag.deploysOut = deployResult.stdout or ""
    end
    finishOne()
  end, 30000)

  -- namespaces
  local nsArgsList = baseKubectlArgs()
  table.insert(nsArgsList, "get")
  table.insert(nsArgsList, "ns")
  table.insert(nsArgsList, "-o")
  table.insert(nsArgsList, "jsonpath=" .. NS_JSONPATH)
  runKubectl(nsArgsList, function(nsResult)
    if generation ~= refreshGeneration then
      return
    end
    if nsResult and nsResult.exitCode == 0 then
      bag.nsOut = nsResult.stdout or ""
    end
    finishOne()
  end, 20000)
end

local function finishAction(command, ok, message)
  actionBusy = false
  actionResult(command, ok, message)
  if ok then
    notifyOk(message)
  else
    notifyErr(message)
  end
  publishSnapshot()
  refreshAll()
end

local function resourceRef(command)
  local ns = trim(command.namespace)
  local name = trim(command.name)
  return ns, name
end

local function openInTerminal(cmd)
  noctalia.runInTerminal(cmd)
end

local function kubectlPrefixShell()
  local parts = baseKubectlArgs()
  return table.concat(parts, " ") -- already will be used carefully
end

local function describeResource(command)
  local kind = trim(command.kind)
  local ns, name = resourceRef(command)
  if name == "" then
    actionResult(command, false, noctalia.tr("result.failed", { error = "missing name" }))
    return
  end
  local args = baseKubectlArgs()
  table.insert(args, "describe")
  table.insert(args, kind)
  table.insert(args, name)
  if ns ~= "" and kind ~= "node" and kind ~= "namespace" then
    table.insert(args, "-n")
    table.insert(args, ns)
  end
  -- keep terminal open with less/pager
  local cmd = shellCommand(args) .. " | less -R"
  openInTerminal(cmd)
  actionResult(command, true, noctalia.tr("result.describe_started", { name = name }))
end

local function logsPod(command)
  local ns, name = resourceRef(command)
  if name == "" or ns == "" then
    actionResult(command, false, noctalia.tr("result.failed", { error = "missing pod" }))
    return
  end
  local args = baseKubectlArgs()
  table.insert(args, "logs")
  table.insert(args, "-n")
  table.insert(args, ns)
  table.insert(args, name)
  table.insert(args, "--tail=200")
  table.insert(args, "-f")
  openInTerminal(shellCommand(args))
  actionResult(command, true, noctalia.tr("result.logs_started", { name = name }))
end

local function deletePod(command)
  if actionBusy then
    actionResult(command, false, noctalia.tr("result.busy"))
    return
  end
  local ns, name = resourceRef(command)
  if name == "" or ns == "" then
    actionResult(command, false, noctalia.tr("result.failed", { error = "missing pod" }))
    return
  end
  local args = baseKubectlArgs()
  table.insert(args, "delete")
  table.insert(args, "pod")
  table.insert(args, name)
  table.insert(args, "-n")
  table.insert(args, ns)
  actionBusy = true
  publishSnapshot()
  runKubectl(args, function(result)
    local ok = result ~= nil and result.exitCode == 0
    if ok then
      finishAction(command, true, noctalia.tr("result.deleted", { name = ns .. "/" .. name }))
    else
      local err = trim(result and result.stderr or "")
      finishAction(command, false, noctalia.tr("result.failed", { error = err ~= "" and err or "delete failed" }))
    end
  end, 60000)
end

local function restartDeploy(command)
  if actionBusy then
    actionResult(command, false, noctalia.tr("result.busy"))
    return
  end
  local ns, name = resourceRef(command)
  if name == "" or ns == "" then
    actionResult(command, false, noctalia.tr("result.failed", { error = "missing deploy" }))
    return
  end
  local args = baseKubectlArgs()
  table.insert(args, "rollout")
  table.insert(args, "restart")
  table.insert(args, "deploy/" .. name)
  table.insert(args, "-n")
  table.insert(args, ns)
  actionBusy = true
  publishSnapshot()
  runKubectl(args, function(result)
    local ok = result ~= nil and result.exitCode == 0
    if ok then
      finishAction(command, true, noctalia.tr("result.restarted", { name = ns .. "/" .. name }))
    else
      local err = trim(result and result.stderr or "")
      finishAction(command, false, noctalia.tr("result.failed", { error = err ~= "" and err or "restart failed" }))
    end
  end, 60000)
end

local function openK9s(command)
  if not noctalia.commandExists("k9s") then
    actionResult(command, false, noctalia.tr("result.failed", { error = "k9s not found" }))
    notifyErr(noctalia.tr("result.failed", { error = "k9s not found" }))
    return
  end
  local args = { "k9s" }
  local kubeconfig = trim(noctalia.getConfig("kubeconfig"))
  if kubeconfig ~= "" then
    table.insert(args, "--kubeconfig")
    table.insert(args, expand(kubeconfig))
  end
  local context = trim(noctalia.getConfig("context"))
  if context ~= "" then
    table.insert(args, "--context")
    table.insert(args, context)
  end
  local ns = trim(command.namespace or noctalia.getConfig("namespace") or "")
  if ns ~= "" then
    table.insert(args, "-n")
    table.insert(args, ns)
  end
  openInTerminal(shellCommand(args))
  actionResult(command, true, noctalia.tr("result.k9s_started"))
end

local function shellPod(command)
  local ns, name = resourceRef(command)
  if name == "" or ns == "" then
    actionResult(command, false, noctalia.tr("result.failed", { error = "missing pod" }))
    return
  end
  local args = baseKubectlArgs()
  table.insert(args, "exec")
  table.insert(args, "-it")
  table.insert(args, "-n")
  table.insert(args, ns)
  table.insert(args, name)
  table.insert(args, "--")
  table.insert(args, "sh")
  table.insert(args, "-c")
  table.insert(args, "command -v bash >/dev/null && exec bash || exec sh")
  openInTerminal(shellCommand(args))
  actionResult(command, true, noctalia.tr("result.shell_started", { name = ns .. "/" .. name }))
end

local function portForwardPod(command)
  local ns, name = resourceRef(command)
  local ports = trim(command.ports)
  if name == "" or ns == "" then
    actionResult(command, false, noctalia.tr("result.failed", { error = "missing pod" }))
    return
  end
  if ports == "" then
    ports = "8080:8080"
  end
  local args = baseKubectlArgs()
  table.insert(args, "port-forward")
  table.insert(args, "-n")
  table.insert(args, ns)
  table.insert(args, "pod/" .. name)
  table.insert(args, ports)
  openInTerminal(shellCommand(args))
  actionResult(command, true, noctalia.tr("result.portforward_started", { name = ns .. "/" .. name, ports = ports }))
end

local function getYaml(command)
  local kind = trim(command.kind)
  local ns, name = resourceRef(command)
  if name == "" then
    actionResult(command, false, noctalia.tr("result.failed", { error = "missing name" }))
    return
  end
  local args = baseKubectlArgs()
  table.insert(args, "get")
  table.insert(args, kind)
  table.insert(args, name)
  if ns ~= "" and kind ~= "node" and kind ~= "namespace" and kind ~= "ns" then
    table.insert(args, "-n")
    table.insert(args, ns)
  end
  table.insert(args, "-o")
  table.insert(args, "yaml")
  openInTerminal(shellCommand(args) .. " | less -R")
  actionResult(command, true, noctalia.tr("result.yaml_started", { name = name }))
end

local function copyResourceName(command)
  local ns, name = resourceRef(command)
  local text = name
  if ns ~= "" then
    text = ns .. "/" .. name
  end
  if text == "" then
    actionResult(command, false, noctalia.tr("result.failed", { error = "missing name" }))
    return
  end
  noctalia.copyToClipboard(text, "text/plain")
  actionResult(command, true, noctalia.tr("result.copied", { name = text }))
  notifyOk(noctalia.tr("result.copied", { name = text }))
end

local function executeAction(command)
  if type(command) ~= "table" or type(command.action) ~= "string" then
    return
  end
  if command.action == "refresh" then
    refreshAll()
    return
  end
  if command.action == "describe" then
    describeResource(command)
    return
  end
  if command.action == "logs" then
    logsPod(command)
    return
  end
  if command.action == "shell" then
    shellPod(command)
    return
  end
  if command.action == "port_forward" then
    portForwardPod(command)
    return
  end
  if command.action == "yaml" then
    getYaml(command)
    return
  end
  if command.action == "copy_name" then
    copyResourceName(command)
    return
  end
  if command.action == "delete_pod" then
    deletePod(command)
    return
  end
  if command.action == "restart_deploy" then
    restartDeploy(command)
    return
  end
  if command.action == "k9s" then
    openK9s(command)
    return
  end
  actionResult(command, false, `Unknown action: {command.action}`)
end

noctalia.state.watch(COMMAND_KEY, executeAction)
noctalia.setUpdateInterval(refreshIntervalMs())
refreshAll()

function update()
  refreshAll()
end

function onConfigChanged()
  noctalia.setUpdateInterval(refreshIntervalMs())
  refreshPending = false
  refreshStartedAt = 0
  refreshAll()
end

function onIpc(event, _payload)
  if event == "refresh" then
    refreshPending = false
    refreshStartedAt = 0
    refreshAll()
  end
end
