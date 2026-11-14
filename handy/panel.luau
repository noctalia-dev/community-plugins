--!nonstrict
-- Handy panel. Reads the service snapshot; every command is emitted through
-- the shared state channel so only the service touches Handy and SQLite.

local snapshot = noctalia.state.get("snapshot")
local open = false
local commandCounter = 0
local filterText = ""
local copiedId = nil
local pendingDeleteId = nil
local transcriptLines = math.floor(tonumber(noctalia.getConfig("transcript_lines")) or 4)
transcriptLines = math.max(1, math.min(10, transcriptLines))
local render

local function translated(key, fallback)
  local value = noctalia.tr(key)
  if value == nil or value == key then
    return fallback
  end
  return value
end

local function translatedWith(key, fallback, subst)
  local value = noctalia.tr(key, subst)
  if value == nil or value == key then
    return fallback
  end
  return value
end

local function sendCommand(action, fields)
  commandCounter += 1
  local command = fields or {}
  command.action = action
  command.nonce = tostring(noctalia.nowMs()) .. ":" .. tostring(commandCounter)
  noctalia.state.set("command", command)
end

local function formatTimestamp(timestamp)
  local seconds = tonumber(timestamp)
  if seconds == nil or seconds <= 0 then
    return ""
  end
  return os.date("%b %d, %H:%M", seconds)
end

local function copyEntry(entry)
  local ok = noctalia.copyToClipboard(entry.text or "", "text/plain")
  copiedId = ok and entry.id or nil
  render()
end

local function deleteEntry(entry)
  if pendingDeleteId == entry.id then
    pendingDeleteId = nil
    sendCommand("delete_transcript", { id = entry.id })
  else
    pendingDeleteId = entry.id
  end
  render()
end

local function matchesFilter(entry)
  if filterText == "" then
    return true
  end
  local needle = filterText:lower()
  local haystack = ((entry.title or "") .. " " .. (entry.text or "") .. " " .. (entry.original or "")):lower()
  return string.find(haystack, needle, 1, true) ~= nil
end

local function stateInfo(value)
  if value == nil then
    return {
      glyph = "loader",
      color = "on_surface_variant",
      text = translated("state.unavailable", "Unavailable"),
    }
  end
  if value.error ~= nil then
    return { glyph = "alert-triangle", color = "error", text = tostring(value.error) }
  end
  if not value.running then
    return {
      glyph = "microphone-off",
      color = "on_surface_variant",
      text = translated("panel.offline", "Handy is not running."),
    }
  end
  if value.state == "recording" then
    return { glyph = "player-record-filled", color = "error", text = translated("state.recording", "Recording") }
  end
  if value.state == "transcribing" then
    return { glyph = "loader", color = "primary", text = translated("state.transcribing", "Transcribing") }
  end
  return { glyph = "microphone", color = "primary", text = translated("state.idle", "Idle") }
end

local function header(value, info)
  return ui.row({ align = "center", gap = 10 }, {
    ui.glyph({ name = info.glyph, size = 22, color = info.color }),
    ui.column({ flexGrow = 1, gap = 1 }, {
      ui.label({ text = translated("panel.title", "Handy"), fontSize = 18, fontWeight = "bold" }),
      ui.label({ text = info.text, color = "on_surface_variant", maxLines = 2 }),
    }),
    ui.button({
      glyph = "refresh",
      tooltip = translated("panel.refresh", "Refresh"),
      controlSize = "sm",
      variant = "ghost",
      onClick = function()
        sendCommand("refresh")
      end,
    }),
    ui.button({
      glyph = "x",
      tooltip = translated("panel.close", "Close"),
      controlSize = "sm",
      variant = "ghost",
      onClick = function()
        panel.close()
      end,
    }),
  })
end

local function actions(value)
  local running = value ~= nil and value.running == true
  local busy = value ~= nil and (value.state == "recording" or value.state == "transcribing")
  local latest = value and value.latest or nil
  local children = {}

  if running then
    table.insert(children, ui.button({
      text = busy and translated("panel.stop", "Stop") or translated("panel.record", "Record"),
      glyph = busy and "player-stop" or "player-record-filled",
      variant = busy and "destructive" or "primary",
      onClick = function()
        sendCommand("toggle")
      end,
    }))
  else
    table.insert(children, ui.button({
      text = translated("panel.launch", "Launch Handy"),
      glyph = "player-play",
      variant = "primary",
      onClick = function()
        sendCommand("launch")
      end,
    }))
  end

  table.insert(children, ui.button({
    text = translated("panel.cancel", "Cancel"),
    glyph = "x",
    variant = "outline",
    enabled = busy,
    onClick = function()
      sendCommand("cancel")
    end,
  }))

  table.insert(children, ui.button({
    glyph = "copy",
    tooltip = translated("panel.copy", "Copy transcript"),
    variant = "ghost",
    enabled = latest ~= nil,
    onClick = function()
      sendCommand("copy_latest")
    end,
  }))

  table.insert(children, ui.button({
    glyph = "folder",
    tooltip = translated("panel.open_recordings", "Open recordings folder"),
    variant = "ghost",
    onClick = function()
      sendCommand("open_recordings")
    end,
  }))

  table.insert(children, ui.spacer({ flexGrow = 1 }))

  return ui.row({ align = "center", gap = 8 }, children)
