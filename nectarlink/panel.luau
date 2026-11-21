--!nonstrict
-- Panel controller: device selection, navigation, drafts and Noctalia entry points.
-- ui/*.luau builds the interface; only the service handles HTTP and credentials.
local palette = require("./ui/palette.luau")
local model = {
  -- snapshot is service input; all other fields are local UI state.
  snapshot = { state = "unconfigured", devices = {} },
  opened = false,
  selected = nil,
  hovered = nil,
  nonce = 0,
  renderedTree = nil,
  appHoverNodes = {},
  tileWidth = 180,
  confirmWifi = nil,
  hotspotMenu = nil,
  -- Drafts belong to a device/thread; transport-only acknowledgement never clears them.
  drafts = {},
  sentDrafts = {},
  draftRevisions = {},
  lastTypeSent = nil,
  pageDrafts = {},
  recipient = "",
  pendingAction = nil,
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
  album = nil,
  search = "",
  searchDraft = "",
  guideTopic = 1,
  dialOpen = false,
  pageHeight = 398,
  lastCacheEpoch = nil,
  appsSignature = nil,
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
local components = Components.new(model, send)
local activeSession = components.activeSession
local setting = components.setting
local appsLayout = components.appsLayout
local titles = components.titles
local memory = require("./ui/page_memory.luau").new(model)
local function decode(raw)
  if not raw then
    return nil
  end
  local ok, value = pcall(noctalia.json.decode, raw)
  return ok and type(value) == "table" and type(value.devices) == "table" and value or nil
end

local function resetPage()
  model.dialOpen = false
  model.pageKey = nil
  model.pageRequested = false
  model.offset = 0
  model.cursors = {}
  model.before = nil
  model.beforeId = nil
  model.thread = nil
  model.album = nil
  model.pendingAction = nil
  model.detail = nil
  model.search = ""
  model.searchDraft = ""
  model.recipient = ""
  model.pageView = nil
end

local function loadPage(force)
  -- Bind each key to its device and filters. A late response for the previous
  -- page must not replace the current one; force is an explicit read only.
  if
    model.page == "home"
    or model.page == "guide"
    or not model.selected
    or model.snapshot.state == "unauthorized"
    or model.snapshot.state == "unconfigured"
  then
    return
  end
  if model.page == "messages" and model.thread and model.thread.id == "" then
    return
  end
  local limit = model.page == "messages" and (model.thread and 6 or 7)
    or (model.page == "calls" and 6 or (model.page == "apps" and appsLayout().limit or nil))
  local fields = {
    model.page,
    model.selected,
    model.thread and model.thread.id or "",
    tostring(model.offset),
    tostring(model.before),
    model.beforeId or "",
    model.album or "",
    model.search,
    tostring(limit or 0),
  }
  for i, value in ipairs(fields) do
    fields[i] = tostring(#value) .. ":" .. value
  end
  local key = table.concat(fields)
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
  send("page", model.selected, {
    key = key,
    page = model.page,
    thread = model.thread and model.thread.id or nil,
    offset = model.offset,
    before = model.before,
    before_id = model.beforeId,
    album = model.album,
    search = model.search,
    limit = limit,
    force = force == true,
  })
end

local function navigate(value)
  if not model.opened or not titles[value] or model.page == value then
    return
  end
  memory.remember(model.pageView)
  memory.save(model.pageDevice, model.page)
  model.page = value
  resetPage()
  memory.restore(model.selected, value)
  if value == "home" or value == "guide" then
    send("page_leave", nil, value)
  end
  render()
end

local function confirmAction(action, id, text, recipients, title)
  -- Capture the recipient before showing confirmation, not at send time.
  model.pendingAction = {
    action = action,
    id = id,
    text = text,
    recipients = recipients,
    title = title,
    device = model.selected,
  }
  render()
end

local function dispatchPageAction(action, id, text, recipients, device)
  local requestId = ""
  for _ = 1, 8 do
    requestId = requestId .. string.format("%04x", math.random(0, 65535))
  end
  send("page_action", device or model.selected, {
    action = action,
    id = id,
    text = text,
    recipients = recipients,
    request_id = requestId,
    confirm = true,
  })
end
-- Explicit dependencies only; modules cannot read controller globals.
local actions = {
  send = send,
  render = function()
    render()
  end,
  resetPage = resetPage,
  loadPage = loadPage,
  confirmAction = confirmAction,
  dispatchPageAction = dispatchPageAction,
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
      and (activeSession(session, kind) or (online and session.allowed[kind])) == true
  end
  if model.snapshot.typeSent and model.snapshot.typeSent ~= model.lastTypeSent then
    model.lastTypeSent = model.snapshot.typeSent
    local id = model.snapshot.typeSentDevice
    if id and model.drafts[id] == model.sentDrafts[id] then
      model.drafts[id] = ""
      model.draftRevisions[id] = (model.draftRevisions[id] or 0) + 1
    end
  end
  if model.selected ~= model.confirmWifi then
    model.confirmWifi = nil
  end
  if model.selected ~= model.hotspotMenu then
    model.hotspotMenu = nil
  end
  local unavailable = not ready and noctalia.tr("common.no_connection")
    or (not phone and noctalia.tr("common.connect_phone") or noctalia.tr("common.phone_offline"))
  local notices = {}
  if
    ready
    and phone
    and setting("panel_notifications")
    and model.snapshot.notificationsState == "ready"
  then
    for _, item in ipairs(model.snapshot.notifications or {}) do
      if item.deviceId == phone.id then
        table.insert(notices, item)
      end
    end
  end
  -- Match the fixed manifest width, host padding (16 per side), root padding
  -- (3 per side), optional 42px rail + gap, and 260px right column + gap.
  local showControls = setting("panel_controls")
  local showTimeline = ready and phone and setting("panel_timeline")
  local sidebar = showControls or showTimeline
  local mainWidth = geometry.panelWidth
    - geometry.hostPadding * 2
    - geometry.framePadding * 2
    - (setting("panel_navigation") and geometry.navigationSpace or 0)
    - (sidebar and geometry.sidebarSpace or 0)
  model.tileWidth = math.floor((mainWidth - 30) / 4)
  mainWidth = model.tileWidth * 4 + 30
  local header = frame.header()
  if model.page ~= "home" then
    local width = geometry.panelWidth
      - geometry.hostPadding * 2
      - geometry.framePadding * 2
      - (setting("panel_navigation") and geometry.navigationSpace or 0)
    renderFrame(header, {
      ui.column({
        key = "page-layout-" .. model.page,
        width = width,
        height = geometry.pageHeight,
        align = "start",
      }, { sidebarPage(phone, online, width) }),
    })
    return
  end
  renderHomePage({
    phone = phone,
    online = online,
    ready = ready,
    session = session,
    canSession = canSession,
    unavailable = unavailable,
    notices = notices,
    showControls = showControls,
    showTimeline = showTimeline,
    sidebar = sidebar,
    mainWidth = mainWidth,
    header = header,
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
        model.appHoverNodes[old].props.fill = "transparent"
      end
      if nextHover then
        model.appHoverNodes[nextHover].props.fill = palette("raised")
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
  model.snapshot = value
  if model.snapshot.cacheEpoch ~= model.lastCacheEpoch then
    -- Auth changes and service resets invalidate the read key, not the draft.
    model.lastCacheEpoch = model.snapshot.cacheEpoch
    memory.clear()
    resetPage()
    model.pageKey = nil
  end
  if value.state == "unauthorized" or value.state == "unconfigured" then
    memory.clear()
    resetPage()
  else
    memory.remember(value.page)
    if model.pageKey then
      model.pageView = memory.resolve(model.pageKey, value.state == "ready" and value.page or nil)
      if value.state ~= "ready" and model.pageView then
        model.pageView.refreshing = false
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
  model.confirmWifi = nil
  model.hotspotMenu = nil
  acceptSnapshot(noctalia.state.get("nl.snapshot") or latestRaw)
  model.pageKey = nil
  send("visible", nil, { open = true, page = model.page })
  render()
end

function onClose()
  model.installCopyStatus = nil
  memory.remember(model.pageView)
  memory.save(model.pageDevice, model.page)
  model.opened = false
  model.hovered = nil
  model.pageKey = nil
  model.pendingAction = nil
  model.detail = nil
  send("visible", nil, false)
end

function onConfigChanged()
  render()
end
