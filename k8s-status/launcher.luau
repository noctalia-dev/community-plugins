--!nonstrict
-- /kube launcher: drill into pods/nodes/deploys with autocomplete + actions.
--
-- /kube                  categories
-- /kube pods [filter]    list pods
-- /kube pods ns/name     actions (logs, shell, …)
-- /kube problems         problem pods only
-- /kube nodes|deploys|ns same pattern
-- /kube panel|k9s|status|refresh

local STATE_KEY = "k8s_snapshot"
local COMMAND_KEY = "k8s_command"
local PANEL_ID = "davemhammer/k8s-status:manager"
local MAX_ROWS = 40

local snapshot = noctalia.state.get(STATE_KEY) or {
  available = false,
  loading = true,
  pods = {},
  nodes = {},
  deployments = {},
  namespaces = {},
  readyNodes = 0,
  nodeCount = 0,
  problemPods = 0,
  podCount = 0,
  context = "",
  error = "",
}

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
  end
end)

local function trim(s)
  return noctalia.string.trim(tostring(s or ""))
end

local function lower(s)
  return string.lower(tostring(s or ""))
end

local function send(action, values)
  local command = { action = action, requestId = "launcher-" .. tostring(os.time()) }
  if type(values) == "table" then
    for k, v in pairs(values) do
      command[k] = v
    end
  end
  noctalia.state.set(COMMAND_KEY, command)
end

local function scoreText(filter, ...)
  if filter == "" then
    return 1
  end
  local best = nil
  for i = 1, select("#", ...) do
    local text = tostring(select(i, ...) or "")
    if text ~= "" then
      local s = noctalia.fuzzyScore(filter, text)
      if s ~= nil and (best == nil or s > best) then
        best = s
      end
      -- also plain substring
      if best == nil and lower(text):find(lower(filter), 1, true) then
        best = 0.5
      end
    end
  end
  return best
end

local function statusRow(title, subtitle, glyph)
  return {
    id = "",
    title = title,
    subtitle = subtitle,
    glyph = glyph or "hexagon",
  }
end

local function ensureSnapshot()
  if snapshot.loading or (not snapshot.available and (snapshot.podCount or 0) == 0) then
    send("refresh")
  end
end

local function topCategories()
  local ctx = snapshot.context ~= "" and snapshot.context or "—"
  local summary = `{snapshot.readyNodes or 0}/{snapshot.nodeCount or 0} nodes · {snapshot.problemPods or 0} problems · {snapshot.podCount or 0} pods`
  return {
    {
      id = "cat:pods",
      title = noctalia.tr("launcher.cat.pods"),
      subtitle = noctalia.tr("launcher.cat.pods-sub"),
      glyph = "box",
      score = 100,
    },
    {
      id = "cat:problems",
      title = noctalia.tr("launcher.cat.problems"),
      subtitle = noctalia.tr("launcher.cat.problems-sub") .. " · " .. tostring(snapshot.problemPods or 0),
      glyph = "circle-x",
      score = 95,
    },
    {
      id = "cat:nodes",
      title = noctalia.tr("launcher.cat.nodes"),
      subtitle = noctalia.tr("launcher.cat.nodes-sub"),
      glyph = "server",
      score = 90,
    },
    {
      id = "cat:deploys",
      title = noctalia.tr("launcher.cat.deploys"),
      subtitle = noctalia.tr("launcher.cat.deploys-sub"),
      glyph = "packages",
      score = 85,
    },
    {
      id = "cat:ns",
      title = noctalia.tr("launcher.cat.ns"),
      subtitle = noctalia.tr("launcher.cat.ns-sub"),
      glyph = "folder",
      score = 80,
    },
    {
      id = "act:status",
      title = noctalia.tr("launcher.cat.status"),
      subtitle = summary .. " · " .. ctx,
      glyph = "info-circle",
      score = 70,
    },
    {
      id = "act:panel",
      title = noctalia.tr("launcher.cat.panel"),
      subtitle = noctalia.tr("launcher.cat.panel-sub"),
      glyph = "layout-dashboard",
      score = 60,
    },
    {
      id = "act:k9s",
      title = noctalia.tr("launcher.cat.k9s"),
      subtitle = noctalia.tr("launcher.cat.k9s-sub"),
      glyph = "terminal-2",
      score = 50,
    },
    {
      id = "act:refresh",
      title = noctalia.tr("launcher.cat.refresh"),
      subtitle = noctalia.tr("launcher.cat.refresh-sub"),
      glyph = "refresh",
      score = 40,
    },
  }