end

local function modelRow(value)
  local models = value and value.models or {}
  local options = {}
  local selected = 0
  local busy = value ~= nil and (value.state == "recording" or value.state == "transcribing")

  for index, model in ipairs(models) do
    table.insert(options, model.name)
    if model.active then
      selected = index - 1
    end
  end

  if #options == 0 then
    return ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "cpu", size = 16, color = "on_surface_variant" }),
      ui.label({ text = translated("panel.model", "Model"), color = "on_surface_variant", fontSize = 12 }),
      ui.label({
        text = (value and value.activeModel) or translated("panel.no_model", "No model selected"),
        color = "on_surface_variant",
        fontSize = 12,
        flexGrow = 1,
      }),
    })
  end

  return ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = "cpu", size = 16, color = "on_surface_variant" }),
    ui.label({ text = translated("panel.model", "Model"), color = "on_surface_variant", fontSize = 12 }),
    ui.select({
      options = options,
      selectedIndex = selected,
      controlSize = "sm",
      flexGrow = 1,
      enabled = #options > 1 and not busy and value ~= nil and value.running == true,
      onChange = function(index)
        local parsed = tonumber(index)
        if parsed == nil then
          return
        end
        local model = models[math.floor(parsed) + 1]
        if model ~= nil then
          sendCommand("select_model", { model = model.name })
        end
      end,
    }),
  })
end

local function entryRow(entry)
  local details = {
    ui.label({
      text = formatTimestamp(entry.timestamp),
      color = "on_surface_variant",
      fontSize = 11,
      flexGrow = 1,
    }),
  }

  if entry.language ~= nil and entry.language ~= "" then
    table.insert(details, ui.label({
      text = translatedWith("panel.language", entry.language, { language = entry.language }),
      color = "on_surface_variant",
      fontSize = 11,
    }))
  end

  table.insert(details, ui.button({
    glyph = copiedId == entry.id and "check" or "copy",
    tooltip = translated("panel.copy", "Copy transcript"),
    controlSize = "sm",
    variant = "ghost",
    onClick = function()
      copyEntry(entry)
    end,
  }))

  local confirming = pendingDeleteId == entry.id
  table.insert(details, ui.button({
    glyph = confirming and "check" or "trash",
    tooltip = confirming
      and translated("panel.delete_confirm", "Click again to delete")
      or translated("panel.delete", "Delete transcript"),
    controlSize = "sm",
    variant = confirming and "destructive" or "ghost",
    onClick = function()
      deleteEntry(entry)
    end,
  }))

  return ui.column({
    key = "transcript-" .. tostring(entry.id),
    gap = 5,
    fill = "on_surface/0.06",
    radius = 8,
    padding = 10,
    onClick = function()
      copyEntry(entry)
    end,
  }, {
    ui.row({ align = "center", gap = 8 }, details),
    ui.label({ text = entry.text or "", maxLines = transcriptLines }),
  })
end

local function body(value)
  local children = {}
  local history = value and value.history or {}
  local count = 0

  for _, entry in ipairs(history) do
    if matchesFilter(entry) then
      table.insert(children, entryRow(entry))
      count += 1
    end
  end

  if count == 0 then
    local message
    if value == nil then
      message = translated("state.unavailable", "Unavailable")
    elseif value.error ~= nil and #history == 0 then
      message = tostring(value.error)
    elseif #history > 0 and filterText ~= "" then
      message = translated("panel.no_matches", "No transcripts match your search.")
    else
      message = translated("panel.no_transcripts", "No transcripts yet. Press the Handy shortcut or click Record.")
    end
    table.insert(children, ui.label({ text = message, color = "on_surface_variant", maxLines = 4 }))
  end

  return children
end

local function footer(value)
  local total = value and #(value.history or {}) or 0
  return ui.row({ align = "center", gap = 8 }, {
    ui.label({
      text = translated("panel.hint", "Click a transcript to copy it."),
      color = "on_surface_variant",
      fontSize = 11,
      flexGrow = 1,
    }),
    ui.label({
      text = translatedWith("panel.footer_count", tostring(total) .. " transcripts", { count = total }),
      color = "on_surface_variant",
      fontSize = 11,
    }),
  })
end

render = function()
  if not open then
    return
  end

  local value = snapshot
  local info = stateInfo(value)
  local rows = body(value)

  panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, {
    header(value, info),
    actions(value),
    modelRow(value),
    ui.input({
      key = "search",
      value = filterText,
      placeholder = translated("panel.search", "Search transcripts…"),
      controlSize = "sm",
      focus = true,
      onChange = function(text)
        filterText = text or ""
        render()
      end,
    }),
    ui.scroll({ flexGrow = 1, gap = 8, align = "stretch" }, rows),
    footer(value),
  }))
end

noctalia.state.watch("snapshot", function(value)
  snapshot = value
  render()
end)

function onOpen(_context)
  open = true
  snapshot = noctalia.state.get("snapshot") or snapshot
  sendCommand("refresh_models")
  render()
end

function onClose()
  open = false
  pendingDeleteId = nil
end
