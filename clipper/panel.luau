--!nonstrict
-- Clipper — full-screen clipboard workspace for Noctalia V5.
--
-- The service owns cliphist and persistent data. This panel keeps only
-- presentation state and bounded form drafts. The three-zone composition is
-- intentionally inherited from Clipper V4: pins on the left, notes in the
-- workspace, and a compact clipboard shelf along the bottom.

local SNAPSHOT_KEY = "clipper_snapshot"
local REQUEST_KEY = "clipper_request"
local PANEL_OPEN_KEY = "clipper_panel_open"
local NOTE_DRAG_TYPE = "clipper/note"
local HISTORY_DRAG_TYPE = "clipper/history"

local snapshot = {
  revision = 0,
  status = "loading",
  error = "",
  items = {},
  pinned = {},
  notes = {},
  watchers_running = false,
  total = 0,
}

local searchQuery = ""
local activeFilter = "all"
local historyPage = 1
local requestCounter = 0
local clearConfirm = false
local noteDrafts = {}
local noteDirty = {}
local noteSaveAfter = {}

local NOTE_PAPER_SIZE = 286
local NOTE_AUTOSAVE_SECONDS = 1
local NOTE_PAPER_COLORS = {
  yellow = "#FFD54F",
  pink = "#F48FB1",
  blue = "#90CAF9",
  green = "#A5D6A7",
  lavender = "#CE93D8",
}
local LEGACY_NOTE_PAPER_COLORS = {
  ["tertiary"] = NOTE_PAPER_COLORS.yellow,
  ["tertiary/0.22"] = NOTE_PAPER_COLORS.yellow,
  ["secondary"] = NOTE_PAPER_COLORS.pink,
  ["secondary/0.22"] = NOTE_PAPER_COLORS.pink,
  ["primary"] = NOTE_PAPER_COLORS.blue,
  ["primary/0.18"] = NOTE_PAPER_COLORS.blue,
  ["surface_variant"] = NOTE_PAPER_COLORS.green,
  ["surface"] = NOTE_PAPER_COLORS.lavender,
  ["#FFD54F66"] = NOTE_PAPER_COLORS.yellow,
  ["#F48FB166"] = NOTE_PAPER_COLORS.pink,
  ["#90CAF966"] = NOTE_PAPER_COLORS.blue,
  ["#A5D6A766"] = NOTE_PAPER_COLORS.green,
  ["#CE93D866"] = NOTE_PAPER_COLORS.lavender,
}

local env = getfenv()
local previousDynamicCallbacks = {}
local currentDynamicCallbacks = {}

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function asString(value)
  if value == nil then return "" end
  return tostring(value)
end

local function asArray(value)
  return type(value) == "table" and value or {}
end

local function clamp(value, low, high)
  if value < low then return low end
  if value > high then return high end
  return value
end

local function focusedOutputSize()
  local outputs = noctalia.outputs()
  local fallbackWidth = 1920
  local fallbackHeight = 1080
  for _, output in ipairs(type(outputs) == "table" and outputs or {}) do
    local width = tonumber(output.width)
    local height = tonumber(output.height)
    if width ~= nil and width > 0 then fallbackWidth = width end
    if height ~= nil and height > 0 then fallbackHeight = height end
    if output.focused == true then return fallbackWidth, fallbackHeight end
  end
  return fallbackWidth, fallbackHeight
end

local function normalized(value)
  return noctalia.string.trim(asString(value)):lower()
end

local function shortHash(value)
  local hash = 5381
  value = asString(value)
  for index = 1, #value do
    hash = (hash * 33 + value:byte(index)) % 4294967296
  end
  return string.format("%08x", hash)
end

local function dynamicCallback(prefix, stableId, callback)
  local name = "clipper_" .. prefix .. "_" .. shortHash(stableId)
  env[name] = callback
  currentDynamicCallbacks[name] = true
  return name
end

local function beginDynamicCallbacks()
  currentDynamicCallbacks = {}
end