end

local function podActions(ns, name)
  local ref = ns .. "/" .. name
  return {
    {
      id = "podact:logs:" .. ref,
      title = noctalia.tr("launcher.action.logs"),
      subtitle = ref .. " · " .. noctalia.tr("launcher.action.logs-sub"),
      glyph = "file-text",
      score = 100,
    },
    {
      id = "podact:shell:" .. ref,
      title = noctalia.tr("launcher.action.shell"),
      subtitle = ref .. " · " .. noctalia.tr("launcher.action.shell-sub"),
      glyph = "terminal",
      score = 95,
    },
    {
      id = "podact:describe:" .. ref,
      title = noctalia.tr("launcher.action.describe"),
      subtitle = noctalia.tr("launcher.action.describe-sub"),
      glyph = "file-description",
      score = 90,
    },
    {
      id = "podact:yaml:" .. ref,
      title = noctalia.tr("launcher.action.yaml"),
      subtitle = noctalia.tr("launcher.action.yaml-sub"),
      glyph = "code",
      score = 85,
    },
    {
      id = "podact:portforward:" .. ref,
      title = noctalia.tr("launcher.action.portforward"),
      subtitle = noctalia.tr("launcher.action.portforward-sub"),
      glyph = "arrows-exchange",
      score = 80,
    },
    {
      id = "podact:copy:" .. ref,
      title = noctalia.tr("launcher.action.copy"),
      subtitle = noctalia.tr("launcher.action.copy-sub"),
      glyph = "copy",
      score = 75,
    },
    {
      id = "podact:delete:" .. ref,
      title = noctalia.tr("launcher.action.delete"),
      subtitle = noctalia.tr("launcher.action.delete-sub"),
      glyph = "trash",
      score = 10,
    },
  }
end

local function nodeActions(name)
  return {
    {
      id = "nodeact:describe:" .. name,
      title = noctalia.tr("launcher.action.describe"),
      subtitle = name,
      glyph = "file-description",
      score = 100,
    },
    {
      id = "nodeact:yaml:" .. name,
      title = noctalia.tr("launcher.action.yaml"),
      subtitle = name,
      glyph = "code",
      score = 90,
    },
    {
      id = "nodeact:copy:" .. name,
      title = noctalia.tr("launcher.action.copy"),
      subtitle = name,
      glyph = "copy",
      score = 80,
    },
  }
end

local function deployActions(ns, name)
  local ref = ns .. "/" .. name
  return {
    {
      id = "depact:restart:" .. ref,
      title = noctalia.tr("launcher.action.restart"),
      subtitle = ref .. " · " .. noctalia.tr("launcher.action.restart-sub"),
      glyph = "refresh",
      score = 100,
    },
    {
      id = "depact:describe:" .. ref,
      title = noctalia.tr("launcher.action.describe"),
      subtitle = ref,
      glyph = "file-description",
      score = 90,
    },
    {
      id = "depact:yaml:" .. ref,
      title = noctalia.tr("launcher.action.yaml"),
      subtitle = ref,
      glyph = "code",
      score = 85,
    },
    {
      id = "depact:copy:" .. ref,
      title = noctalia.tr("launcher.action.copy"),
      subtitle = ref,
      glyph = "copy",
      score = 80,
    },
  }
end

local function filterActions(actions, filter)
  if filter == "" then
    return actions
  end
  local out = {}
  for _, row in ipairs(actions) do
    local s = scoreText(filter, row.title, row.id)
    if s ~= nil then
      row.score = s
      table.insert(out, row)
    end
  end
  return out
end

local function listPods(filter, problemsOnly)
  local rows = {}
  for _, p in ipairs(snapshot.pods or {}) do
    if problemsOnly and not p.problem then
      -- skip
    else
      local ref = p.namespace .. "/" .. p.name
      local s = scoreText(filter, p.name, p.namespace, ref, p.status, p.node)
      if s ~= nil then
        table.insert(rows, {
          id = "pod:" .. ref,
          title = ref,
          subtitle = `{p.ready} · {p.status} · r{p.restarts}` .. (p.node ~= "" and (" · " .. p.node) or ""),
          glyph = p.problem and "circle-x" or "box",
          score = s + (p.problem and 5 or 0),
        })
      end
    end
  end
  table.sort(rows, function(a, b)
    if (a.score or 0) == (b.score or 0) then
      return a.title < b.title
    end
    return (a.score or 0) > (b.score or 0)
  end)
  while #rows > MAX_ROWS do
    table.remove(rows)
  end
  if #rows == 0 then
    rows[1] = statusRow(noctalia.tr("launcher.no-matches"), filter, "search")
  end
  return rows
