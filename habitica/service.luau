--!nonstrict
-- Habitica backend for Noctalia v5.
--
-- The service owns every network call and publishes one snapshot to
-- noctalia.state. The bar widget and the panel are thin readers; commands
-- (refresh, score a task, score a checklist item) travel back through a
-- second state key so the UI never blocks on HTTP.

local API_BASE = "https://habitica.com/api/v3"
local ASSET_BASE = "https://habitica-assets.s3.amazonaws.com/mobileApp/images/"

local STATE_KEY = "habitica_snapshot"
local REV_KEY = "habitica_rev"
local COMMAND_KEY = "habitica_command"

local PANEL_ID = "vasqs/habitica:panel"

-- A refresh that never calls back must not leave the service stuck.
local STUCK_REFRESH_SEC = 45

local revision = 0
local loading = false
local refreshStartedAt = 0
local lastFetch = 0
local scoring = false
local avatarBuilding = false
local lastAvatarAttempt = ""
local lastAvatarAttemptAt = 0
local lastData = nil

local snapshot = {
  revision = 0,
  configured = false,
  available = false,
  loading = true,
  scoring = false,
  scoringTaskId = "",
  error = "",
  updatedAt = 0,
  displayName = "Habitica",
  level = 0,
  className = "",
  stats = {},
  dailies = {},
  todos = {},
  habits = {},
  tags = {},
  dueDailiesCount = 0,
  openTodosCount = 0,
  habitCount = 0,
  pendingCount = 0,
  avatarPath = "",
  avatarSignature = "",
}

