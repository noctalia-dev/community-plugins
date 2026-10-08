--!nonstrict
-- /svc: fuzzy-find systemd units, then start, stop or restart them.
--
-- "/svc <query>" lists matching units. Activating one rewrites the input to
-- "/svc <unit> " and the results become that unit's actions. Listings come from
-- systemctl asynchronously, so cached rows are published first and replaced when
-- the fresh listing lands.

local RESULT_LIMIT = 60
local CACHE_TTL_MS = 10000

local VERB_GLYPH = {
  start = "player-play",
  stop = "player-stop",
  restart = "refresh",
}

local units = {} -- sorted { name, scope, active, sub, description }
local byName = {} -- name -> units sharing that name (one per scope)
local loaded = false
local refreshing = false
local lastRefreshMs = 0
local lastQuery = ""

local tr = noctalia.tr
local trim = noctalia.string.trim

local function scopes()
  local cfg = noctalia.getConfig("scopes")
  if cfg == "user" then
    return { "user" }
  elseif cfg == "system" then
    return { "system" }
  end
  return { "user", "system" }
end

local function unitTypes()
  local types = {}
  local cfg = noctalia.getConfig("unit_types")
  if type(cfg) == "table" then
    for _, t in cfg do
      if type(t) == "string" and trim(t) ~= "" then
        table.insert(types, trim(t))
      end
    end
  end
  if #types == 0 then
    types = { "service" }
  end
  return types
end

local function systemctlArgv(scope, ...)
  local argv = {}
  if scope == "system" then
    local wrapper = noctalia.getConfig("system_wrapper")
    if type(wrapper) == "string" then
      for word in string.gmatch(wrapper, "%S+") do
        table.insert(argv, word)
      end
    end
  end
  table.insert(argv, "systemctl")
  if scope == "user" then
    table.insert(argv, "--user")
  end
  for _, arg in { ... } do
    table.insert(argv, arg)
  end
  return argv
end

local function scopeLabel(scope)
  return tr("launcher.scope." .. scope)
end

local function categoryFor(scope)
  return scope == "user" and "User" or "System"
end

local function stateGlyph(u)
  if u.active == "active" then
    return "circle-check"
  elseif u.active == "failed" then
    return "alert-circle"
  elseif u.active == "activating" or u.active == "deactivating" or u.active == "reloading" then
    return "loader"
  end
  return "circle-dashed"
end

local function stateText(u)
  if u.sub ~= "" and u.sub ~= u.active then
    return `{u.active} ({u.sub})`
  end
  return u.active
end

local function unitSubtitle(u)
  local parts = { scopeLabel(u.scope), stateText(u) }
  if u.description ~= "" then
    table.insert(parts, u.description)
  end
  return table.concat(parts, " · ")
end

-- Unit files give the full set of startable units; list-units adds live state and
-- template instances. Aliases, masked and unknown units are dropped since none of
-- the offered actions can apply to them.
local function rebuild(collected)
  local map = {}
  for scope, data in collected do
    for _, f in data.files do
      local name = f.unit_file
      local state = f.state
      if
        type(name) == "string"
        and not string.find(name, "@.", 1, true)
        and state ~= "alias"
        and state ~= "masked"
        and state ~= "masked-runtime"
      then
        map[scope .. "/" .. name] = { name = name, scope = scope, active = "inactive", sub = "dead", description = "" }
      end
    end
    for _, u in data.units do
      local name = u.unit
      if type(name) == "string" and u.load ~= "not-found" and u.load ~= "masked" then
        local key = scope .. "/" .. name
        local entry = map[key]
        if entry == nil then
          entry = { name = name, scope = scope }
          map[key] = entry
        end
        entry.active = if type(u.active) == "string" then u.active else ""
        entry.sub = if type(u.sub) == "string" then u.sub else ""
        entry.description = if type(u.description) == "string" then u.description else ""
      end
    end
  end

  units = {}
  byName = {}
  for _, u in map do
    table.insert(units, u)
  end
  table.sort(units, function(a, b)
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.scope < b.scope
  end)
  for _, u in units do
    byName[u.name] = byName[u.name] or {}
    table.insert(byName[u.name], u)
  end
  loaded = true
end

local function unitRow(u, score)
  return {
    id = "unit:" .. u.name,
    title = u.name,
    subtitle = unitSubtitle(u),
    glyph = stateGlyph(u),
    category = categoryFor(u.scope),
    score = score,
  }
end

-- With no pattern, surface failed units first, then running ones.
local function baseScore(u)
  if u.active == "failed" then
    return 3
  elseif u.active == "active" then
    return 2
  end
  return 1
end