end

local function listNodes(filter)
  local rows = {}
  for _, n in ipairs(snapshot.nodes or {}) do
    local s = scoreText(filter, n.name, n.status, n.version, n.ip)
    if s ~= nil then
      table.insert(rows, {
        id = "node:" .. n.name,
        title = n.name,
        subtitle = `{n.status} · {n.version} · {n.ip}`,
        glyph = "server",
        score = s,
      })
    end
  end
  table.sort(rows, function(a, b)
    return (a.score or 0) > (b.score or 0)
  end)
  if #rows == 0 then
    rows[1] = statusRow(noctalia.tr("launcher.no-matches"), filter, "search")
  end
  return rows
end

local function listDeploys(filter)
  local rows = {}
  for _, d in ipairs(snapshot.deployments or {}) do
    local ref = d.namespace .. "/" .. d.name
    local s = scoreText(filter, d.name, d.namespace, ref)
    if s ~= nil then
      table.insert(rows, {
        id = "deploy:" .. ref,
        title = ref,
        subtitle = `{d.ready}/{d.desired} ready`,
        glyph = "packages",
        score = s + (d.problem and 5 or 0),
      })
    end
  end
  table.sort(rows, function(a, b)
    return (a.score or 0) > (b.score or 0)
  end)
  while #rows > MAX_ROWS do
    table.remove(rows)
  end
  if #rows == 0 then
    rows[1] = statusRow(noctalia.tr("launcher.no-matches"), filter, "search")
  end
  return rows
end

local function listNamespaces(filter)
  local rows = {}
  for _, n in ipairs(snapshot.namespaces or {}) do
    local s = scoreText(filter, n.name, n.phase)
    if s ~= nil then
      table.insert(rows, {
        id = "ns:" .. n.name,
        title = n.name,
        subtitle = n.phase,
        glyph = "folder",
        score = s,
      })
    end
  end
  table.sort(rows, function(a, b)
    return (a.score or 0) > (b.score or 0)
  end)
  if #rows == 0 then
    rows[1] = statusRow(noctalia.tr("launcher.no-matches"), filter, "search")
  end
  return rows
end

local function findPod(ref)
  ref = trim(ref)
  for _, p in ipairs(snapshot.pods or {}) do
    local id = p.namespace .. "/" .. p.name
    if id == ref or p.name == ref then
      return p
    end
  end
  -- partial unique match
  local hits = {}
  local q = lower(ref)
  for _, p in ipairs(snapshot.pods or {}) do
    local id = p.namespace .. "/" .. p.name
    if lower(id):find(q, 1, true) or lower(p.name):find(q, 1, true) then
      table.insert(hits, p)
    end
  end
  if #hits == 1 then
    return hits[1]
  end
  return nil
end

local function findDeploy(ref)
  ref = trim(ref)
  for _, d in ipairs(snapshot.deployments or {}) do
    local id = d.namespace .. "/" .. d.name
    if id == ref or d.name == ref then
      return d
    end
  end
  local hits = {}
  local q = lower(ref)
  for _, d in ipairs(snapshot.deployments or {}) do
    local id = d.namespace .. "/" .. d.name
    if lower(id):find(q, 1, true) or lower(d.name):find(q, 1, true) then
      table.insert(hits, d)
    end
  end
  if #hits == 1 then
    return hits[1]
  end
  return nil
end

local function findNode(name)
  name = trim(name)
  for _, n in ipairs(snapshot.nodes or {}) do
    if n.name == name then
      return n
    end
  end
  local hits = {}
  local q = lower(name)
  for _, n in ipairs(snapshot.nodes or {}) do
    if lower(n.name):find(q, 1, true) then
      table.insert(hits, n)
    end
  end
  if #hits == 1 then
    return hits[1]
  end
  return nil
end

local POD_ACTION_WORDS = {
  logs = true,
  log = true,
  shell = true,
  sh = true,
  exec = true,
  describe = true,
  desc = true,
  yaml = true,
  yml = true,
  pf = true,
  portforward = true,
  forward = true,
  copy = true,
  delete = true,
  del = true,
  rm = true,
}

