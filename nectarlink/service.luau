--!nonstrict
-- Own connection state and read scheduling. Separate modules handle HTTP,
-- page caching and explicit actions; credentials never reach the UI.
local limits =
  { updateIntervalMs = 2000, timeoutTicks = 15, pageCacheLimit = 24, pageRetryTicks = 15 }
local snapshot = { state = "unconfigured", devices = {} }
local clock = { ticks = 0 }
local visibility = { open = false, section = "home", activePage = nil, warmedHome = nil }
local access = require("./message_access.luau")
local knownDevices = {}
local knownAppAccess = {}
local legacyEmpty = false
-- Device reads and individual action channels have independent counters.
local requests = {
  devices = { pending = false, generation = 0 },
  ring = { generation = 0, started = 0, refreshing = false },
  timeline = { pending = false, generation = 0, started = 0 },
  notifications = { pending = false, generation = 0, started = 0 },
  camera = { generation = 0, started = 0 },
  controls = { generation = 0, started = 0, refreshing = false },
  sessions = {
    pending = false,
    refreshing = false,
    generation = 0,
    started = 0,
    commandGeneration = 0,
    commandStarted = 0,
  },
  typing = { generation = 0, started = 0 },
  actions = { generation = 0, started = 0 },
}
local lastPublished = nil
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = copy(v)
  end
  return out
end

