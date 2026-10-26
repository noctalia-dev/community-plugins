--!nonstrict
local api = require("./lib/api.luau")
local credentials = require("./lib/credentials.luau")
local config = require("./lib/config.luau")

local state = "idle"
local opened = false
local generation = 0
local sessionNumber = 0
local draft, question, answer, errorText = "", "", "", ""
local sessionId = nil
local connection, configError = nil, nil
local stream = nil
local dirty = false
local lastRender, startedAt, lastActivity = 0, 0, 0
local copied = false
local copyError = false
local render

local function busy()
  return state == "loading" or state == "streaming"
end

local function hasContent(text)
  -- Lua %s covers ASCII only; pasted Unicode spaces must not trigger a request.
  for _, cp in utf8.codes(text) do
    local whitespace = (cp >= 9 and cp <= 13) or cp == 32 or cp == 0x85
      or cp == 0xA0 or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200A)
      or cp == 0x2028 or cp == 0x2029 or cp == 0x202F or cp == 0x205F or cp == 0x3000
    if not whitespace then return true end
  end
  return false
end

local function stopStream()
  generation = generation + 1
  local previous = stream
  stream = nil
  if previous then previous.stop() end
  panel.setNeedsFrameTick(false)
end

local function fail(message, discard)
  stopStream()
  state = "error"
  errorText = message
  if discard then answer = "" end
  render()
end

render = function()
  if not opened then return end
  dirty = false
  lastRender = noctalia.nowMs()
  local body = {}
  if state == "idle" then
    if configError then
      table.insert(body, ui.label({ text = configError, color = "error" }))
    end
    table.insert(body, ui.input({
      key = "question-" .. tostring(sessionNumber),
      value = "", placeholder = noctalia.tr("panel.placeholder"), multiline = true,
      submitOnEnter = true, focus = true, height = 92,
      onChange = function(value) draft = value; render() end,
      onSubmit = "onSubmit",
    }))
    table.insert(body, ui.label({
      text = noctalia.tr("panel.keyboard-help"),
      color = "on_surface_variant", fontSize = 13,
    }))
  else
    table.insert(body, ui.label({ text = question, color = "on_surface_variant", fontSize = 13, maxLines = 3 }))
    if answer ~= "" then
      table.insert(body, ui.markdown({ key = "answer", text = answer }))
    elseif busy() then
      table.insert(body, ui.label({ text = noctalia.tr("panel.loading"), color = "on_surface_variant" }))
    end
    if state == "error" then
      table.insert(body, ui.label({ text = errorText, color = "error" }))
    elseif state == "cancelled" then
      table.insert(body, ui.label({ text = noctalia.tr("panel.cancelled"), color = "on_surface_variant" }))
    end
    if copyError then
      table.insert(body, ui.label({ text = noctalia.tr("panel.copy-error"), color = "error" }))
    end
  end

  local actions = {}
  if state == "idle" then
    table.insert(actions, ui.button({
      text = noctalia.tr("panel.send"), glyph = "arrow-up", variant = "primary",
      enabled = connection ~= nil and hasContent(draft), onClick = function() onSubmit(draft) end,
    }))
  elseif busy() then
    table.insert(actions, ui.button({ text = noctalia.tr("panel.stop"), glyph = "player-stop", onClick = "onStop" }))
  elseif state == "error" then
    table.insert(actions, ui.button({ text = noctalia.tr("panel.retry"), glyph = "refresh", variant = "primary", onClick = "onRetry" }))
  end
  table.insert(actions, ui.spacer({ flexGrow = 1 }))
  table.insert(actions, ui.button({
    text = copied and noctalia.tr("panel.copied") or noctalia.tr("panel.copy"), glyph = "copy",
    enabled = not busy() and answer ~= "", onClick = "onCopy",
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = "QuickAsk", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "settings", tooltip = noctalia.tr("panel.settings"), variant = "ghost", onClick = "onSettingsClicked" }),
      ui.button({ glyph = "close", tooltip = noctalia.tr("panel.close"), variant = "ghost", onClick = "onCloseClicked" }),
    }),
    ui.label({
      text = connection and noctalia.tr("config.summary", { host = connection.authority, model = connection.model })
        or noctalia.tr("config.required"),
      color = "on_surface_variant", fontSize = 12, maxLines = 2,
    }),
    ui.scroll({ key = "body-" .. tostring(sessionNumber), flexGrow = 1, gap = 12, stickToBottom = true }, body),
    ui.row({ align = "center", gap = 8 }, actions),
  }))
end

local function send()
  stopStream()
  local current = generation
  state, answer, errorText, copied, copyError = "loading", "", "", false, false
  startedAt = noctalia.nowMs()
  lastActivity = startedAt
  render() -- first paint precedes credential lookup and HTTP
  panel.setNeedsFrameTick(true)

  credentials.lookup(connection, function(key, message)
    if not opened or generation ~= current then return end
    if not key then fail(message); return end
    lastActivity = noctalia.nowMs()
    local handle = api.start(question, key, sessionId, connection, {
      onActivity = function()
        if opened and generation == current then lastActivity = noctalia.nowMs() end
      end,
      onDelta = function(text)
        if not opened or generation ~= current then return end
        state = "streaming"
        answer = answer .. text
        dirty = true
      end,
      onComplete = function()
        if not opened or generation ~= current then return end
        stream = nil
        state = "complete"
        panel.setNeedsFrameTick(false)
        render()
      end,
      onError = function(messageText, discard)
        if opened and generation == current then fail(messageText, discard) end
      end,
    })
    key = nil
    if opened and generation == current and busy() then stream = handle else handle.stop() end
  end)
end

function onOpen(_context)
  stopStream()
  opened = true
  sessionNumber = sessionNumber + 1
  state, draft, question, answer, errorText = "idle", "", "", "", ""
  sessionId, copied, copyError = nil, false, false
  connection, configError = config.read()
  render()
end

function onSubmit(value)
  if not opened or state ~= "idle" or type(value) ~= "string" then return end
  if not hasContent(value) then return end
  local trimmed = value:match("^%s*(.-)%s*$")
  if trimmed == "" then return end
  if not connection then render(); return end
  question = trimmed
  sessionId = api.newSession()
  send()
end

function onRetry()
  if opened and state == "error" and question ~= "" then send() end
end

function onStop()
  if not opened or not busy() then return end
  stopStream()
  state = "cancelled"
  render()
end

function onCopy()
  if not opened or busy() or answer == "" then return end
  if noctalia.copyToClipboard(answer, "text/plain") then
    copied = true
    copyError = false
  else
    copied = false
    copyError = true
  end
  render()
end

function onFrameTick(_deltaMs)
  if not opened or not busy() then return end
  local now = noctalia.nowMs()
  if now - startedAt >= 180000 or now - lastActivity >= 45000 then
    fail(noctalia.tr("panel.timeout"))
  elseif dirty and now - lastRender >= 32 then
    render()
  end
end

function onClose()
  opened = false -- every host close path invalidates callbacks before cancellation
  stopStream()
  state, draft, question, answer, errorText = "idle", "", "", "", ""
  sessionId, copied, copyError = nil, false, false
  connection, configError = nil, nil
end

function onSettingsClicked()
  onClose()
  noctalia.openSettings()
end

function onCloseClicked()
  onClose()
  panel.close()
end

function onExit(_signal, _reason)
  onClose()
end
