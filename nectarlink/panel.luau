--!nonstrict
-- Panel controller: device selection, navigation, drafts and Noctalia entry points.
-- ui/*.luau builds the interface; only the service handles HTTP and credentials.
local model = {
  -- snapshot is service input; all other fields are local UI state.
  snapshot = { state = "unconfigured", devices = {} },
  opened = false,
  selected = nil,
  hovered = nil,
  nonce = 0,
  renderedTree = nil,
  appHoverNodes = {},
  hotspotMenu = nil,
  -- Drafts belong to a device/thread; transport-only acknowledgement never clears them.
  drafts = {},
  sentDrafts = {},
  draftRevisions = {},
  lastTypeSent = nil,
  pageDrafts = {},
  pageDraftRevisions = {},
  actionScope = 0, -- Invalidate click handlers when the panel, phone or credentials change.
  actionAttempts = { page = 0, control = 0 },
  actionReceipts = {},
  recipient = "",
  detail = nil,
  detailPart = 0,
  -- Keep offsets and cursors separate: API pages use different pagination schemes.
  page = "home",
  pageKey = nil,
  pageDevice = nil,
  offset = 0,
  cursors = {},
  before = nil,
  beforeId = nil,
  thread = nil,
  threadList = { offset = 0, cursors = {} },
  album = nil,
  search = "",
  searchDraft = "",
  guideTopic = 1,
  lastCacheEpoch = nil,
  appsSignature = nil,
  fileHandoff = nil,
}
local render

local function send(action, device, value)
  model.nonce = model.nonce + 1
  noctalia.state.set(
    "nl.command",
    noctalia.json.encode({ n = model.nonce, action = action, device = device, value = value })
  )
end
local Components = require("./ui/components.luau")
local geometry = Components.layout
local components = Components.new()
local activeSession = components.activeSession
local setting = components.setting
local appsLayout = components.appsLayout
local titles = components.titles
local memory = require("./ui/page_memory.luau").new(model)
local access = require("./message_access.luau")
local function decode(raw)
  if not raw then
    return nil
  end
  local ok, value = pcall(noctalia.json.decode, raw)
  return ok and type(value) == "table" and type(value.devices) == "table" and value or nil
end

local function resetPage()
  model.actionScope = model.actionScope + 1
  model.pageKey = nil
  model.pageRequested = false
  model.offset = 0
  model.cursors = {}
  model.before = nil
  model.beforeId = nil
  model.thread = nil
  model.threadList = { offset = 0, cursors = {} }
  model.album = nil
  model.detail = nil
  model.search = ""
  model.searchDraft = ""
  model.recipient = ""
  model.pageView = nil
end

local function pageQuery(page, thread, nav, limit, album, search)
  local fields = {
    page,
    model.selected,
    thread or "",
    tostring(nav.offset),
    tostring(nav.before),
    nav.beforeId or "",
    album or "",
    search or "",
    tostring(limit or 0),
  }
  for i, value in ipairs(fields) do
    fields[i] = tostring(#value) .. ":" .. value
  end
  return {
    key = table.concat(fields), page = page, thread = thread, offset = nav.offset,
    before = nav.before, before_id = nav.beforeId, limit = limit, album = album, search = search or "",
  }
end

local limits = geometry.page.limits
local function threadsQuery()
  return pageQuery("messages", nil, model.threadList, limits.messages)
end

local function loadPage(force)
  -- One command binds both panes to the same phone and selection.
  local page = model.page
  if page == "home" or page == "guide" or not model.selected
    or model.snapshot.state == "unauthorized" or model.snapshot.state == "unconfigured" then
    return
  end
  local thread = model.thread and model.thread.id ~= "" and model.thread.id or nil
  local query
  if page == "messages" and not thread then
    query = threadsQuery()
  else
    local limit = page == "messages" and limits.thread
      or (page == "calls" and limits.calls or (page == "apps" and appsLayout().limit or nil))
    query = pageQuery(page, thread, model, limit, model.album, model.search)
  end
  local key = query.key
  if model.pageKey == key and not force and model.pageRequested then
    return
  end
  model.pageKey = key
  -- Restore the local view BEFORE inter-entry dispatch: state.watch responds
  -- later even when the service can answer without HTTP.
  model.pageView =
    memory.resolve(key, model.snapshot.state == "ready" and model.snapshot.page or nil)
  model.pageRequested = model.snapshot.state == "ready"
  if not model.pageRequested then
    if model.pageView then
      model.pageView.refreshing = false
    end
    return
  end
  query.force = force == true
  if page == "messages" and thread then query.threads = threadsQuery() end
  send("page", model.selected, query)
end

local function sectionDenied(snapshot, page, device)
  return (page == "messages" and snapshot.messagesDenied == true)
    or (page and device and snapshot.deniedPages and snapshot.deniedPages[page .. ":" .. device] == true)
end

local function threadsView()
  if not model.selected then return nil end
  local key = threadsQuery().key
  local view = model.pageView
  if view and view.key == key then return view end
  view = model.snapshot.threads
  if view and view.key == key and (view.status == "ready" or sectionDenied(model.snapshot, "messages", model.selected)) then
    return view
  end
  if sectionDenied(model.snapshot, "messages", model.selected) then return nil end
  if view and view.key == key then return memory.resolve(key, view) end
  return memory.saved(key)
end

local function selectThread(thread, threadList)
  if not model.opened or model.page ~= "messages" then return end
  if thread and access.chatThread(thread.id)
    and not access.allowsScope(model.snapshot.notificationPolicy, thread.appScope) then return end
  if thread and (thread.kind == "sms" or access.smsThread(thread.id))
    and model.snapshot.smsDenied and model.snapshot.smsDenied[model.selected]
  then return end
  memory.remember(model.pageView)
  if threadList then model.threadList = threadList end
  model.thread = thread
  model.offset, model.before, model.beforeId = 0, nil, nil
  model.cursors = {}
  model.detail, model.detailPart = nil, 0
  render()
end

local function navigate(value)
  if not model.opened or not titles[value] or model.page == value then
    return
  end
  memory.remember(model.pageView)
  memory.save(model.pageDevice, model.page)
  model.page = value
  model.hovered = nil
  model.hotspotMenu = nil
  resetPage()
  memory.restore(model.selected, value)
  if value == "home" or value == "guide" then
    send("page_leave", nil, value)
  end
  render()
end

local actionChannels = {
  page = { busy = "pageActionBusy", receipt = "pageActionRequestId", command = "page_action" },
  control = { busy = "controlBusy", receipt = "controlRequestId", command = "phone_toggle" },
}

local function nowSeconds()
  return noctalia.nowMs and noctalia.nowMs() / 1000 or os.time()
end

local function actionBusy(channel)
  local pending = model.actionReceipts[channel]
  -- A command overwritten before the service sees it must not lock the UI
  -- forever. Expiring the local wait never replays the command.
  if pending and not pending.received and nowSeconds() - pending.started >= 30 then
    model.actionReceipts[channel] = nil
    pending = nil
  end
  return model.snapshot[actionChannels[channel].busy] == true or pending ~= nil, pending and pending.kind
end

local function onlinePhone(device)
  if not device or model.snapshot.state ~= "ready" then return nil end
  for _, phone in ipairs(model.snapshot.devices) do
    if phone.id == device and phone.online == true then return phone end
  end
end

local function openFiles(device, scope)
  if not model.opened or model.page ~= "home" or model.selected ~= device or model.actionScope ~= scope
    or model.fileHandoff
    or #model.snapshot.devices ~= 1 or not onlinePhone(device)
  then return end
  model.fileHandoff = device
  panel.close()
end

local function dispatch(channel, device, payload)
  local requestId = ""
  for _ = 1, 8 do
    requestId = requestId .. string.format("%04x", math.random(0, 65535))
  end
  -- Lock synchronously, before Noctalia delivers the click to the service.
  model.actionAttempts[channel] = model.actionAttempts[channel] + 1
  model.actionReceipts[channel] = { id = requestId, started = nowSeconds(), kind = payload.action or payload.id }
  payload.request_id = requestId
  send(actionChannels[channel].command, device, payload)
  render()
  return true
end

local function bindAction(channel, device)
  local page, scope, attempt = model.page, model.actionScope, model.actionAttempts[channel]
  return function(payload)
    -- A queued callback may belong to an old render, device or connection.
    if not model.opened or model.selected ~= device or model.page ~= page or model.actionScope ~= scope
      or model.actionAttempts[channel] ~= attempt or actionBusy(channel) then return false end
    local phone = onlinePhone(device)
    if channel == "page" then
      if payload.action ~= "deck" and not phone then return false end
      -- The API still needs this explicit-intent flag; it does not imply a dialog.
      payload.confirm = true
    else
      local controls = phone and phone.controls
      if not setting("panel_controls") or not controls or not controls.allowed
        or controls.allowed[payload.id] ~= true then return false end
      local state = controls.state and controls.state[payload.id]
      if payload.id == "ringer" then
        if (state ~= "ring" and state ~= "vibrate" and state ~= "silent") or state == payload.mode then return false end
      elseif payload.id ~= "hotspot" and (type(state) ~= "boolean" or state == payload.on) then
        return false
      end
      model.hotspotMenu = nil
    end
    return dispatch(channel, device, payload)
  end
end
-- Explicit dependencies only; modules cannot read controller globals.
local actions = {
  send = send,
  openFiles = openFiles,
  render = function()
    render()
  end,
  resetPage = resetPage,
  loadPage = loadPage,
  threadsView = threadsView,
  selectThread = selectThread,
  actionBusy = actionBusy,
  bindAction = bindAction,
  navigate = navigate,
}
local items = require("./ui/page_items.luau").new(model, components, actions)
local pages = require("./ui/pages.luau").new(model, components, actions, items)
local controls = require("./ui/phone_controls.luau").new(model, components, actions)
local frame = require("./ui/frame.luau").new(model, components, actions)
local home = require("./ui/home.luau").new(model, components, actions, controls, frame)
local sidebarPage = pages.render
local renderHomePage = home.render
local renderFrame = frame.render
render = function()
  if not model.opened then
    return
  end
  model.appHoverNodes = {}
  local ready = model.snapshot.state == "ready"
  local phone
  for _, d in ipairs(model.snapshot.devices) do
    if d.id == model.selected then
      phone = d
    end
  end
  if not phone then
    for _, d in ipairs(model.snapshot.devices) do
      if d.online then
        phone = d
        break
      end
    end
    phone = phone or model.snapshot.devices[1]
    -- A brief API outage removes devices without changing the cached page owner.
    -- A ready response without devices really does clear the selection.
    model.selected = phone and phone.id or (not ready and model.selected or nil)
  end
  local online = ready and phone ~= nil and phone.online == true
  if model.pageDevice ~= model.selected then
    memory.remember(model.pageView)
    memory.save(model.pageDevice, model.page)
    model.pageDevice = model.selected
    resetPage()
    memory.restore(model.selected, model.page)
  end
  local layout = appsLayout()
  local signature = tostring(layout.names) .. ":" .. tostring(layout.limit)
  if model.appsSignature ~= signature then
    model.appsSignature = signature
    if model.page == "apps" then
      model.pageKey = nil
      model.offset = 0
      model.cursors = {}
    end
  end
  loadPage()
  local session = phone and model.snapshot.sessions and model.snapshot.sessions[phone.id]
  local function canSession(kind)
    return not model.snapshot.sessionBusy
      and session
      and (activeSession(session, kind) or (online and session.allowed and session.allowed[kind])) == true
  end
  if model.snapshot.typeSent and model.snapshot.typeSent ~= model.lastTypeSent then
    model.lastTypeSent = model.snapshot.typeSent
    local id = model.snapshot.typeSentDevice
    if id and model.drafts[id] == model.sentDrafts[id] then
      model.drafts[id] = ""
      model.draftRevisions[id] = (model.draftRevisions[id] or 0) + 1
    end
  end
  if model.selected ~= model.hotspotMenu then
    model.hotspotMenu = nil
  end
  local unavailable = not ready and noctalia.tr("common.no_connection")
    or (not phone and noctalia.tr("common.connect_phone") or noctalia.tr("common.phone_offline"))
  local width = geometry.contentWidth(setting("panel_navigation"))
  if model.page ~= "home" then
    local settingsButton = not setting("panel_navigation") and frame.settingsButton() or nil
    renderFrame({ sidebarPage(phone, online, width, settingsButton) })
    return
  end
  renderHomePage({
    phone = phone,
    online = online,
    ready = ready,
    session = session,
    canSession = canSession,
    unavailable = unavailable,
    width = width,
  })
end

function onNavigate(value)
  navigate(value)
end

function onIpc(event, value)
  if event == "navigate" then
    onNavigate(value)
  end
end

function onTileHover(state, key)
  local nextHover = model.hovered
  if state == "true" then
    nextHover = key
  elseif model.hovered == key then
    nextHover = nil
  end
  if nextHover ~= model.hovered then
    local old = model.hovered
    model.hovered = nextHover
    if
      model.renderedTree
      and model.page == "apps"
      and (not old or model.appHoverNodes[old])
      and (not nextHover or model.appHoverNodes[nextHover])
    then
      if old then
        model.appHoverNodes[old].props.fill = components.appTileFill(false)
      end
      if nextHover then
        model.appHoverNodes[nextHover].props.fill = components.appTileFill(true)
      end
      panel.render(model.renderedTree)
    else
      render()
    end
  end
end
local latestRaw = nil
local function acceptSnapshot(raw)
  local value = decode(raw)
  if type(value) ~= "table" then
    return
  end
  local before = model.snapshot
  local old, current = before.pageRevocations or {}, value.pageRevocations or {}
  local function revoked(kind, device)
    if not kind then return false end
    local scope = device and kind .. ":" .. device or kind
    return old[kind] ~= current[kind] or old[scope] ~= current[scope]
  end
  local function removed(device)
    return device and revoked("device", device)
  end
  local function smsRevoked(device)
    return device and (revoked("sms", device) or (value.smsDenied and value.smsDenied[device]))
  end
  local function scrubSnapshotView(view)
    if not view or view.kind ~= "messages" or not value.smsDenied or not value.smsDenied[view.device] then
      return view
    end
    if access.smsThread(view.thread) then return nil end
    if view.thread == "" and view.data then view.data = access.withoutSms(view.data) end
    return view
  end
  value.page, value.threads = scrubSnapshotView(value.page), scrubSnapshotView(value.threads)
  local policy = value.notificationPolicy
  if access.policyChanged(before.notificationPolicy, policy) then
    local previousInstance = before.notificationPolicy and before.notificationPolicy.instance ~= policy.instance
    local function scrubNotificationView(view)
      if not view or view.kind ~= "messages" or not view.data then return view end
      if access.chatThread(view.thread) and not access.allowsScope(policy, view.data.appScope, previousInstance) then
        return nil
      end
      if view.thread == "" then view.data = access.withoutHiddenChats(view.data, policy, previousInstance) end
      return view
    end
    value.page, value.threads = scrubNotificationView(value.page), scrubNotificationView(value.threads)
    memory.revokeChats(policy, previousInstance)
    if model.page == "messages" then
      local thread = model.thread
      if thread and access.chatThread(thread.id)
        and not access.allowsScope(policy, thread.appScope, previousInstance)
      then
        -- Keep the left pane and its cursor, but close the revoked detail.
        model.actionScope = model.actionScope + 1
        model.thread, model.detail, model.detailPart = nil, nil, 0
        model.offset, model.before, model.beforeId, model.cursors = 0, nil, nil, {}
        model.pageKey, model.pageView = nil, nil
      end
      model.pageRequested = false
    end
  end
  if removed(model.selected) or revoked(model.page, model.selected)
    or (sectionDenied(value, model.page, model.selected) and not sectionDenied(before, model.page, model.selected))
  then
    resetPage()
  elseif sectionDenied(before, model.page, model.selected)
    and not sectionDenied(value, model.page, model.selected)
  then
    model.pageRequested = false
  elseif model.page == "messages" and model.selected and revoked("sms", model.selected) then
    if model.thread and (model.thread.kind == "sms" or access.smsThread(model.thread.id)) then
      resetPage()
    else
      model.pageRequested = false
    end
  end
  model.snapshot = value
  for name, channel in pairs(actionChannels) do
    local pending = model.actionReceipts[name]
    if pending then
      if value[channel.receipt] == pending.id then pending.received = true end
      if pending.received and value[channel.busy] ~= true then model.actionReceipts[name] = nil end
    end
  end
  if model.snapshot.cacheEpoch ~= model.lastCacheEpoch then
    -- Auth changes and service resets invalidate the read key, not the draft.
    model.lastCacheEpoch = model.snapshot.cacheEpoch
    model.actionReceipts = {}
    memory.clear()
    resetPage()
    model.pageKey = nil
  end
  if value.state == "unauthorized" or value.state == "unconfigured" then
    memory.clear()
    resetPage()
  else
    local known = {}
    if value.state == "ready" then
      for _, device in ipairs(value.devices) do known[device.id] = true end
    end
    local pageFailure = value.page and value.page.status == "failed" and value.page or nil
    local deniedChat = pageFailure and pageFailure.kind == "messages" and type(pageFailure.thread) == "string"
      and pageFailure.thread:sub(1, 5) == "chat:"
      and (pageFailure.error == "chat_unavailable" or pageFailure.error == "permission"
        or pageFailure.error == "feature_toggle_disabled" or pageFailure.error == "feature_unsupported"
        or pageFailure.error == "feature_update_phone" or pageFailure.error == "feature_update_desktop")
    if deniedChat and model.page == "messages" and model.selected == pageFailure.device
      and model.thread and model.thread.id == pageFailure.thread
    then
      model.detail, model.detailPart = nil, 0
    end
    memory.discard(function(saved)
      return (saved.device and value.state == "ready" and not known[saved.device])
        or (deniedChat and saved.device == pageFailure.device and saved.kind == "messages"
          and saved.thread == pageFailure.thread)
        or removed(saved.device)
        or sectionDenied(value, saved.kind, saved.device)
        or revoked(saved.kind, saved.device)
    end)
    memory.revokeSms(smsRevoked)
    memory.remember(value.page)
    if model.page == "messages" and model.selected and not sectionDenied(value, "messages", model.selected) then
      memory.remember(value.threads, threadsQuery().key)
    end
    if model.pageKey then
      model.pageView = memory.resolve(model.pageKey, value.state == "ready" and value.page or nil)
      if value.state ~= "ready" and model.pageView then
        model.pageView.refreshing = false
      end
      if model.page == "photos" and model.detail and model.pageView and model.pageView.data then
        for _, photo in ipairs(model.pageView.data.items or {}) do
          if photo.id == model.detail.id and photo.thumbnailPath ~= model.detail.thumbnailPath then
            model.detail = photo
            break
          end
        end
      end
    end
  end
end

noctalia.state.watch("nl.snapshot", function(raw)
  -- A hidden panel neither builds UI nor decodes every background snapshot.
  -- Retain only the latest raw input; drafts and navigation remain in memory.
  latestRaw = raw
  if not model.opened then
    return
  end
  acceptSnapshot(raw)
  render()
end)

function onOpen()
  model.opened = true
  model.hovered = nil
  model.hotspotMenu = nil
  acceptSnapshot(noctalia.state.get("nl.snapshot") or latestRaw)
  model.pageKey = nil
  send("visible", model.selected, { open = true, page = model.page })
  render()
end

function onClose()
  model.installCopyStatus = nil
  memory.remember(model.pageView)
  memory.save(model.pageDevice, model.page)
  model.opened = false
  model.actionScope = model.actionScope + 1
  model.hovered = nil
  model.pageKey = nil
  model.detail = nil
  model.hotspotMenu = nil
  local device = model.fileHandoff
  model.fileHandoff = nil
  if device then
    -- One state message carries both the close and its explicit file intent.
    send("files_after_close", device, false)
  else
    send("visible", model.selected, false)
  end
end

function onConfigChanged()
  if not setting("panel_controls") then
    model.hotspotMenu = nil
  end
  render()
end