local function finishDynamicCallbacks()
  for name, _ in pairs(previousDynamicCallbacks) do
    if currentDynamicCallbacks[name] ~= true then
      env[name] = nil
    end
  end
  previousDynamicCallbacks = currentDynamicCallbacks
end

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then return fallback end
  return value
end

local function panelGeometry()
  local width, height = focusedOutputSize()
  local percent = clamp(tonumber(cfg("panel_margin_percent", 0)) or 0, 0, 10)
  local marginH = math.floor(width * percent / 100 + 0.5)
  local marginV = math.floor(height * percent / 100 + 0.5)
  return {
    marginH = marginH,
    marginV = marginV,
    contentWidth = math.max(520, width - (2 * marginH) - 24),
    radius = percent > 0 and 16 or 0,
  }
end

local function request(operation, fields)
  requestCounter += 1
  local payload = {
    request_id = tostring(os.time()) .. "-" .. tostring(requestCounter),
    operation = operation,
  }
  if type(fields) == "table" then
    for key, value in pairs(fields) do payload[key] = value end
  end
  noctalia.state.set(REQUEST_KEY, payload)
end

local function itemKind(item)
  local declared = normalized(item.kind)
  if declared ~= "" then return declared end
  if item.is_image == true then return "image" end

  local preview = noctalia.string.trim(asString(item.preview))
  local lower = preview:lower()
  if preview:match("^#%x%x%x%x%x%x$") or preview:match("^#%x%x%x$")
      or lower:match("^rgba?%s*%(") then
    return "color"
  end
  if lower:match("^https?://") then return "link" end
  if preview:match("^/") or preview:match("^~/") or lower:match("^file://") then return "file" end
  if lower:find("function", 1, true) or lower:find("import ", 1, true)
      or lower:find("const ", 1, true) or lower:find("class ", 1, true)
      or lower:find("def ", 1, true) then
    return "code"
  end
  return "text"
end

local FILTERS = {
  { id = "all", glyph = "clipboard", key = "panel.filters.all" },
  { id = "text", glyph = "align-left", key = "panel.filters.text" },
  { id = "image", glyph = "photo", key = "panel.filters.images" },
  { id = "color", glyph = "palette", key = "panel.filters.colors" },
  { id = "link", glyph = "link", key = "panel.filters.links" },
  { id = "code", glyph = "code", key = "panel.filters.code" },
  { id = "file", glyph = "file", key = "panel.filters.files" },
}

local KIND_GLYPHS = {
  text = "align-left",
  image = "photo",
  color = "palette",
  link = "link",
  code = "code",
  file = "file",
}

local KIND_CARD_COLORS = {
  image = "tertiary/0.32",
  color = "primary/0.30",
  link = "secondary/0.30",
  code = "warning/0.24",
  file = "error/0.18",
}

local KIND_ACCENTS = {
  text = "on_surface_variant",
  image = "tertiary",
  color = "primary",
  link = "secondary",
  code = "warning",
  file = "error",
}

local HISTORY_CARD_SIZE = 184

local function kindLabel(kind)
  local key = "panel.kinds." .. kind
  return tr(key)
end