-- ---------------------------------------------------------------------------
-- configuration

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function cfgString(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "string" then
    return value
  end
  return fallback or ""
end

local function cfgInt(key, fallback, min, max)
  local value = tonumber(noctalia.getConfig(key)) or fallback
  value = math.floor(value)
  if min ~= nil then value = math.max(min, value) end
  if max ~= nil then value = math.min(max, value) end
  return value
end

local function cfgBool(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "boolean" then
    return value
  end
  if type(value) == "string" then
    return value == "true"
  end
  return fallback and true or false
end

local function userId()
  return trim(cfgString("habitica_user_id", ""))
end

local function apiToken()
  return trim(cfgString("habitica_api_token", ""))
end

local function isConfigured()
  return userId() ~= "" and apiToken() ~= ""
end

local function refreshSeconds()
  return cfgInt("refresh_interval", 300, 60, 3600)
end

local function refreshMs()
  return refreshSeconds() * 1000
end

local function maxDailies()
  return cfgInt("max_dailies", 8, 1, 25)
end

local function maxTodos()
  return cfgInt("max_todos", 8, 1, 25)
end

local function maxHabits()
  return cfgInt("max_habits", 8, 1, 25)
end

local function showHabits()
  return cfgBool("show_habits", false)
end

local function tagFilterEnabled()
  return cfgBool("enable_tag_filter", false)
end

local function selectedTagId()
  return trim(cfgString("selected_tag_id", ""))
end

local function nowSec()
  return os.time()
end

-- ---------------------------------------------------------------------------
-- snapshot publishing

local function publish()
  revision += 1
  snapshot.revision = revision
  noctalia.state.set(STATE_KEY, snapshot)
  noctalia.state.set(REV_KEY, revision)
end

local function resetCounts()
  snapshot.dailies = {}
  snapshot.todos = {}
  snapshot.habits = {}
  snapshot.tags = {}
  snapshot.dueDailiesCount = 0
  snapshot.openTodosCount = 0
  snapshot.habitCount = 0
  snapshot.pendingCount = 0
end

local function publishNotConfigured()
  loading = false
  refreshStartedAt = 0
  snapshot.configured = false
  snapshot.available = false
  snapshot.loading = false
  snapshot.error = noctalia.tr("panel.not_configured")
  snapshot.user = nil
  snapshot.stats = {}
  snapshot.displayName = "Habitica"
  snapshot.level = 0
  snapshot.className = ""
  resetCounts()
  publish()
end

-- ---------------------------------------------------------------------------
-- task shaping

local function asString(value)
  if value == nil then
    return ""
  end
  if type(value) == "boolean" then
    return value and "true" or "false"
  end
  return tostring(value)
end

local function taskId(raw)
  local id = raw.id or raw._id
  return id == nil and "" or tostring(id)
end

local function shapeChecklist(raw)
  local out = {}
  for _, item in ipairs(raw or {}) do
    if type(item) == "table" then
      table.insert(out, {
        id = taskId(item),
        text = asString(item.text),
        completed = item.completed == true,
      })
    end
  end
  return out
end

local function shapeTask(raw, kind)
  if type(raw) ~= "table" then
    return nil
  end
  local id = taskId(raw)
  if id == "" then
    return nil
  end
  return {
    id = id,
    text = asString(raw.text),
    notes = asString(raw.notes),
    type = asString(raw.type) ~= "" and asString(raw.type) or kind,
    completed = raw.completed == true,
    priority = tonumber(raw.priority) or 0,
    value = tonumber(raw.value) or 0,
    streak = tonumber(raw.streak) or 0,
    up = raw.up ~= false,
    down = raw.down ~= false,
    tags = raw.tags or {},
    nextDue = raw.nextDue or {},
    checklist = shapeChecklist(raw.checklist),
  }
end

-- Habitica's nextDue is a list of local calendar dates. Comparing the date
-- prefix keeps this independent of the timezone offset in the payload.
local function isDueDaily(task)
  if task.completed or task.type ~= "daily" then
    return false
  end
  local dates = task.nextDue
  if type(dates) ~= "table" or #dates == 0 then
    return true
  end
  local today = os.date("%Y-%m-%d")
  for _, raw in ipairs(dates) do
    local day = asString(raw):sub(1, 10)
    if day ~= "" and day <= today then
      return true
    end
  end
  return false
end

local function tagMatches(task)
  if not tagFilterEnabled() then
    return true
  end
  local wanted = selectedTagId()
  if wanted == "" then
    return true
  end
  if type(task.tags) ~= "table" then
    return false
  end
  for _, id in ipairs(task.tags) do
    if asString(id) == wanted then
      return true
    end
  end
  return false
end

local function filterTasks(list, kind)
  local out = {}
  for _, task in ipairs(list or {}) do
    local include = tagMatches(task)
    if include and kind == "daily" then
      include = isDueDaily(task)
    elseif include and kind == "todo" then
      include = task.type == "todo" and not task.completed
    elseif include and kind == "habit" then
      include = task.type == "habit"
    end
    if include then
      table.insert(out, task)
    end
  end
  return out
end

local function applyLimits(list, limit)
  local out = {}
  for index = 1, math.min(#list, math.max(1, limit)) do
    out[index] = list[index]
  end
  return out
end

local function displayName(user)
  local profile = type(user) == "table" and user.profile or {}
  local name = profile and profile.name
  if name ~= nil and asString(name) ~= "" then
    return asString(name)
  end
  local auth = type(user) == "table" and user.auth or nil
  local authLocal = auth and auth["local"] or nil
  if authLocal and asString(authLocal.username) ~= "" then
    return asString(authLocal.username)
  end
  return "Habitica"
end

local function className(stats)
  local value = asString(stats and stats.class)
  if value == "" then
    return ""
  end
  return value:sub(1, 1):upper() .. value:sub(2)
end

local function applyData(user, rawDailies, rawTodos, rawHabits, tags, updatedAt)
  local dailies = {}
  local todos = {}
  local habits = {}
  for _, raw in ipairs(rawDailies or {}) do
    local task = shapeTask(raw, "daily")
    if task ~= nil then table.insert(dailies, task) end
  end
  for _, raw in ipairs(rawTodos or {}) do
    local task = shapeTask(raw, "todo")
    if task ~= nil then table.insert(todos, task) end
  end
  for _, raw in ipairs(rawHabits or {}) do
    local task = shapeTask(raw, "habit")
    if task ~= nil then table.insert(habits, task) end
  end

  local dueDailies = filterTasks(dailies, "daily")
  local openTodos = filterTasks(todos, "todo")
  local allHabits = filterTasks(habits, "habit")

  snapshot.user = {
    profile = type(user) == "table" and user.profile or nil,
    preferences = type(user) == "table" and user.preferences or nil,
    items = type(user) == "table" and user.items or nil,
  }
  snapshot.stats = type(user) == "table" and user.stats or snapshot.stats or {}
  snapshot.displayName = displayName(user)
  snapshot.level = tonumber(snapshot.stats.lvl) or 0
  snapshot.className = className(snapshot.stats)
  snapshot.tags = tags or {}
  snapshot.dailies = applyLimits(dueDailies, maxDailies())
  snapshot.todos = applyLimits(openTodos, maxTodos())
  snapshot.habits = showHabits() and applyLimits(allHabits, maxHabits()) or {}
  snapshot.dueDailiesCount = #dueDailies
  snapshot.openTodosCount = #openTodos
  snapshot.habitCount = #allHabits
  snapshot.pendingCount = #dueDailies + #openTodos
  snapshot.available = true
  snapshot.loading = false
  snapshot.error = ""
  snapshot.updatedAt = updatedAt or nowSec()
end

-- ---------------------------------------------------------------------------
-- cache

local function dataDir()
  local dir = noctalia.pluginDataDir()
  return dir
end

local function cachePath()
  local dir = dataDir()
  return dir and (dir .. "/habitica.json") or nil
end

local function saveCache()
  if lastData == nil then
    return
  end
  local path = cachePath()
  if path == nil then
    return
  end
  local payload = {
    user = lastData.user,
    dailies = lastData.dailies,
    todos = lastData.todos,
    habits = lastData.habits,
    tags = lastData.tags,
    timestamp = lastFetch,
    avatarPath = snapshot.avatarPath,
    avatarSignature = snapshot.avatarSignature,
  }
  local text = noctalia.json.encode(payload, true)
  if text ~= nil then
    local ok, err = noctalia.writeFile(path, text)
    if not ok then
      noctalia.log("habitica: cache write failed: " .. asString(err))
    end
  end
end

local function loadCache()
  local path = cachePath()
  if path == nil or not noctalia.fileExists(path) then
    return false
  end
  local text = noctalia.readFile(path)
  if text == nil or trim(text) == "" then
    return false
  end
  local data = noctalia.json.decode(text)
  if type(data) ~= "table" or type(data.user) ~= "table" then
    return false
  end
  lastData = {
    user = data.user,
    dailies = data.dailies or {},
    todos = data.todos or {},
    habits = data.habits or {},
    tags = data.tags or {},
  }
  lastFetch = tonumber(data.timestamp) or 0
  snapshot.avatarPath = asString(data.avatarPath)
  snapshot.avatarSignature = asString(data.avatarSignature)
  applyData(lastData.user, lastData.dailies, lastData.todos, lastData.habits, lastData.tags, lastFetch)
  snapshot.configured = isConfigured()
  snapshot.available = true
  publish()
  return true
end

-- ---------------------------------------------------------------------------
-- HTTP

local function decodeBody(res)
  if type(res) ~= "table" then
    return nil, "no response"
  end
  if not res.ok and (res.status == nil or res.status == 0) then
    return nil, trim(res.body) ~= "" and trim(res.body) or "network error"
  end
  local body = type(res.body) == "string" and res.body or ""
  local data = nil
  if body ~= "" then
    local decoded, err = noctalia.json.decode(body)
    if type(decoded) ~= "table" then
      return nil, err or "invalid JSON response"
    end
    data = decoded
  else
    data = {}
  end
  if data.success == false then
    local message = trim(data.message)
    if message == "" then
      message = trim(data.error)
    end
    return nil, message ~= "" and message or "Habitica request failed"
  end
  if res.status ~= nil and res.status >= 400 then
    local message = trim(data.message)
    if message == "" then
      message = trim(data.error)
    end
    return nil, message ~= "" and message or ("HTTP " .. tostring(res.status))
  end
  return data, nil
end

local function apiRequest(method, path, body, callback)
  local id = userId()
  local req = {
    url = API_BASE .. path,
    method = method or "GET",
    headers = {
      "x-api-user: " .. id,
      "x-api-key: " .. apiToken(),
      "x-client: " .. id .. "-noctalia-habitica",
      "Accept: application/json",
    },
  }
  if body ~= nil then
    req.body = noctalia.json.encode(body) or ""
    table.insert(req.headers, "Content-Type: application/json")
  end

  local function safeCallback(res)
    if type(callback) ~= "function" then
      return
    end
    local ok, err = pcall(callback, res)
    if not ok then
      noctalia.log("habitica: callback error: " .. asString(err))
    end
  end

  local started = noctalia.http(req, safeCallback)
  if not started then
    safeCallback({ ok = false, status = 0, body = "http queue full" })
  end
  return started
end

local function apiGet(path, callback)
  return apiRequest("GET", path, nil, callback)
end

local function apiPost(path, body, callback)
  return apiRequest("POST", path, body, callback)
end

local function fetchUser(callback)
  apiGet("/user?userFields=stats,profile,preferences,items,notifications", function(res)
    local data, err = decodeBody(res)
    if data == nil then
      callback(nil, err)
      return
    end
    callback(data.data or {}, nil)
  end)
end

local function fetchTasks(kind, callback)
  apiGet("/tasks/user?type=" .. kind, function(res)
    local data, err = decodeBody(res)
    if data == nil then
      callback(nil, err)
      return
    end
    callback(type(data.data) == "table" and data.data or {}, nil)
  end)
end

local function fetchTags(callback)
  apiGet("/tags", function(res)
    local data, err = decodeBody(res)
    if data == nil then
      callback(nil, err)
      return
    end
    callback(type(data.data) == "table" and data.data or {}, nil)
  end)
end

-- ---------------------------------------------------------------------------
-- avatar compositing
--
-- Habitica's avatar is a stack of transparent sprites. v5's ui.image only
-- accepts local files, so the service downloads the visible layers once per
-- avatar change and composites them with ImageMagick. When magick is missing
-- the panel falls back to the sword glyph.

local function pref(preferences, path, fallback)
  local current = preferences
  for _, key in ipairs(path) do
    if type(current) ~= "table" then
      return fallback
    end
    current = current[key]
    if current == nil then
      return fallback
    end
  end
  if current == nil or current == "" then
    return fallback
  end
  return current
end

local function gearSet(user)
  local preferences = type(user) == "table" and user.preferences or {}
  local items = type(user) == "table" and user.items or {}
  local allGear = type(items) == "table" and items.gear or {}
  local set = pref(preferences, { "costume" }, false) and "costume" or "equipped"
  return allGear[set] or allGear.equipped or {}
end

local function gear(user, slot)
  local set = gearSet(user)
  return asString(set[slot])
end

local function hair(user, slot)
  local preferences = type(user) == "table" and user.preferences or {}
  local value = pref(preferences, { "hair", slot }, 0)
  if value == 0 or value == "" then
    return ""
  end
  return "hair_" .. slot .. "_" .. asString(value) .. "_" .. asString(pref(preferences, { "hair", "color" }, "brown"))
end

local function addSprite(list, sprite)
  if sprite == nil or sprite == "" or sprite == "undefined" or sprite == "null" then
    return
  end
  for _, existing in ipairs(list) do
    if existing == sprite then
      return
    end
  end
  table.insert(list, sprite)
end

local function addGear(list, sprite)
  if sprite == nil or sprite == "" or sprite:match("_base_0$") then
    return
  end
  addSprite(list, sprite)
end

local function avatarSpec(user)
  local preferences = type(user) == "table" and user.preferences or {}
  local items = type(user) == "table" and user.items or {}
  local mount = asString(items.currentMount)
  local pet = asString(items.currentPet)
  local size = asString(pref(preferences, { "size" }, "slim"))
  local chair = asString(pref(preferences, { "chair" }, "none"))
  local armor = gear(user, "armor")
  local flower = pref(preferences, { "hair", "flower" }, 0)

  local layers = {}
  if chair ~= "" and chair ~= "none" then
    addSprite(layers, "chair_" .. chair)
  end
  addGear(layers, gear(user, "back"))
  addSprite(layers, "skin_" .. asString(pref(preferences, { "skin" }, "ddc994")) .. (pref(preferences, { "sleep" }, false) and "_sleep" or ""))
  addSprite(layers, size .. "_shirt_" .. asString(pref(preferences, { "shirt" }, "blue")))
  addSprite(layers, "head_0")
  if armor ~= "" then
    addSprite(layers, size .. "_" .. armor)
  end
  addGear(layers, gear(user, "back_collar"))
  addSprite(layers, hair(user, "bangs"))
  addSprite(layers, hair(user, "base"))
  addSprite(layers, hair(user, "mustache"))
  addSprite(layers, hair(user, "beard"))
  addGear(layers, gear(user, "body"))
  addGear(layers, gear(user, "eyewear"))
  addGear(layers, gear(user, "head"))
  addGear(layers, gear(user, "headAccessory"))
  if flower ~= 0 and flower ~= "" then
    addSprite(layers, "hair_flower_" .. asString(flower))
  end
  addGear(layers, gear(user, "shield"))
  addGear(layers, gear(user, "weapon"))

  return {
    background = "background_" .. asString(pref(preferences, { "background" }, "violet")),
    layers = layers,
    mount = mount,
    pet = pet,
    hasMount = mount ~= "",
    hasPet = pet ~= "",
    mountBody = mount ~= "" and ("Mount_Body_" .. mount) or "",
    mountHead = mount ~= "" and ("Mount_Head_" .. mount) or "",
    petSprite = pet ~= "" and ("Pet-" .. pet) or "",
    layerOffsetY = (mount ~= "" and mount:find("Kangaroo", 1, true) ~= nil) and 24 or 0,
  }
end

local function avatarSignature(user)
  local encoded = noctalia.json.encode({
    preferences = type(user) == "table" and user.preferences or {},
    items = type(user) == "table" and user.items or {},
  })
  return encoded or ""
end

local function avatarDir()
  local dir = dataDir()
  return dir and (dir .. "/avatar") or nil
end

local function spritePath(dir, sprite)
  return dir .. "/" .. sprite .. ".png"
end

local function composeAvatar(user)
  if not isConfigured() or not noctalia.commandExists("magick") then
    return
  end
  local dir = avatarDir()
  if dir == nil then
    return
  end
  local signature = avatarSignature(user)
  if signature == "" then
    return
  end
  if snapshot.avatarSignature == signature and snapshot.avatarPath ~= ""
    and noctalia.fileExists(snapshot.avatarPath) then
    return
  end
  if avatarBuilding then
    return
  end
  local now = nowSec()
  if lastAvatarAttempt == signature and (now - lastAvatarAttemptAt) < 600 then
    return
  end

  local spec = avatarSpec(user)
  local names = { spec.background }
  for _, sprite in ipairs(spec.layers) do
    table.insert(names, sprite)
  end
  if spec.mountBody ~= "" then table.insert(names, spec.mountBody) end
  if spec.mountHead ~= "" then table.insert(names, spec.mountHead) end
  if spec.petSprite ~= "" then table.insert(names, spec.petSprite) end

  avatarBuilding = true
  lastAvatarAttempt = signature
  lastAvatarAttemptAt = now
  noctalia.mkdirAll(dir)

  local missing = {}
  for _, sprite in ipairs(names) do
    local path = spritePath(dir, sprite)
    if not noctalia.fileExists(path) then
      table.insert(missing, { sprite = sprite, path = path })
    end
  end

  local function finishCompose()
    local out = dir .. "/avatar.png"
    local args = { "magick", spritePath(dir, spec.background) }
    local paddingTop = spec.hasMount and 0 or 24
    local mountY = spec.hasMount and 18 or 0

    local function composite(path, x, y)
      table.insert(args, "(")
      table.insert(args, path)
      table.insert(args, ")")
      table.insert(args, "-geometry")
      table.insert(args, string.format("+%d+%d", x, y))
      table.insert(args, "-composite")
    end

    if spec.hasMount then
      composite(spritePath(dir, spec.mountBody), 24, mountY)
    end
    for _, sprite in ipairs(spec.layers) do
      composite(spritePath(dir, sprite), 24, paddingTop + spec.layerOffsetY)
    end
    if spec.hasMount then
      composite(spritePath(dir, spec.mountHead), 24, mountY)
    end
    if spec.hasPet then
      table.insert(args, "(")
      table.insert(args, spritePath(dir, spec.petSprite))
      table.insert(args, ")")
      table.insert(args, "-gravity")
      table.insert(args, "south")
      table.insert(args, "-geometry")
      table.insert(args, "+0+0")
      table.insert(args, "-composite")
    end
    table.insert(args, out)

    noctalia.runAsync(args, function(result)
      avatarBuilding = false
      if result ~= nil and result.exitCode == 0 and noctalia.fileExists(out) then
        snapshot.avatarPath = out
        snapshot.avatarSignature = signature
        saveCache()
        publish()
      else
        noctalia.log("habitica: avatar compositing failed")
      end
    end, 30000)
  end

  if #missing == 0 then
    finishCompose()
    return
  end

  local pending = #missing
  local completed = 0
  local failed = false
  local function oneDone(ok)
    completed += 1
    if not ok then
      failed = true
    end
    if completed == pending then
      if failed then
        avatarBuilding = false
        noctalia.log("habitica: avatar sprite download failed")
      else
        finishCompose()
      end
    end
  end
  for _, item in ipairs(missing) do
    local settled = false
    local function settle(ok)
      if settled then
        return
      end
      settled = true
      oneDone(ok)
    end
    local started = noctalia.download(ASSET_BASE .. item.sprite .. ".png", item.path, settle)
    if not started then
      settle(false)
    end
  end
end

-- ---------------------------------------------------------------------------
-- refresh

local function finishError(message)
  loading = false
  refreshStartedAt = 0
  snapshot.loading = false
  snapshot.error = message
  snapshot.available = false
  publish()
end

local function refreshAll(force)
  if loading then
    if refreshStartedAt > 0 and (nowSec() - refreshStartedAt) >= STUCK_REFRESH_SEC then
      noctalia.log("habitica: refresh timed out")
      finishError("refresh timed out")
    end
    return
  end
  if not isConfigured() then
    publishNotConfigured()
    return
  end
  if not force and lastFetch > 0 and (nowSec() - lastFetch) < refreshSeconds() then
    return
  end

  loading = true
  refreshStartedAt = nowSec()
  snapshot.configured = true
  snapshot.loading = true
  snapshot.error = ""
  publish()

  fetchUser(function(user, userError)
    if userError ~= nil then
      finishError(userError)
      return
    end
    fetchTasks("dailys", function(dailies, dailiesError)
      if dailiesError ~= nil then
        finishError(dailiesError)
        return
      end
      fetchTasks("todos", function(todos, todosError)
        if todosError ~= nil then
          finishError(todosError)
          return
        end
        local function afterHabits(habits, habitsError)
          if habitsError ~= nil then
            finishError(habitsError)
            return
          end
          local function afterTags(tags, tagsError)
            if tagsError ~= nil then
              finishError(tagsError)
              return
            end
            lastData = {
              user = user,
              dailies = dailies,
              todos = todos,
              habits = habits or {},
              tags = tags or {},
            }
            lastFetch = nowSec()
            loading = false
            refreshStartedAt = 0
            applyData(user, dailies, todos, habits or {}, tags or {}, lastFetch)
            saveCache()
            publish()
            composeAvatar(user)
          end
          if tagFilterEnabled() then
            fetchTags(afterTags)
          else
            afterTags({}, nil)
          end
        end
        if showHabits() then
          fetchTasks("habits", afterHabits)
        else
          afterHabits({}, nil)
        end
      end)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- scoring

local function finishScore(message, isError)
  scoring = false
  snapshot.scoring = false
  snapshot.scoringTaskId = ""
  publish()
  if isError and message ~= nil and message ~= "" then
    noctalia.notifyError("Habitica", message)
  end
  refreshAll(true)
end

local function scoreTask(id, direction)
  if scoring then
    return
  end
  if not isConfigured() then
    noctalia.notifyError("Habitica", noctalia.tr("panel.not_configured"))
    return
  end
  id = trim(id)
  if id == "" then
    return
  end
  direction = direction == "down" and "down" or "up"
  scoring = true
  snapshot.scoring = true
  snapshot.scoringTaskId = id
  publish()
  apiPost("/tasks/" .. noctalia.string.urlEncode(id) .. "/score/" .. direction, nil, function(res)
    local data, err = decodeBody(res)
    if data == nil then
      finishScore(noctalia.tr("toast.score_failed", { error = err }), true)
      return
    end
    if type(data.data) == "table" then
      snapshot.stats = data.data
    end
    finishScore(nil, false)
  end)
end

local function scoreChecklist(id, itemId)
  if scoring then
    return
  end
  if not isConfigured() then
    noctalia.notifyError("Habitica", noctalia.tr("panel.not_configured"))
    return
  end
  id = trim(id)
  itemId = trim(itemId)
  if id == "" or itemId == "" then
    return
  end
  scoring = true
  snapshot.scoring = true
  snapshot.scoringTaskId = id
  publish()
  local path = "/tasks/" .. noctalia.string.urlEncode(id)
    .. "/checklist/" .. noctalia.string.urlEncode(itemId) .. "/score"
  apiPost(path, nil, function(res)
    local data, err = decodeBody(res)
    if data == nil then
      finishScore(noctalia.tr("toast.score_failed", { error = err }), true)
      return
    end
    if type(data.data) == "table" then
      snapshot.stats = data.data
    end
    finishScore(nil, false)
  end)
end

-- ---------------------------------------------------------------------------
-- commands / lifecycle

local function executeCommand(command)
  if type(command) ~= "table" or type(command.action) ~= "string" then
    return
  end
  if command.action == "refresh" then
    refreshAll(true)
  elseif command.action == "score_task" then
    scoreTask(command.taskId, command.direction)
  elseif command.action == "score_checklist" then
    scoreChecklist(command.taskId, command.itemId)
  elseif command.action == "toggle_panel" then
    noctalia.togglePanel(PANEL_ID)
  end
end

noctalia.state.watch(COMMAND_KEY, executeCommand)

noctalia.setUpdateInterval(refreshMs())
if not loadCache() then
  publishNotConfigured()
end
if isConfigured() then
  refreshAll(true)
end

function update()
  if scoring then
    return
  end
  refreshAll(false)
end

function onConfigChanged()
  noctalia.setUpdateInterval(refreshMs())
  loading = false
  refreshStartedAt = 0
  if not isConfigured() then
    publishNotConfigured()
    return
  end
  refreshAll(true)
end

function onIpc(event, payload)
  if event == "refresh" then
    refreshAll(true)
  elseif event == "toggle" then
    noctalia.togglePanel(PANEL_ID)
  elseif event == "score" then
    -- `score <task-id> <up|down>`
    local id, direction = tostring(payload or ""):match("^(%S+)%s+(%S+)$")
    if id ~= nil then
      scoreTask(id, direction)
    end
  elseif event == "checklist" then
    -- `checklist <task-id> <item-id>`
    local id, itemId = tostring(payload or ""):match("^(%S+)%s+(%S+)$")
    if id ~= nil then
      scoreChecklist(id, itemId)
    end
  end
end
