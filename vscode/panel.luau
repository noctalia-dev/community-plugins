--!nonstrict
-- VS Code panel - a thin client. It renders the service's "vscode.state" snapshot through
-- view_panel and turns clicks into one "vscode.request" each (with a fresh requestId).
--
-- ui_state is local to the panel (see view_panel.luau): shown starts at recent_count on
-- every open and Load more adds 10; input is the path box's text, and a new inputSeq
-- remounts the box empty (on open, and once the service has accepted a clone; a refused
-- URL stays in the box). expandedKey is the one row with its inline actions open; it
-- collapses on open and after an action.
--
-- After each render the panel sends `git {keys}` for the visible local rows when that set
-- changed (and again on every open, since the service caches git for 30 s).
--
-- Opening a project closes the panel. A path-box open waits for the service's answer:
-- the snapshot whose requestSeq covers it, closing only when it reports no error.

local view_panel = require("./view_panel.luau")

local STATE_KEY = "vscode.state"
local REQUEST_KEY = "vscode.request"

local snapshot = nil
local ui_state = { shown = 5, input = "", inputSeq = 0, cloneDir = "~/Projects" }
local isOpen = false
local requestId = 0
-- requests sent that the last snapshot's requestSeq does not cover yet
local expectedSeq, bootId = 0, nil
local closeAtSeq = nil -- close when a snapshot reaches this requestSeq without errors
local gitSig = nil
-- A sent clone waiting for its answer: the requestSeq that covers it (see settleClone).
local awaitingClone = nil
local dismissAfterOpen = false -- Open existing: clear the exists line once the open worked

local render -- forward

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function recentCount()
  local n = tonumber(noctalia.getConfig("recent_count"))
  if n == nil or n < 1 then
    return 5
  end
  return math.floor(n)
end

local function cloneDir()
  local d = noctalia.getConfig("clone_dir")
  if type(d) ~= "string" or d == "" then
    return "~/Projects"
  end
  return d
end

local function send(request)
  local copy = {}
  for k, v in pairs(request) do
    copy[k] = v
  end
  requestId = requestId + 1
  copy.requestId = requestId
  expectedSeq = expectedSeq + 1
  noctalia.state.set(REQUEST_KEY, copy)
end

local function resetInput()
  ui_state.input = ""
  ui_state.inputSeq = ui_state.inputSeq + 1
end

-- Clears the box once the service answered the clone: running / exists with no error means
-- accepted; anything else (busy_clone, bad_url, no_git, clone_dir) keeps the text to fix.
local function settleClone(snap)
  if awaitingClone == nil or (tonumber(snap.requestSeq) or 0) < awaitingClone then
    return
  end
  awaitingClone = nil
  local st = type(snap.clone) == "table" and snap.clone.state or nil
  if snap.lastError == nil and (st == "running" or st == "exists") then
    resetInput()
  end
end

local function menuSend(id, key)
  local request = view_panel.menuRequest(id, key)
  if request ~= nil then
    send(request)
  end
end

local handlers = {
  open = function(key)
    send({ action = "open", key = key })
    panel.close()
  end,
  openPath = function(text)
    send({ action = "open_path", text = text })
    closeAtSeq = expectedSeq
  end,
  openExisting = function(dest)
    if type(dest) == "string" then
      send({ action = "open_path", text = dest })
      closeAtSeq = expectedSeq
      dismissAfterOpen = true
    end
  end,
  clone = function(url)
    send({ action = "clone", url = url })
    awaitingClone = expectedSeq
  end,
  pickFolder = function()
    send({ action = "pick_folder" })
    panel.close() -- zenity takes focus; the service opens the picked folder
  end,
  cancelClone = function()
    send({ action = "cancel_clone" })
  end,
  dismiss = function()
    send({ action = "dismiss_error" })
  end,
  loadMore = function()
    ui_state.shown = ui_state.shown + view_panel.MORE_STEP
    render()
  end,
  setInput = function(text)
    ui_state.input = text or ""
    render()
  end,
  menu = function(entry)
    panel.openContextMenu({
      items = view_panel.menuItems(entry, tr),
      onActivate = "onRowMenu",
      context = entry.key,
    })
  end,
  toggleActions = function(key)
    if ui_state.expandedKey == key then
      ui_state.expandedKey = nil
    else
      ui_state.expandedKey = key
    end
    render()
  end,
  action = function(id, key)
    ui_state.expandedKey = nil
    menuSend(id, key)
    render()
  end,
  close = function()
    panel.close()
  end,
  unhide = function(key)
    send({ action = "unhide", key = key })
  end,
  openSettings = function()
    panel.close()
    noctalia.openSettings()
  end,
}

-- openContextMenu takes a global's name, not a closure.
function onRowMenu(id, key)
  menuSend(id, key)
end

local function sendGit()
  if not isOpen then
    return
  end
  local keys = view_panel.gitKeys(snapshot, ui_state)
  local sig = table.concat(keys, "\n")
  if sig ~= gitSig and #keys > 0 then
    gitSig = sig
    send({ action = "git", keys = keys })
  end
end

function render()
  ui_state.cloneDir = cloneDir()
  panel.render(view_panel.build(snapshot, ui_state, tr, handlers))
  sendGit()
end

function onOpen(_context)
  isOpen = true
  local value = noctalia.state.get(STATE_KEY)
  if type(value) == "table" then
    snapshot = value
    if value.serviceBootId ~= bootId then
      bootId, expectedSeq = value.serviceBootId, 0
    end
    expectedSeq = math.max(expectedSeq, tonumber(value.requestSeq) or 0)
  end
  ui_state.shown = recentCount()
  ui_state.cloneDir = cloneDir()
  resetInput()
  ui_state.expandedKey = nil
  closeAtSeq, gitSig, awaitingClone, dismissAfterOpen = nil, nil, nil, false
  -- state.watch does not replay an old value; ask for a fresh snapshot (and a re-read).
  send({ action = "refresh" })
  -- A clone that finished (or was cancelled) before this open has been seen: the
  -- notification said so and its row carries the Cloned chip. Drop its status line.
  local cs = snapshot and snapshot.clone and snapshot.clone.state
  if cs == "done" or cs == "cancelled" then
    local copy = {}
    for k, v in pairs(snapshot) do
      copy[k] = v
    end
    copy.clone = { state = "idle" }
    snapshot = copy
    send({ action = "clear_clone" })
  end
  render()
end

function onClose()
  isOpen = false
  closeAtSeq = nil
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) ~= "table" then
    return
  end
  if value.serviceBootId ~= bootId then
    bootId = value.serviceBootId
    expectedSeq, closeAtSeq, awaitingClone, dismissAfterOpen = 0, nil, nil, false
  end
  local seen = tonumber(value.requestSeq) or 0
  if seen > expectedSeq then
    expectedSeq = seen
  end
  snapshot = value
  settleClone(value)
  if closeAtSeq ~= nil and seen >= closeAtSeq then
    closeAtSeq = nil
    local dismiss = dismissAfterOpen
    dismissAfterOpen = false
    if isOpen and value.pathError == nil and value.lastError == nil then
      if dismiss then
        send({ action = "dismiss_error" })
      end
      panel.close()
      return
    end
  end
  render()
end)

render()