local function unitRows(pattern)
  local rows = {}
  for _, u in units do
    local score
    if pattern == "" then
      score = baseScore(u)
    else
      score = noctalia.fuzzyScore(pattern, u.name)
      if score == nil and u.description ~= "" then
        local d = noctalia.fuzzyScore(pattern, u.description)
        if d ~= nil then
          score = d * 0.5
        end
      end
    end
    if score ~= nil then
      table.insert(rows, unitRow(u, score))
    end
  end
  table.sort(rows, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.title < b.title
  end)
  while #rows > RESULT_LIMIT do
    table.remove(rows)
  end
  return rows
end

local function verbsFor(u)
  if u.active == "active" or u.active == "activating" or u.active == "reloading" then
    return { "stop", "restart" }
  end
  return { "start" }
end

local function actionRows(name, filter)
  local rows = {}
  for _, u in byName[name] do
    for _, verb in verbsFor(u) do
      local score = 0
      if filter ~= "" then
        score = noctalia.fuzzyScore(filter, verb)
        if score == nil then
          continue
        end
      end
      table.insert(rows, {
        id = `act:{verb}:{u.scope}:{name}`,
        title = tr("launcher.action." .. verb, { unit = name }),
        subtitle = unitSubtitle(u),
        glyph = VERB_GLYPH[verb],
        category = categoryFor(u.scope),
        score = score,
      })
    end
  end
  return rows
end

local function hintRow(key, glyph)
  return { { id = "", title = tr(key), glyph = glyph } }
end

local function publish(query)
  if not loaded then
    launcher.setResults(query, hintRow("launcher.loading", "loader"))
    return
  end
  -- A unit name followed by a space means a unit was chosen: show its actions.
  local name, rest = string.match(query, "^%s*(%S+)%s+(.*)$")
  if name ~= nil and byName[name] ~= nil then
    launcher.setResults(query, actionRows(name, trim(rest)))
    return
  end
  local rows = unitRows(trim(query))
  if #rows == 0 then
    rows = hintRow(if #units == 0 then "launcher.no-units" else "launcher.no-matches", "search-off")
  end
  launcher.setResults(query, rows)
end

local function listArgv(scope, subcommand)
  return systemctlArgv(scope, subcommand, "--plain", "--no-pager", "--type=" .. table.concat(unitTypes(), ","), "-o", "json")
end

local function refresh()
  if refreshing then
    return
  end
  if not noctalia.commandExists("systemctl") then
    loaded = true
    launcher.setResults(lastQuery, hintRow("launcher.systemctl-missing", "alert-triangle"))
    return
  end
  refreshing = true

  local collected = {}
  local active = scopes()
  local pending = #active * 2

  local function finish()
    pending -= 1
    if pending > 0 then
      return
    end
    refreshing = false
    lastRefreshMs = noctalia.nowMs()
    rebuild(collected)
    publish(lastQuery)
  end

  local function collect(scope, key, argv)
    local ok = noctalia.runAsync(argv, function(result)
      local rows = nil
      if result.exitCode == 0 then
        rows = noctalia.json.decode(result.stdout)
      else
        noctalia.log(`systemctl {scope} {key} listing failed: {trim(result.stderr)}`)
      end
      collected[scope][key] = if type(rows) == "table" then rows else {}
      finish()
    end)
    if not ok then
      finish()
    end
  end

  for _, scope in active do
    collected[scope] = { files = {}, units = {} }
    collect(scope, "files", listArgv(scope, "list-unit-files"))
    collect(scope, "units", listArgv(scope, "list-units", "--all"))
  end
end

local function reportState(verb, scope, name)
  noctalia.runAsync(systemctlArgv(scope, "is-active", name), function(result)
    local state = trim(result.stdout)
    if state == "" then
      state = "unknown"
    end
    noctalia.notify(
      tr("launcher.action." .. verb, { unit = name }),
      tr("notify.state", { scope = scopeLabel(scope), state = state })
    )
  end)
end

local function runAction(verb, scope, name)
  local ok = noctalia.runAsync(systemctlArgv(scope, verb, name), function(result)
    lastRefreshMs = 0
    if result.exitCode == 0 then
      reportState(verb, scope, name)
    else
      noctalia.notifyError(tr("notify.failed", { verb = verb, unit = name }), trim(result.stderr))
    end
  end)
  if not ok then
    noctalia.notifyError(tr("notify.launch-failed"))
  end
end

function onQuery(text)
  lastQuery = text
  publish(text)
  if not refreshing and (not loaded or noctalia.nowMs() - lastRefreshMs > CACHE_TTL_MS) then
    refresh()
  end
end

function onActivate(id)
  if type(id) ~= "string" or id == "" then
    return
  end
  local unitName = string.match(id, "^unit:(.+)$")
  if unitName ~= nil then
    launcher.setQuery(unitName .. " ")
    return
  end
  local verb, scope, name = string.match(id, "^act:(%a+):(%a+):(.+)$")
  if verb ~= nil then
    runAction(verb, scope, name)
  end
end

function onIpc(event)
  if event == "refresh" then
    lastRefreshMs = 0
    refresh()
  end
end