local function filterItems()
  local query = normalized(searchQuery)
  local result = {}
  for _, item in ipairs(asArray(snapshot.items)) do
    local kind = itemKind(item)
    local matchesKind = activeFilter == "all" or kind == activeFilter
    local matchesQuery = query == "" or normalized(item.preview):find(query, 1, true) ~= nil
    if matchesKind and matchesQuery then
      local copy = {}
      for key, value in pairs(item) do copy[key] = value end
      copy.kind = kind
      result[#result + 1] = copy
    end
  end
  return result
end

local function filterCount(kind)
  if kind == "all" then return #asArray(snapshot.items) end
  local count = 0
  for _, item in ipairs(asArray(snapshot.items)) do
    if itemKind(item) == kind then count += 1 end
  end
  return count
end

local function previewText(item, limit)
  local text = asString(item.preview):gsub("\r", ""):gsub("\t", "    ")
  if #text > limit then return text:sub(1, limit - 1) .. "…" end
  return text
end

local function cardFill(kind)
  return KIND_CARD_COLORS[kind] or cfg("card_color", "surface_variant")
end

local function cardAccent(kind)
  return KIND_ACCENTS[kind] or "primary"
end

local function sendActivate(item, paste)
  request("activate", { id = asString(item.id), paste = paste == true })
  panel.close()
end

local function historyCard(item, width)
  local itemId = asString(item.id)
  local kind = item.kind or itemKind(item)
  local activate = dynamicCallback("activate", itemId, function()
    sendActivate(item, false)
  end)
  local activatePaste = dynamicCallback("paste", itemId, function()
    sendActivate(item, true)
  end)
  local pin = dynamicCallback("pin", itemId, function()
    request("pin", { id = itemId })
  end)
  local remove = dynamicCallback("delete", itemId, function()
    request("delete", { id = itemId })
  end)

  local body
  if item.image_path ~= nil and item.image_path ~= "" then
    body = ui.image({
      key = "history-image-" .. itemId,
      path = item.image_path,
      width = width - 20,
      height = 86,
      radius = 8,
      fit = "contain",
      onClick = activate,
    })
  else
    body = ui.column({
      key = "history-body-" .. itemId,
      fill = "surface/0.22",
      radius = 8,
      height = 86,
      padding = 6,
      justify = "center",
    }, {
      ui.label({
        text = kind == "image" and tr("panel.image_preview_pending") or previewText(item, 120),
        color = "on_surface",
        fontSize = 10,
        maxLines = 4,
        width = width - 32,
      }),
    })
  end

  local dragHandleWidth = math.max(64, width - 88)
  local dragHandle = ui.dragSource({
    key = "history-source-" .. itemId,
    width = dragHandleWidth,
    height = 28,
    align = "center",
    dragType = HISTORY_DRAG_TYPE,
    payload = itemId,
    previewAncestor = 2,
    liftFromLayout = true,
    radius = 6,
    tooltip = tr("panel.actions.drag_to_pin"),
  }, {
    ui.row({ width = dragHandleWidth, gap = 4, align = "center" }, {
      ui.glyph({ name = "grip-vertical", size = 12, color = "on_surface_variant" }),
      ui.glyph({ name = KIND_GLYPHS[kind] or "clipboard", size = 14, color = cardAccent(kind) }),
      ui.label({ text = kindLabel(kind), color = "on_surface_variant", fontSize = 9, flexGrow = 1 }),
    }),
  })

  local card = ui.column({
    key = "history-card-" .. itemId,
    width = width,
    height = width,
    padding = 8,
    gap = 7,
    fill = cardFill(kind),
    radius = 12,
    border = cardAccent(kind) .. "/0.58",
    borderWidth = 1,
  }, {
    ui.row({ gap = 5, align = "center" }, {
      dragHandle,
      ui.button({
        glyph = "pin", variant = "ghost", width = 28, height = 28,
        tooltip = tr("panel.actions.pin"), onClick = pin,
      }),
      ui.button({
        glyph = "trash", variant = "ghost", width = 28, height = 28,
        tooltip = tr("panel.actions.delete"), onClick = remove,
      }),
    }),
    body,
    ui.row({ gap = 5, align = "center", height = 30 }, {
      ui.button({
        text = tr("panel.actions.copy"), glyph = "copy", variant = "ghost", height = 30,
        onClick = activate, flexGrow = 1,
      }),
      ui.button({
        text = tr("panel.actions.paste"), glyph = "clipboard-check", variant = "ghost", height = 30,
        onClick = activatePaste, flexGrow = 1,
      }),
    }),
  })
  return card
end

local function pinnedCard(item)
  local itemId = asString(item.id)
  local kind = item.kind or itemKind(item)
  local copy = dynamicCallback("copy_pin", itemId, function()
    request("copy_pinned", { id = itemId, paste = false })
    panel.close()
  end)
  local paste = dynamicCallback("paste_pin", itemId, function()
    request("copy_pinned", { id = itemId, paste = true })
    panel.close()
  end)
  local unpin = dynamicCallback("unpin", itemId, function()
    request("unpin", { id = itemId })
  end)

  local previewNode
  if item.image_path ~= nil and item.image_path ~= "" then
    previewNode = ui.image({
      path = item.image_path, width = 210, height = 92, radius = 8, fit = "contain", onClick = copy,
    })
  else
    previewNode = ui.label({
      text = previewText(item, 150), color = "on_surface", fontSize = 10, maxLines = 5, width = 210,
    })
  end

  return ui.column({
    key = "pinned-" .. itemId,
    padding = 9,
    gap = 7,
    fill = cfg("pinned_color", "primary"),
    radius = 12,
    border = "outline/0.42",
    borderWidth = 1,
  }, {
    ui.row({ gap = 5, align = "center" }, {
      ui.glyph({ name = KIND_GLYPHS[kind] or "pin", size = 14, color = "secondary" }),
      ui.label({ text = kindLabel(kind), fontSize = 9, color = "on_surface_variant", flexGrow = 1 }),
      ui.button({ glyph = "unpin", variant = "ghost", controlSize = "sm", tooltip = tr("panel.actions.unpin"), onClick = unpin }),
    }),
    previewNode,
    ui.row({ gap = 5, align = "center" }, {
      ui.button({
        text = tr("panel.actions.copy"), glyph = "copy", variant = "ghost", controlSize = "sm",
        onClick = copy, flexGrow = 1,
      }),
      ui.button({
        text = tr("panel.actions.paste"), glyph = "clipboard-check", variant = "ghost", controlSize = "sm",
        onClick = paste, flexGrow = 1,
      }),
    }),
  })
end

local function draftFor(note)
  local id = asString(note.id)
  local draft = noteDrafts[id]
  if draft == nil then
    draft = { title = asString(note.title), content = asString(note.content) }
    noteDrafts[id] = draft
  end
  return draft
end

local function notePaperFill(note)
  local color = asString(note.color)
  if color == "" then color = asString(cfg("notes_color", NOTE_PAPER_COLORS.yellow)) end
  return LEGACY_NOTE_PAPER_COLORS[color] or color
end

local function notePaperBorder(note)
  local red, green, blue = notePaperFill(note):match("^#(%x%x)(%x%x)(%x%x)$")
  if red == nil then return "on_surface/0.16" end
  local function soften(channel)
    local value = tonumber(channel, 16) or 0
    return math.floor(value + ((255 - value) * 0.42) + 0.5)
  end
  return string.format("#%02X%02X%02X", soften(red), soften(green), soften(blue))
end

local function saveNoteDraft(noteId)
  local draft = noteDrafts[noteId]
  if draft == nil or noteDirty[noteId] ~= true then return false end
  request("update_note", { id = noteId, title = draft.title, content = draft.content })
  noteDirty[noteId] = nil
  noteSaveAfter[noteId] = nil
  return true
end

local function scheduleNoteSave(noteId)
  noteDirty[noteId] = true
  noteSaveAfter[noteId] = os.time() + NOTE_AUTOSAVE_SECONDS
end

local function noteCard(note, index)
  local noteId = asString(note.id)
  local draft = draftFor(note)
  local function bringToFront()
    local highestZ = -1
    local topNoteId = ""
    for _, candidate in ipairs(asArray(snapshot.notes)) do
      local candidateZ = tonumber(candidate.z) or 0
      if candidateZ >= highestZ then
        highestZ = candidateZ
        topNoteId = asString(candidate.id)
      end
    end
    if topNoteId == noteId then return end
    request("move_note", {
      id = noteId,
      x = tonumber(note.x) or (24 + ((index - 1) * 36)),
      y = tonumber(note.y) or (24 + ((index - 1) * 28)),
    })
  end
  local focus = dynamicCallback("note_focus", noteId, bringToFront)
  local titleChanged = dynamicCallback("note_title", noteId, function(value)
    draft.title = asString(value)
    scheduleNoteSave(noteId)
    render()
  end)
  local contentChanged = dynamicCallback("note_content", noteId, function(value)
    draft.content = asString(value)
    scheduleNoteSave(noteId)
    render()
  end)
  local save = dynamicCallback("note_save", noteId, function()
    if saveNoteDraft(noteId) then render() end
  end)
  local remove = dynamicCallback("note_delete", noteId, function()
    request("delete_note", { id = noteId })
    noteDrafts[noteId] = nil
    noteDirty[noteId] = nil
    noteSaveAfter[noteId] = nil
  end)
  local export = dynamicCallback("note_export", noteId, function()
    bringToFront()
    request("export_note", { id = noteId })
  end)
  local cycle = dynamicCallback("note_color", noteId, function()
    bringToFront()
    request("cycle_note_color", { id = noteId })
  end)

  local noteDragHandle = ui.dragSource({
    key = "note-source-" .. noteId,
    width = 24,
    height = 28,
    align = "center",
    justify = "center",
    dragType = NOTE_DRAG_TYPE,
    payload = noteId,
    previewAncestor = 2,
    liftFromLayout = true,
    radius = 5,
    tooltip = tr("panel.notes.drag_hint"),
  }, {
    ui.glyph({ name = "grip-vertical", size = 15, color = "on_surface_variant" }),
  })

  local headerChildren = {
    noteDragHandle,
    ui.input({
      key = "note-title-" .. noteId,
      value = draft.title,
      placeholder = tr("panel.notes.untitled"),
      onChange = titleChanged,
      onSubmit = save,
      onPress = focus,
      controlSize = "sm",
      fontSize = 14,
      frameVisible = false,
      flexGrow = 1,
    }),
    ui.button({
      glyph = "palette",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.notes.change_color"),
      onClick = cycle,
    }),
    ui.button({
      glyph = "file-export",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.notes.export"),
      onClick = export,
    }),
    ui.button({
      glyph = "trash",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.notes.delete"),
      onClick = remove,
    }),
  }

  local noteBody = ui.input({
    key = "note-content-" .. noteId,
    value = draft.content,
    placeholder = tr("panel.notes.content_placeholder"),
    multiline = true,
    height = 142,
    flexGrow = 1,
    fontSize = 12,
    frameVisible = false,
    onChange = contentChanged,
    onSubmit = save,
    onPress = focus,
  })

  local paper = ui.column({
    key = "note-card-content-" .. noteId,
    width = NOTE_PAPER_SIZE,
    height = NOTE_PAPER_SIZE,
    padding = 12,
    gap = 7,
    fill = notePaperFill(note),
    radius = 5,
    border = notePaperBorder(note),
    borderWidth = 1,
    onClick = focus,
  }, {
    ui.row({ key = "note-header-" .. noteId, gap = 5, align = "center" }, headerChildren),
    noteBody,
  })

  local content = ui.column({
    key = "note-paper-wrap-" .. noteId,
    width = NOTE_PAPER_SIZE + 4,
    gap = 0,
  }, {
    ui.row({ key = "note-paper-side-shadow-" .. noteId, gap = 0, align = "end" }, {
      paper,
      ui.box({
        key = "note-side-shadow-" .. noteId,
        width = 4,
        height = NOTE_PAPER_SIZE - 5,
        fill = "shadow/0.16",
        radius = 2,
        softness = 1,
      }),
    }),
    ui.row({ key = "note-bottom-shadow-row-" .. noteId, height = 4, justify = "end" }, {
      ui.box({
        key = "note-bottom-shadow-" .. noteId,
        width = NOTE_PAPER_SIZE - 5,
        height = 4,
        fill = "shadow/0.20",
        radius = 2,
        softness = 1,
      }),
    }),
  })

  return ui.column({
    key = "note-position-" .. noteId,
    position = "absolute",
    x = tonumber(note.x) or (24 + ((index - 1) * 36)),
    y = tonumber(note.y) or (24 + ((index - 1) * 28)),
    zIndex = tonumber(note.z) or index,
    width = NOTE_PAPER_SIZE + 4,
    height = NOTE_PAPER_SIZE + 4,
  }, { content })
end

local function headerNode()
  local statusText
  if snapshot.status == "error" then
    statusText = tr("panel.status.error")
  elseif snapshot.status == "loading" then
    statusText = tr("panel.status.loading")
  elseif snapshot.watchers_running == true then
    statusText = tr("panel.status.live")
  else
    statusText = tr("panel.status.manual")
  end

  local children = {
    ui.row({ gap = 9, align = "center", flexGrow = 1 }, {
      ui.glyph({ name = "clipboard", size = 25, color = "primary" }),
      ui.column({ gap = 1 }, {
        ui.label({ text = tr("panel.title"), fontSize = 17, fontWeight = "bold" }),
        ui.label({ text = statusText, fontSize = 9, color = "on_surface_variant" }),
      }),
    }),
    ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("panel.actions.refresh"), onClick = "onRefresh" }),
    ui.button({ glyph = "settings", variant = "ghost", tooltip = tr("panel.actions.settings"), onClick = "onSettings" }),
  }
  if cfg("show_close_button", true) == true then
    children[#children + 1] = ui.button({ glyph = "close", variant = "ghost", tooltip = tr("panel.actions.close"), onClick = "onCloseClicked" })
  end
  return ui.row({ gap = 8, align = "center", paddingH = 4 }, children)
end

local function pinnedPane()
  local cards = {}
  for _, item in ipairs(asArray(snapshot.pinned)) do cards[#cards + 1] = pinnedCard(item) end
  if #cards == 0 then
    cards[1] = ui.column({ align = "center", gap = 8, padding = 18 }, {
      ui.glyph({ name = "pin", size = 26, color = "on_surface_variant" }),
      ui.label({ text = tr("panel.pinned.empty"), color = "on_surface_variant", textAlign = "center", maxLines = 2 }),
    })
  end

  local pane = ui.column({
    key = "pinned-pane",
    width = 250,
    flexGrow = 1,
    padding = 10,
    gap = 9,
    fill = "surface_variant",
    radius = 14,
    border = "outline/0.38",
    borderWidth = 1,
  }, {
    ui.row({ gap = 7, align = "center" }, {
      ui.glyph({ name = "pin", size = 17, color = "secondary" }),
      ui.label({ text = tr("panel.pinned.title"), fontSize = 12, fontWeight = "bold", flexGrow = 1 }),
      ui.label({ text = tostring(#asArray(snapshot.pinned)), color = "on_surface_variant", fontSize = 9 }),
    }),
    ui.scroll({ flexGrow = 1, fill = "surface", radius = 10 }, cards),
  })
  return ui.dropZone({
    key = "pinned-drop-zone",
    accepts = { HISTORY_DRAG_TYPE },
    value = "pin",
    onDrop = "onPinDrop",
    direction = "column",
    align = "stretch",
    hitSlop = 24,
    radius = 14,
    border = "primary/0.7",
    borderWidth = 1,
  }, { pane })
end

local function notesPane()
  local noteList = asArray(snapshot.notes)
  local canvasChildren = {}
  if #noteList == 0 then
    canvasChildren[1] = ui.column({ align = "center", justify = "center", gap = 9, padding = 28, flexGrow = 1 }, {
      ui.glyph({ name = "notes", size = 36, color = "tertiary" }),
      ui.label({ text = tr("panel.notes.empty"), fontSize = 13, fontWeight = "bold" }),
      ui.label({ text = tr("panel.notes.empty_hint"), color = "on_surface_variant", maxLines = 2, textAlign = "center" }),
      ui.button({ text = tr("panel.notes.create"), glyph = "add", onClick = "onCreateNote" }),
    })
  else
    for index, note in ipairs(noteList) do canvasChildren[#canvasChildren + 1] = noteCard(note, index) end
  end

  local canvas = ui.dropZone({
    key = "notes-canvas",
    accepts = { NOTE_DRAG_TYPE },
    value = "canvas",
    onDrop = "onNoteDrop",
    direction = "column",
    flexGrow = 1,
    clipChildren = true,
  }, canvasChildren)

  return ui.column({
    key = "notes-pane",
    flexGrow = 1,
    padding = 10,
    gap = 9,
  }, {
    ui.row({ gap = 7, align = "center", justify = "end" }, {
      ui.label({ text = tr("panel.notes.count", { count = #asArray(snapshot.notes) }), color = "on_surface_variant", fontSize = 9 }),
      ui.button({ text = tr("panel.notes.create"), glyph = "add", controlSize = "sm", onClick = "onCreateNote" }),
    }),
    canvas,
  })
end

local function filtersNode()
  local buttons = {}
  for _, filter in ipairs(FILTERS) do
    local filterId = filter.id
    buttons[#buttons + 1] = ui.button({
      key = "filter-" .. filterId,
      text = tr(filter.key) .. " " .. tostring(filterCount(filterId)),
      glyph = filter.glyph,
      variant = activeFilter == filterId and "primary" or "ghost",
      controlSize = "sm",
      onClick = dynamicCallback("filter", filterId, function()
        activeFilter = filterId
        historyPage = 1
        render()
      end),
    })
  end
  return ui.row({ gap = 4, align = "center" }, buttons)
end

local function historyPane(usableWidth)
  local filtered = filterItems()
  local desiredPerPage = clamp(tonumber(cfg("history_cards", 30)) or 30, 3, 30)
  local widthLimited = math.max(3, math.floor((usableWidth + 8) / (HISTORY_CARD_SIZE + 8)))
  local perPage = math.min(desiredPerPage, widthLimited)
  local pages = math.max(1, math.ceil(#filtered / perPage))
  historyPage = clamp(historyPage, 1, pages)
  local first = (historyPage - 1) * perPage + 1
  local last = math.min(#filtered, first + perPage - 1)
  local cards = {}
  for index = first, last do cards[#cards + 1] = historyCard(filtered[index], HISTORY_CARD_SIZE) end
  if #cards == 0 then
    cards[1] = ui.column({ align = "center", gap = 6, padding = 18, flexGrow = 1 }, {
      ui.glyph({ name = searchQuery ~= "" and "search-off" or "clipboard-off", size = 26, color = "on_surface_variant" }),
      ui.label({
        text = (searchQuery ~= "" or activeFilter ~= "all") and tr("panel.history.no_matches") or tr("panel.history.empty"),
        color = "on_surface_variant",
      }),
    })
  end

  local clearText = clearConfirm and tr("panel.history.confirm_clear") or tr("panel.history.clear")
  return ui.column({
    key = "history-pane",
    height = 305,
    padding = 10,
    gap = 8,
    fill = "surface_variant",
    radius = 14,
    border = "outline/0.42",
    borderWidth = 1,
  }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "history", size = 17, color = "primary" }),
      ui.label({ text = tr("panel.history.title"), fontSize = 12, fontWeight = "bold" }),
      ui.input({
        key = "history-search",
        value = searchQuery,
        placeholder = tr("panel.history.search"),
        onChange = "onSearchChanged",
        controlSize = "sm",
        flexGrow = 1,
      }),
      ui.button({
        text = clearText,
        glyph = clearConfirm and "alert-triangle" or "trash",
        variant = clearConfirm and "destructive" or "ghost",
        controlSize = "sm",
        onClick = "onClearHistory",
      }),
    }),
    filtersNode(),
    ui.row({ gap = 8, align = "start", flexGrow = 1 }, cards),
    ui.row({ gap = 7, align = "center", justify = "center" }, {
      ui.button({ glyph = "chevron-left", variant = "ghost", controlSize = "sm", enabled = historyPage > 1, onClick = "onPreviousPage" }),
      ui.label({ text = tr("panel.history.page", { page = historyPage, pages = pages }), color = "on_surface_variant", fontSize = 9 }),
      ui.button({ glyph = "chevron-right", variant = "ghost", controlSize = "sm", enabled = historyPage < pages, onClick = "onNextPage" }),
    }),
  })
end

function render()
  beginDynamicCallbacks()
  local geometry = panelGeometry()
  local showPanelBackground = cfg("show_panel_background", false) == true
  local body = {
    headerNode(),
    ui.row({ key = "workspace", gap = 10, flexGrow = 1, align = "stretch" }, {
      pinnedPane(),
      notesPane(),
    }),
    historyPane(geometry.contentWidth),
  }
  if snapshot.error ~= nil and snapshot.error ~= "" then
    table.insert(body, 2, ui.row({
      gap = 7, align = "center", padding = 8, fill = "error/0.14", radius = 10,
    }, {
      ui.glyph({ name = "alert-triangle", size = 15, color = "error" }),
      ui.label({ text = tr("notifications." .. asString(snapshot.error)), color = "error", maxLines = 2, flexGrow = 1 }),
    }))
  end

  panel.render(ui.column({
    key = "clipper-viewport",
    flexGrow = 1,
    align = "stretch",
    paddingH = geometry.marginH,
    paddingV = geometry.marginV,
  }, {
    ui.column({
      key = "clipper-root",
      flexGrow = 1,
      align = "stretch",
      padding = 12,
      gap = 10,
      fill = showPanelBackground and "surface/0.96" or "#00000000",
      radius = geometry.radius,
    }, body),
  }))
  finishDynamicCallbacks()
end

function onOpen()
  noctalia.state.set(PANEL_OPEN_KEY, true)
  panel.setWantsSecondTicks(true)
  request("refresh")
  render()
end

function onClose()
  noctalia.state.set(PANEL_OPEN_KEY, false)
  for noteId, _ in pairs(noteDirty) do
    saveNoteDraft(noteId)
  end
end

function update()
  local now = os.time()
  local due = {}
  for noteId, deadline in pairs(noteSaveAfter) do
    if deadline <= now then due[#due + 1] = noteId end
  end
  local saved = false
  for _, noteId in ipairs(due) do
    if saveNoteDraft(noteId) then saved = true end
  end
  if saved then render() end
end

function onRefresh()
  request("refresh")
end

function onSettings()
  noctalia.runAsync("noctalia msg settings-open plugins")
end

function onCloseClicked()
  panel.close()
end

function onSearchChanged(value)
  searchQuery = asString(value)
  historyPage = 1
  clearConfirm = false
  render()
end

function onPreviousPage()
  historyPage = math.max(1, historyPage - 1)
  render()
end

function onNextPage()
  historyPage += 1
  render()
end

function onClearHistory()
  if not clearConfirm then
    clearConfirm = true
    render()
    return
  end
  clearConfirm = false
  request("wipe")
end

function onCreateNote()
  request("create_note")
end

function onNoteDrop(payload, target, x, y)
  local noteId = asString(payload)
  local dropX = tonumber(x)
  local dropY = tonumber(y)
  if noteId == "" or target ~= "canvas" or dropX == nil or dropY == nil then return end
  request("move_note", { id = noteId, x = dropX, y = dropY })
end

function onPinDrop(payload, _target)
  local itemId = asString(payload)
  if itemId:match("^%d+$") == nil then return end
  request("pin", { id = itemId })
end

function onIpc(event, payload)
  if event == "refresh" then
    request("refresh")
  elseif event == "search" then
    searchQuery = asString(payload)
    historyPage = 1
    render()
  elseif event == "filter" then
    local value = normalized(payload)
    for _, filter in ipairs(FILTERS) do
      if filter.id == value then
        activeFilter = value
        historyPage = 1
        render()
        break
      end
    end
  elseif event == "new-note" then
    onCreateNote()
  end
end

noctalia.state.watch(SNAPSHOT_KEY, function(value)
  if type(value) ~= "table" then return end
  snapshot = value

  local present = {}
  for _, note in ipairs(asArray(snapshot.notes)) do
    local noteId = asString(note.id)
    present[noteId] = true
    if noteDirty[noteId] ~= true then
      noteDrafts[noteId] = { title = asString(note.title), content = asString(note.content) }
    end
  end
  for noteId, _ in pairs(noteDrafts) do
    if present[noteId] ~= true then
      noteDrafts[noteId] = nil
      noteDirty[noteId] = nil
      noteSaveAfter[noteId] = nil
    end
  end
  render()
end)

local initial = noctalia.state.get(SNAPSHOT_KEY)
if type(initial) == "table" then snapshot = initial end
render()