local function normalizePodAction(word)
  word = lower(word)
  if word == "log" then return "logs" end
  if word == "sh" or word == "exec" then return "shell" end
  if word == "desc" then return "describe" end
  if word == "yml" then return "yaml" end
  if word == "pf" or word == "forward" then return "portforward" end
  if word == "del" or word == "rm" then return "delete" end
  if POD_ACTION_WORDS[word] then
    return word
  end
  return nil
end

local function runPodAction(action, ns, name)
  if action == "logs" then
    send("logs", { namespace = ns, name = name })
  elseif action == "shell" then
    send("shell", { namespace = ns, name = name })
  elseif action == "describe" then
    send("describe", { kind = "pod", namespace = ns, name = name })
  elseif action == "yaml" then
    send("yaml", { kind = "pod", namespace = ns, name = name })
  elseif action == "portforward" then
    send("port_forward", { namespace = ns, name = name, ports = "8080:8080" })
  elseif action == "copy" then
    send("copy_name", { namespace = ns, name = name })
  elseif action == "delete" then
    send("delete_pod", { namespace = ns, name = name })
  end
end

-- tokens after /kube
local function parseTokens(text)
  local tokens = {}
  for t in trim(text):gmatch("%S+") do
    table.insert(tokens, t)
  end
  return tokens
end