local function same(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not same(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

local function publish()
  if same(snapshot, lastPublished) then
    return
  end
  lastPublished = copy(snapshot)
  noctalia.state.set("nl.snapshot", noctalia.json.encode(snapshot))
end

local function onlineDevice(id)
  if snapshot.state ~= "ready" then
    return false
  end
  for _, d in ipairs(snapshot.devices) do
    if d.id == id and d.online then
      return true
    end
  end
  return false
end

local function canTransfer()
  return #snapshot.devices == 1 and onlineDevice(snapshot.devices[1].id)
end
local pages
local api = require("./service/api.luau").new(function(reason)
  -- Old callbacks will be discarded. Release pending/busy immediately so new
  -- reads do not wait for their timeout. Never replay an action.
  local uncertain = snapshot.pageActionBusy
    or snapshot.typeBusy
    or snapshot.sessionBusy
    or snapshot.controlBusy
    or snapshot.cameraBusy
    or snapshot.ringBusy
  for _, channel in pairs(requests) do
    channel.generation = channel.generation + 1
    if channel.pending ~= nil then
      channel.pending = false
    end
    if channel.refreshing ~= nil then
      channel.refreshing = false
    end
  end
  requests.sessions.commandGeneration = requests.sessions.commandGeneration + 1
  visibility.activePage = nil
  visibility.threads = nil
  visibility.warmedHome = nil
  knownDevices = {}
  knownAppAccess = {}
  legacyEmpty = false
  -- Clear the old projection in place; modules retain the same snapshot table.
  for key in pairs(snapshot) do
    snapshot[key] = nil
  end
  snapshot.state = reason == "auth_changed" and "offline" or "unconfigured"
  snapshot.error = reason
  snapshot.devices = {}
  pages.reset()
  publish()
  if uncertain then
    noctalia.notifyError("NectarLink", noctalia.tr("notifications.auth_changed"))
  end
end)
pages = require("./service/pages.luau").new(
  visibility,
  clock,
  snapshot,
  api,
  publish,
  onlineDevice,
  limits
)
local geometry = require("./ui/components.luau").layout
local warmup = require("./service/warmup.luau").new(pages, snapshot, visibility, onlineDevice, geometry)
local decode = api.decode
local credentials = api.credentials
local request = api.request
local resetPages = pages.reset
local invalidateKind = pages.invalidate
local readPage = pages.read
local sessionKinds = { "pc_audio", "watch", "phone_audio", "screen", "webcam", "keyboard" }
local function homeActive()
  return visibility.open and visibility.section == "home"
end

local function pollTimeline(warm)
  if
    (not homeActive() and not warm)
    or noctalia.getConfig("panel_timeline") == false
    or requests.timeline.pending
  then
    return
  end
  requests.timeline.pending = true
  requests.timeline.started = clock.ticks
  requests.timeline.generation = requests.timeline.generation + 1
  local requestGeneration = requests.timeline.generation
  request("/v1/timeline?limit=20", nil, function(ok, _, data)
    if requestGeneration ~= requests.timeline.generation then
      return
    end
    requests.timeline.pending = false
    snapshot.timelineState = ok and data and type(data.items) == "table" and "ready" or "offline"
    -- Publish only display fields; never paths, clipboard details or targets.
    snapshot.timeline = {}
    if snapshot.timelineState == "ready" then
      for _, item in ipairs(data.items) do
        if type(item) == "table" and type(item.deviceId) == "string" then
          table.insert(snapshot.timeline, {
            id = item.id,
            deviceId = item.deviceId,
            kind = item.kind,
            title = item.title,
            direction = item.direction,
            timestamp = type(item.timestamp) == "number" and item.timestamp or nil,
          })
        end
      end
    end
    publish()
  end)
end

local function pollNotifications(warm)
  if
    (not homeActive() and not warm)
    or snapshot.privateMessages == false
    or noctalia.getConfig("panel_notifications") == false
    or requests.notifications.pending
  then
    return
  end
  requests.notifications.pending = true
  requests.notifications.started = clock.ticks
  requests.notifications.generation = requests.notifications.generation + 1
  local requestGeneration = requests.notifications.generation
  request("/v1/notifications", nil, function(ok, status, data)
    if requestGeneration ~= requests.notifications.generation then
      return
    end
    requests.notifications.pending = false
    snapshot.notificationsState = ok and data and type(data.notifications) == "table" and "ready"
      or (status == 404 and "unsupported" or "offline")
    snapshot.notifications = {}
    if snapshot.notificationsState == "ready" then
      for _, item in ipairs(data.notifications) do
        if
          type(item) == "table"
          and type(item.deviceId) == "string"
          and type(item.key) == "string"
          and access.allowsScope(snapshot.notificationPolicy, item.appScope)
        then
          table.insert(snapshot.notifications, {
            deviceId = item.deviceId,
            key = item.key,
            appName = item.appName,
            appScope = item.appScope,
            title = item.title,
            text = item.text,
            timestamp = type(item.timestamp) == "number" and item.timestamp or nil,
          })
        end
      end
    end
    publish()
  end)
end

local function pollSessions(warm)
  if
    (not homeActive() and not requests.sessions.refreshing and not warm)
    or requests.sessions.pending
  then
    return
  end
  requests.sessions.pending = true
  requests.sessions.started = clock.ticks
  requests.sessions.generation = requests.sessions.generation + 1
  local requestGeneration = requests.sessions.generation
  request("/v1/sessions", nil, function(ok, status, data)
    if requestGeneration ~= requests.sessions.generation then
      return
    end
    requests.sessions.pending = false
    snapshot.sessions = {}
    snapshot.sessionsState = ok and data and type(data.devices) == "table" and "ready"
      or (status == 404 and "unsupported" or "offline")
    if snapshot.sessionsState == "ready" then
      for _, device in ipairs(data.devices) do
        if type(device) == "table" and type(device.id) == "string" then
          local view = { allowed = {} }
          for _, kind in ipairs(sessionKinds) do
            view[kind] = type(device[kind]) == "string" and device[kind] or "off"
            view.allowed[kind] = type(device.allowed) == "table" and device.allowed[kind] == true
          end
          snapshot.sessions[device.id] = view
        end
      end
    end
    if requests.sessions.refreshing then
      requests.sessions.refreshing = false
      snapshot.sessionBusy = false
    end
    publish()
  end)
end

local function acceptDeviceList(devices)
  local known = {}
  for _, device in ipairs(devices) do known[device.id] = true end
  for id in pairs(knownDevices) do
    if not known[id] then
      invalidateKind(id)
      knownAppAccess[id] = nil
      warmup.forget(id)
      if visibility.activePage and visibility.activePage.device == id then
        visibility.activePage, visibility.threads = nil, nil
      end
      snapshot.pageRevocations = snapshot.pageRevocations or {}
      for _, section in ipairs({ "messages", "photos", "apps", "calls", "sms" }) do
        local scope = section .. ":" .. id
        if snapshot.deniedPages then snapshot.deniedPages[scope] = nil end
        snapshot.pageRevocations[scope] = nil
      end
      local scope = "device:" .. id
      snapshot.pageRevocations[scope] = (snapshot.pageRevocations[scope] or 0) + 1
      if snapshot.smsDenied then snapshot.smsDenied[id] = nil end
    end
  end
  knownDevices = known
  snapshot.state, snapshot.error, snapshot.devices = "ready", nil, devices
  for _, device in ipairs(devices) do
    pages.setSmsAccess(device.id, device.smsAllowed)
    local current, previous = device.appWindowsAllowed, knownAppAccess[device.id]
    if type(current) == "boolean" then
      knownAppAccess[device.id] = current
      if current and (previous ~= true or
        (snapshot.deniedPages and snapshot.deniedPages["apps:" .. device.id]))
      then
        pages.allowApps(device.id)
        warmup.rearm("apps", device.id)
      elseif not current and previous ~= false
        and not (snapshot.deniedPages and snapshot.deniedPages["apps:" .. device.id])
      then
        pages.deny(device.id, "apps", "permission")
      end
    end
  end
end

local function cancelNotifications()
  requests.notifications.generation = requests.notifications.generation + 1
  requests.notifications.pending = false
end

local function acceptPrivateAccess(data)
  local previousPrivate, previousEpoch = snapshot.privateMessages, snapshot.privateReadEpoch
  snapshot.privateMessages = data.privateMessages
  snapshot.privateReadEpoch = type(data.privateReadEpoch) == "string" and data.privateReadEpoch or nil
  if data.privateMessages == false then
    if previousPrivate ~= false then
      cancelNotifications()
      snapshot.notifications, snapshot.notificationsState = {}, "offline"
    end
    snapshot.notificationPolicy = nil
    if not snapshot.messagesDenied then pages.deny(nil, "messages", "private_api_disabled") end
    return
  end
  if previousPrivate == false and data.privateMessages == true then
    pages.allowPrivate()
    warmup.rearm("messages")
  elseif previousEpoch and snapshot.privateReadEpoch and previousEpoch ~= snapshot.privateReadEpoch then
    -- Off and on between polls is still a confirmed revocation.
    cancelNotifications()
    snapshot.notifications, snapshot.notificationsState = {}, nil
    pages.revokePrivate()
    pages.allowPrivate()
    warmup.rearm("messages")
  end
  local policy = access.policy(data.notificationPolicy)
  local previous = snapshot.notificationPolicy
  if not access.policyChanged(previous, policy) then return end
  local previousInstance = previous and previous.instance ~= policy.instance
  snapshot.notificationPolicy = policy
  cancelNotifications()
  local kept = {}
  for _, notice in ipairs(snapshot.notifications or {}) do
    if access.allowsScope(policy, notice.appScope, previousInstance) then kept[#kept + 1] = notice end
  end
  snapshot.notifications = kept
  pages.setNotificationPolicy(policy, previousInstance)
end

local function poll()
  if requests.devices.pending then
    return
  end
  local config, credentialError = credentials()
  if not config then
    resetPages()
    snapshot.state = "unconfigured"
    snapshot.error = credentialError
    snapshot.devices = {}
    snapshot.timeline = {}
    snapshot.timelineState = nil
    requests.timeline.generation = requests.timeline.generation + 1
    requests.timeline.pending = false
    snapshot.notifications = {}
    requests.notifications.generation = requests.notifications.generation + 1
    requests.notifications.pending = false
    snapshot.sessions = {}
    snapshot.sessionsState = "offline"
    requests.sessions.generation = requests.sessions.generation + 1
    requests.sessions.pending = false
    publish()
    return
  end
  requests.devices.pending = true
  requests.devices.generation = requests.devices.generation + 1
  local requestGeneration = requests.devices.generation
  request("/v1/devices", nil, function(ok, status, data, reason)
    if requestGeneration ~= requests.devices.generation then
      return
    end
    requests.devices.pending = false
    local valid = ok and type(data) == "table" and type(data.devices) == "table"
      and (data.devicesReady == nil or type(data.devicesReady) == "boolean")
    if valid then
      for index, device in pairs(data.devices) do
        if
          type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #data.devices
          or type(device) ~= "table"
          or type(device.id) ~= "string"
          or (device.appWindowsAllowed ~= nil and type(device.appWindowsAllowed) ~= "boolean")
          or (device.battery ~= nil and type(device.battery) ~= "table")
        then
          valid = false
          break
        end
      end
    end
    if valid then
      local waitForDevices = data.devicesReady == false
        or (data.devicesReady == nil and next(knownDevices) ~= nil and #data.devices == 0 and not legacyEmpty)
      legacyEmpty = data.devicesReady == nil and #data.devices == 0
      snapshot.localMessageThreads = data.localMessageThreads == true
      snapshot.pageCacheV2 = data.pageCacheV2 == true
      acceptPrivateAccess(data)
      if waitForDevices then
        snapshot.state, snapshot.error, snapshot.devices = "offline", nil, {}
      else
        acceptDeviceList(data.devices)
      end
    else
      legacyEmpty = false
      snapshot.state = status == 401 and "unauthorized" or "offline"
      snapshot.error = reason or (ok and "invalid_response" or "api_unavailable")
      if status == 401 then
        resetPages()
      end
      snapshot.devices = {}
      snapshot.timeline = {}
      snapshot.timelineState = "offline"
      requests.timeline.generation = requests.timeline.generation + 1
      requests.timeline.pending = false
      snapshot.notifications = {}
      snapshot.notificationsState = "offline"
      requests.notifications.generation = requests.notifications.generation + 1
      requests.notifications.pending = false
      snapshot.sessions = {}
      snapshot.sessionsState = "offline"
      requests.sessions.generation = requests.sessions.generation + 1
      requests.sessions.pending = false
    end
    if requests.ring.refreshing then
      requests.ring.refreshing = false
      snapshot.ringBusy = false
    end
    if requests.controls.refreshing then
      requests.controls.refreshing = false
      snapshot.controlBusy = false
    end
    publish()
  end, config)
end

local function launch(task)
  local executable = noctalia.getConfig("executable")
  if not executable or executable == "" then
    executable = "nectarlink-desktop"
  end
  if executable ~= "nectarlink-desktop" and executable:sub(1, 1) ~= "/" then
    noctalia.notifyError("NectarLink", noctalia.tr("notifications.absolute_path"))
    return
  end
  local command = { executable }
  if task then
    table.insert(command, "--task")
    table.insert(command, task)
  end
  -- Without a callback Noctalia detaches the process. Direct argv avoids shell
  -- parsing and the captured-process timeout; no Python helper is required.
  if not noctalia.runAsync(command) then
    noctalia.notifyError("NectarLink", noctalia.tr("notifications.launch_failed"))
  end
end
local commandHandlers =
  require("./service/actions.luau").new(snapshot, requests, clock, visibility, {
    request = request,
    publish = publish,
    onlineDevice = onlineDevice,
    invalidateKind = invalidateKind,
    readPage = readPage,
    poll = poll,
    pollSessions = pollSessions,
    sessionKinds = sessionKinds,
  })
local handlePageAction = commandHandlers.handlePageAction
local handleSessionCommand = commandHandlers.handleSessionCommand
local handleTextInput = commandHandlers.handleTextInput
local handlePhoneToggle = commandHandlers.handlePhoneToggle
local handleCameraCommand = commandHandlers.handleCameraCommand
local handleRingCommand = commandHandlers.handleRingCommand
local knownPages = { messages = true, calls = true, photos = true, apps = true, deck = true }
local function validPage(v)
  return type(v) == "table" and knownPages[v.page] and type(v.key) == "string"
    and (v.thread == nil or type(v.thread) == "string")
    and (v.offset == nil or (type(v.offset) == "number" and v.offset % 1 == 0 and v.offset >= 0 and v.offset <= 5000))
    and (v.limit == nil or (type(v.limit) == "number" and v.limit % 1 == 0 and v.limit >= 1 and v.limit <= 96))
end

noctalia.state.watch("nl.command", function(raw)
  local cmd = decode(raw)
  if type(cmd) ~= "table" then
    return
  end
  if cmd.action == "page" then
    local v = cmd.value
    if not validPage(v) or type(cmd.device) ~= "string" then
      return
    end
    -- A page command is also an explicit panel-open signal. State watchers may
    -- coalesce the earlier visible command in the same frame; never drop the read.
    visibility.open = true
    visibility.device = cmd.device
    visibility.section = v.page
    visibility.activePage = cmd
    visibility.threads = nil
    if v.page == "messages" and v.thread and v.thread ~= "" and validPage(v.threads)
      and v.threads.page == "messages" and (v.threads.thread or "") == ""
    then
      visibility.threads = { device = cmd.device, value = v.threads }
    end
    if not visibility.threads or not snapshot.threads or snapshot.threads.key ~= v.threads.key then
      snapshot.threads = nil
    end
    pages.cancelInactiveRefreshes()
    if visibility.threads then readPage(visibility.threads, false, v.force == true, "threads") end
    readPage(cmd, false)
  elseif cmd.action == "page_leave" then
    visibility.activePage, visibility.threads = nil, nil
    pages.cancelInactiveRefreshes()
    visibility.section = cmd.value == "guide" and "guide" or "home"
    snapshot.page = nil
    snapshot.threads = nil
    publish()
  elseif cmd.action == "page_action" and type(cmd.value) == "table" then
    handlePageAction(cmd)
  elseif cmd.action == "visible" or cmd.action == "files_after_close" then
    local fileHandoff = cmd.action == "files_after_close"
    visibility.open = not fileHandoff and (cmd.value == true or (type(cmd.value) == "table" and cmd.value.open == true))
    if type(cmd.device) == "string" then visibility.device = cmd.device end
    if visibility.open then
      visibility.section = type(cmd.value) == "table" and cmd.value.page or "home"
    end
    poll()
    if not visibility.open then
      visibility.activePage, visibility.threads = nil, nil
      pages.cancelInactiveRefreshes()
      snapshot.threads = nil
      -- Keep a completed view so reopening this same page can draw it before
      -- the IPC cache reply. Pending/failed views must never stay stuck.
      if snapshot.page and snapshot.page.status == "ready" and not snapshot.page.partial then
        snapshot.page.refreshing = false
      else
        snapshot.page = nil
      end
      publish()
    end
    if visibility.open then
      pollTimeline()
      pollNotifications()
      pollSessions()
    elseif fileHandoff and canTransfer() and snapshot.devices[1].id == cmd.device then
      launch("send-files")
    end
  elseif cmd.action == "refresh" then
    poll()
    pollTimeline()
    pollNotifications()
    pollSessions()
  elseif cmd.action == "open" then
    launch(nil)
  elseif cmd.action == "open_fork" then
    -- Explicit click and fixed URL only; no downloads, installation or shell.
    local url = "https://github.com/vladikchi/nectarlink-noctalia/tree/noctalia"
    if not noctalia.runAsync({ "xdg-open", url }) then
      noctalia.notifyError(
        "NectarLink",
        noctalia.tr(
          "notifications.browser_failed",
          { url = url }
        )
      )
    end
  elseif cmd.action == "timeline" then
    launch("open-timeline")
  elseif cmd.action == "clipboard" and canTransfer() then
    launch("send-clipboard")
  elseif cmd.action == "session" and type(cmd.value) == "table" then
    handleSessionCommand(cmd)
  elseif cmd.action == "type_text" and type(cmd.value) == "string" then
    handleTextInput(cmd)
  elseif cmd.action == "phone_toggle" and type(cmd.value) == "table" then
    handlePhoneToggle(cmd)
  elseif cmd.action == "camera" and type(cmd.device) == "string" and onlineDevice(cmd.device) then
    handleCameraCommand(cmd)
  elseif cmd.action == "ring" and type(cmd.device) == "string" and onlineDevice(cmd.device) then
    handleRingCommand(cmd)
  end
end)

-- The timer only reads and releases stalled busy flags. Expiring an action
-- advances its generation without resending the action.

function update()
  -- Schedule reads and expire waits; an expired action may have reached the phone.
  noctalia.setUpdateInterval(limits.updateIntervalMs)
  clock.ticks = clock.ticks + 1
  -- One small read-only Home warmup for this API binding. Going offline
  -- briefly does not put Home (or any of the other tabs) back in the queue.
  local cacheEpoch = snapshot.cacheEpoch or 0
  if snapshot.state == "ready" and visibility.warmedHome ~= cacheEpoch then
    for _, d in ipairs(snapshot.devices) do
      if d.online then
        if not visibility.open then
          visibility.warmedHome = cacheEpoch
          pollTimeline(true)
          pollNotifications(true)
          pollSessions(true)
        elseif homeActive() then
          visibility.warmedHome = cacheEpoch
        end
        break
      end
    end
  end
  pages.expire()
  if snapshot.pageActionBusy and clock.ticks - requests.actions.started >= limits.timeoutTicks then
    requests.actions.generation = requests.actions.generation + 1
    snapshot.pageActionBusy = false
    snapshot.pageActionResult = nil
    noctalia.notifyError("NectarLink", noctalia.tr("notifications.action_timeout"))
    publish()
  end
  if
    requests.sessions.pending and clock.ticks - requests.sessions.started >= limits.timeoutTicks
  then
    requests.sessions.generation = requests.sessions.generation + 1
    requests.sessions.pending = false
    snapshot.sessions = {}
    snapshot.sessionsState = "offline"
    publish()
  end
  if
    snapshot.sessionBusy and clock.ticks - requests.sessions.commandStarted >= limits.timeoutTicks
  then
    requests.sessions.commandGeneration = requests.sessions.commandGeneration + 1
    snapshot.sessionBusy = false
    requests.sessions.refreshing = false
    requests.sessions.generation = requests.sessions.generation + 1
    requests.sessions.pending = false
    noctalia.notifyError("NectarLink", noctalia.tr("notifications.session_timeout"))
    publish()
    pollSessions()
  end
  if snapshot.typeBusy and clock.ticks - requests.typing.started >= limits.timeoutTicks then
    requests.typing.generation = requests.typing.generation + 1
    snapshot.typeBusy = false
    noctalia.notifyError("NectarLink", noctalia.tr("notifications.type_timeout"))
    publish()
  end
  if snapshot.controlBusy and clock.ticks - requests.controls.started >= limits.timeoutTicks then
    requests.controls.generation = requests.controls.generation + 1
    requests.controls.refreshing = false
    snapshot.controlBusy = false
    requests.devices.generation = requests.devices.generation + 1
    requests.devices.pending = false
    noctalia.notifyError("NectarLink", noctalia.tr("notifications.toggle_timeout"))
    publish()
    poll()
  end
  if snapshot.cameraBusy and clock.ticks - requests.camera.started >= limits.timeoutTicks then
    requests.camera.generation = requests.camera.generation + 1
    snapshot.cameraBusy = false
    noctalia.notifyError("NectarLink", noctalia.tr("notifications.camera_timeout"))
    publish()
  end
  if
    requests.timeline.pending and clock.ticks - requests.timeline.started >= limits.timeoutTicks
  then
    requests.timeline.generation = requests.timeline.generation + 1
    requests.timeline.pending = false
    snapshot.timeline = {}
    snapshot.timelineState = "offline"
    publish()
  end
  if
    requests.notifications.pending
    and clock.ticks - requests.notifications.started >= limits.timeoutTicks
  then
    requests.notifications.generation = requests.notifications.generation + 1
    requests.notifications.pending = false
    snapshot.notifications = {}
    snapshot.notificationsState = "offline"
    publish()
  end
  if snapshot.ringBusy and clock.ticks - requests.ring.started >= limits.timeoutTicks then
    requests.ring.generation = requests.ring.generation + 1
    requests.ring.refreshing = false
    snapshot.ringBusy = false
    requests.devices.generation = requests.devices.generation + 1
    requests.devices.pending = false
    noctalia.notifyError("NectarLink", noctalia.tr("notifications.ring_timeout"))
    publish()
    poll()
  end
  -- Release a stuck device read every 15 ticks (normally 30 seconds).
  -- This does not resend any phone action.
  if clock.ticks % 15 == 0 and requests.devices.pending then
    requests.devices.generation = requests.devices.generation + 1
    requests.devices.pending = false
  end
  if
    (visibility.open and clock.ticks % 2 == 0) or (not visibility.open and clock.ticks % 15 == 1)
  then
    poll()
  end
  if homeActive() and clock.ticks % 5 == 1 then
    pollTimeline()
  end
  if homeActive() and clock.ticks % 3 == 1 then
    pollNotifications()
  end
  if homeActive() and clock.ticks % 2 == 0 then
    pollSessions()
  end
  if visibility.open and visibility.activePage and onlineDevice(visibility.activePage.device) then
    local current = visibility.activePage
    if visibility.activePage.value.page == "calls" and clock.ticks % 3 == 0 then
      readPage(current, true, true)
    elseif clock.ticks % 5 == 0 and (not pages.isIndex(current) or (current.value.offset or 0) == 0) then
      readPage(current, true, false)
      if visibility.threads and pages.isIndex(visibility.threads) and (visibility.threads.value.offset or 0) == 0 then
        readPage(visibility.threads, true, false, "threads")
      end
    end
  end
  warmup.update()
end

function onConfigChanged()
  -- Geometry already has a different cache key. Unrelated settings should
  -- not discard photos, conversations or their navigation history.
  local active = visibility.activePage
  if active and active.value.page == "apps" and active.value.limit ~= geometry.appsLayout().limit then
    visibility.activePage = nil
  end
  requests.devices.generation = requests.devices.generation + 1
  requests.devices.pending = false
  requests.timeline.generation = requests.timeline.generation + 1
  requests.timeline.pending = false
  requests.notifications.generation = requests.notifications.generation + 1
  requests.notifications.pending = false
  requests.sessions.generation = requests.sessions.generation + 1
  requests.sessions.pending = false
  if noctalia.getConfig("panel_timeline") == false then
    snapshot.timeline = {}
    snapshot.timelineState = nil
    publish()
  end
  if noctalia.getConfig("panel_notifications") == false then
    snapshot.notifications = {}
    snapshot.notificationsState = nil
    publish()
  end
  poll()
  pollTimeline()
  pollNotifications()
  pollSessions()
end