function onQuery(query)
  ensureSnapshot()

  if not snapshot.available and snapshot.loading then
    launcher.setResults(query, {
      statusRow(noctalia.tr("launcher.loading"), snapshot.context, "loader"),
    })
    return
  end

  if not snapshot.available then
    launcher.setResults(query, {
      statusRow(noctalia.tr("launcher.unavailable"), snapshot.error or "", "cloud-off"),
      {
        id = "act:refresh",
        title = noctalia.tr("launcher.cat.refresh"),
        subtitle = noctalia.tr("launcher.cat.refresh-sub"),
        glyph = "refresh",
      },
    })
    return
  end

  local text = trim(query)
  if text == "" then
    launcher.setResults(query, topCategories())
    return
  end

  local tokens = parseTokens(text)
  local head = lower(tokens[1] or "")

  -- fuzzy match top categories if first token is incomplete
  local function isKind(name, aliases)
    if head == name then
      return true
    end
    for _, a in ipairs(aliases) do
      if head == a then
        return true
      end
    end
    return false
  end

  if isKind("pods", { "pod", "po", "p" }) or isKind("problems", { "problem", "bad", "fail" }) then
    local problemsOnly = isKind("problems", { "problem", "bad", "fail" })
    local rest = {}
    for i = 2, #tokens do
      table.insert(rest, tokens[i])
    end

    -- /kube pods ns/name action
    if #rest >= 1 then
      local maybeAction = normalizePodAction(rest[#rest])
      local refParts = {}
      local endIdx = #rest
      if maybeAction and #rest >= 2 then
        endIdx = #rest - 1
      else
        maybeAction = nil
      end
      for i = 1, endIdx do
        table.insert(refParts, rest[i])
      end
      local ref = table.concat(refParts, " ")

      local pod = findPod(ref)
      if pod and maybeAction then
        -- show only matching action (or run via activate of filtered list)
        local actions = filterActions(podActions(pod.namespace, pod.name), maybeAction)
        if #actions == 0 then
          actions = podActions(pod.namespace, pod.name)
        end
        launcher.setResults(query, actions)
        return
      end

      if pod and not maybeAction and (#rest >= 1) then
        -- exact/unique pod selected via typing full ref — show actions
        -- if filter still ambiguous, list pods
        local exact = false
        local full = pod.namespace .. "/" .. pod.name
        if lower(ref) == lower(full) or lower(ref) == lower(pod.name) then
          exact = true
        end
        -- if only one fuzzy hit for ref, treat as drill-in when user typed a slash ref
        if exact or ref:find("/", 1, true) then
          launcher.setResults(query, podActions(pod.namespace, pod.name))
          return
        end
      end
    end

    local filter = table.concat(rest, " ")
    launcher.setResults(query, listPods(filter, problemsOnly))
    return
  end

  if isKind("nodes", { "node", "no" }) then
    local rest = table.concat(tokens, " ", 2)
    local node = findNode(rest)
    if node and (lower(rest) == lower(node.name) or rest:find(node.name, 1, true)) and rest ~= "" then
      -- if unique and reasonably exact, show actions
      if lower(rest) == lower(node.name) then
        launcher.setResults(query, nodeActions(node.name))
        return
      end
    end
    launcher.setResults(query, listNodes(rest))
    return
  end

  if isKind("deploys", { "deploy", "deployment", "deployments", "dep", "d" }) then
    local rest = table.concat(tokens, " ", 2)
    local dep = findDeploy(rest)
    if dep and rest:find("/", 1, true) then
      launcher.setResults(query, deployActions(dep.namespace, dep.name))
      return
    end
    if dep and lower(rest) == lower(dep.name) then
      launcher.setResults(query, deployActions(dep.namespace, dep.name))
      return
    end
    launcher.setResults(query, listDeploys(rest))
    return
  end

  if isKind("ns", { "namespace", "namespaces", "n" }) then
    local rest = table.concat(tokens, " ", 2)
    launcher.setResults(query, listNamespaces(rest))
    return
  end

  -- fallback: filter top categories + quick pod search
  local rows = {}
  for _, row in ipairs(topCategories()) do
    local s = scoreText(text, row.title, row.id)
    if s ~= nil then
      row.score = s
      table.insert(rows, row)
    end
  end
  -- also inject matching pods for convenience
  for _, p in ipairs(listPods(text, false)) do
    if p.id ~= "" then
      table.insert(rows, p)
    end
  end
  if #rows == 0 then
    rows[1] = statusRow(noctalia.tr("launcher.no-matches"), text, "search")
  end
  launcher.setResults(query, rows)
end

function onActivate(id)
  if id == nil or id == "" then
    return
  end

  if id == "cat:pods" then
    launcher.setQuery("pods ")
    return
  end
  if id == "cat:problems" then
    launcher.setQuery("problems ")
    return
  end
  if id == "cat:nodes" then
    launcher.setQuery("nodes ")
    return
  end
  if id == "cat:deploys" then
    launcher.setQuery("deploys ")
    return
  end
  if id == "cat:ns" then
    launcher.setQuery("ns ")
    return
  end

  if id == "act:panel" then
    noctalia.togglePanel(PANEL_ID)
    return
  end
  if id == "act:k9s" then
    send("k9s", {})
    return
  end
  if id == "act:refresh" then
    send("refresh")
    noctalia.notify(noctalia.tr("title"), noctalia.tr("widget.refresh_requested"))
    return
  end
  if id == "act:status" then
    local body = noctalia.tr("panel.summary", {
      ready = snapshot.readyNodes or 0,
      nodes = snapshot.nodeCount or 0,
      problems = snapshot.problemPods or 0,
      pods = snapshot.podCount or 0,
    })
    local ctx = snapshot.context ~= "" and snapshot.context or "default"
    noctalia.notify(noctalia.tr("title") .. " · " .. ctx, body)
    return
  end

  local podRef = id:match("^pod:(.+)$")
  if podRef then
    launcher.setQuery("pods " .. podRef .. " ")
    return
  end

  local nodeName = id:match("^node:(.+)$")
  if nodeName then
    launcher.setQuery("nodes " .. nodeName .. " ")
    return
  end

  local deployRef = id:match("^deploy:(.+)$")
  if deployRef then
    launcher.setQuery("deploys " .. deployRef .. " ")
    return
  end

  local nsName = id:match("^ns:(.+)$")
  if nsName then
    noctalia.copyToClipboard(nsName, "text/plain")
    noctalia.notify(noctalia.tr("title"), noctalia.tr("result.copied", { name = nsName }))
    return
  end

  local podAct, pref = id:match("^podact:([%w]+):(.+)$")
  if podAct and pref then
    local ns, name = pref:match("^([^/]+)/(.+)$")
    if ns and name then
      runPodAction(podAct, ns, name)
    end
    return
  end

  local nodeAct, nname = id:match("^nodeact:([%w]+):(.+)$")
  if nodeAct and nname then
    if nodeAct == "describe" then
      send("describe", { kind = "node", name = nname })
    elseif nodeAct == "yaml" then
      send("yaml", { kind = "node", name = nname })
    elseif nodeAct == "copy" then
      send("copy_name", { name = nname })
    end
    return
  end

  local depAct, dref = id:match("^depact:([%w]+):(.+)$")
  if depAct and dref then
    local ns, name = dref:match("^([^/]+)/(.+)$")
    if ns and name then
      if depAct == "restart" then
        send("restart_deploy", { namespace = ns, name = name })
      elseif depAct == "describe" then
        send("describe", { kind = "deploy", namespace = ns, name = name })
      elseif depAct == "yaml" then
        send("yaml", { kind = "deploy", namespace = ns, name = name })
      elseif depAct == "copy" then
        send("copy_name", { namespace = ns, name = name })
      end
    end
    return
  end
end
