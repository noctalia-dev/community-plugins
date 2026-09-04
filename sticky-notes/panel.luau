--!nonstrict
-- Sticky Notes panel — scrollable list + full-width edit view.

local DRAG_TYPE = "sticky-notes-note"
-- Pastel note fills are intentionally independent of the active shell theme.
-- A fixed dark foreground keeps them readable in both light and dark modes.
local NOTE_TEXT_COLOR = "#111111"

local NOTE_COLORS = {
  { id = "yellow", hex = "#FFF59D", labelKey = "settings.color-yellow" },
  { id = "pink",   hex = "#F8BBD9", labelKey = "settings.color-pink"   },
  { id = "red",    hex = "#EF5350", labelKey = "settings.color-red"    },
  { id = "blue",   hex = "#B3E5FC", labelKey = "settings.color-blue"   },
  { id = "green",  hex = "#DCEDC8", labelKey = "settings.color-green"  },
  { id = "orange", hex = "#FFA726", labelKey = "settings.color-orange" },
  { id = "purple", hex = "#E1BEE7", labelKey = "settings.color-purple" },
}

local notes = {}
local blurred = false
local notesReady = false
local editingId = nil
local editingContent = nil
local pendingDeleteId = nil
local editKey = 0
-- -1 so the first state-watch fire (initial load) does not trigger auto-open.
local prevNoteCount = -1

-- -------------------------------------------------------------------------
local function colorHex(id)
  for _, c in ipairs(NOTE_COLORS) do
    if c.id == id then return c.hex end
  end
  return "#FFF59D"
end

local function formatDate(ts)
  if type(ts) ~= "number" or ts <= 0 then return "" end
  local ok, result = pcall(os.date, "%b %d, %H:%M", ts)
  if ok and type(result) == "string" then return result end
  return ""
end

local function findNote(id)
  for _, n in ipairs(notes) do
    if n.id == id then return n end
  end
  return nil
end

-- Return the first web link in a note. We deliberately only accept HTTP(S)
-- links: notes are user content, so an accidental file:, command:, or custom
-- URI must never be forwarded to the desktop URL handler.
local function firstWebLink(content)
  if type(content) ~= "string" then return nil end

  for token in content:gmatch("%S+") do
    token = token:gsub("^[%(%[%{<\"']+", "")
    local url = nil
    if token:sub(1, 8) == "https://" or token:sub(1, 7) == "http://" then
      url = token
    elseif token:sub(1, 4) == "www." then
      url = "https://" .. token
    end

    if url ~= nil then
      -- Natural punctuation after a link should not become part of the URL.
      url = url:gsub("[%,%.%!%?%;:]+$", "")
      if url:match("^https://[^%s]+$") or url:match("^http://[^%s]+$") then
        return url
      end
    end
  end
  return nil
end

local function openWebLink(url)
  if type(url) ~= "string" then return end
  if not url:match("^https://[^%s]+$") and not url:match("^http://[^%s]+$") then return end
  -- Argument-array form avoids shell interpolation of note content.
  noctalia.runAsync({ "xdg-open", url })
end

-- Preview text is kept compact so short notes do not leave an empty block,
-- while a long note is visibly shortened before ui.label applies its four-line
-- layout clamp. Flattening whitespace also prevents manual line breaks from
-- making a preview taller than the surrounding cards.
local function previewText(content, fontSize)
  local compact = (content or ""):gsub("%s+", " ")
  compact = noctalia.string.trim(compact)
  if compact == "" then return noctalia.tr("panel.empty-preview") end

  -- Approximate four visual lines for the panel's available width. The label's
  -- maxLines remains the final guard for unusually wide glyphs or long words.
  local limit = math.max(96, math.min(220, math.floor(2200 / fontSize)))
  if #compact > limit then return compact:sub(1, limit - 1) .. "…" end
  return compact
end

local function sendCmd(cmd)
  noctalia.state.set("sticky_notes.cmd", cmd)
end

-- Markdown task-list lines stay ordinary note text, so they remain useful in
-- exported .md/.txt files and editable outside the plugin. The panel adds a
-- lightweight interactive view for the common `- [ ] task` form.
local function checklistTasks(content)
  local tasks = {}
  local lineNumber = 0
  for line in ((content or "") .. "\n"):gmatch("(.-)\n") do
    lineNumber += 1
    local state, text = line:match("^%s*[%-%*+]%s+%[([ xX])%]%s*(.*)$")
    if state ~= nil then
      table.insert(tasks, {
        line = lineNumber,
        done = state == "x" or state == "X",
        text = text ~= "" and text or noctalia.tr("panel.untitled-task"),
      })
    end
  end
  return tasks
end

local function setChecklistTask(content, targetLine, done)
  local lines = {}
  local lineNumber = 0
  for line in ((content or "") .. "\n"):gmatch("(.-)\n") do
    lineNumber += 1
    if lineNumber == targetLine then
      local before, _state, after = line:match("^(%s*[%-%*+]%s+%[)([ xX])(%].*)$")
      if before ~= nil then line = before .. (done and "x" or " ") .. after end
    end
    table.insert(lines, line)
  end
  return table.concat(lines, "\n")
end

local function updateChecklistTask(note, task, done)
  local content = setChecklistTask(note.content or "", task.line, done)
  if content ~= note.content then
    sendCmd({ op = "update", id = note.id, content = content })
  end
end

-- Persist the local input draft without forcing a render. This is shared by
-- Done/Back and onClose, so closing the panel cannot lose a long-note edit.
local function saveEditingDraft()
  local note = editingId ~= nil and findNote(editingId) or nil
  local id = editingId
  local content = editingContent or (note and note.content) or ""
  editingId = nil
  editingContent = nil
  pendingDeleteId = nil

  if note == nil then return false end
  if noctalia.string.trim(content) == "" then
    sendCmd({ op = "remove", id = id })
    return true
  elseif note.content ~= content then
    sendCmd({ op = "update", id = id, content = content })
    return true
  end
  return false
end

-- Auto-delete an empty note and return to the list (or just return to list).
-- Called from both the Back button and the Done button.
local function leaveEdit()
  if not saveEditingDraft() then render() end
end

-- -------------------------------------------------------------------------
-- Color picker
-- Each swatch = outer "halo" wrapper (fill = primary when selected, surface
-- when not) → inner coloured column (fill = hex, always the real color) →
-- ghost button click target. The wrapper's fill provides an unmissable
-- selection ring without touching the swatch's own fill.
-- IMPORTANT: never pass selected = true on the inner button — its theme
-- background paints over the column's fill (the swatch would appear blue).
-- -------------------------------------------------------------------------
local function colorPicker(note)
  local swatches = {}
  for _, c in ipairs(NOTE_COLORS) do
    local isSelected = note.color == c.id
    table.insert(swatches, ui.column({
      key     = "wrap-" .. c.id,
      fill    = isSelected and "primary" or "surface",
      padding = 3,
      radius  = 10,
      align   = "stretch",
      justify = "stretch",
    }, {
      ui.column({
        key     = "sw-" .. c.id,
        fill    = c.hex,
        width   = 26,
        height  = 26,
        radius  = 7,
        align   = "stretch",
        justify = "center",
      }, {
        ui.button({
          key      = "sw-btn-" .. c.id,
          variant  = "ghost",
          flexGrow = 1,
          tooltip  = noctalia.tr(c.labelKey),
          onClick  = function()
            sendCmd({ op = "update", id = note.id, color = c.id })
          end,
        }),
      }),
    }))
  end
  return ui.row({ gap = 6, align = "center", justify = "center", paddingV = 4 }, swatches)
end

-- -------------------------------------------------------------------------
-- Blur overlay
-- -------------------------------------------------------------------------
local function blurOverlay()
  local strength = noctalia.getConfig("blur_strength") or "medium"
  -- The overlay renders on top of the note card's pastel fill, so use the
  -- theme's "surface" color (dark in dark themes) rather than the muted
  -- "on_surface_variant" which is near-invisible on light backgrounds.
  local items = { ui.glyph({ name = "eye-off", size = 32, color = "surface" }) }
  if strength ~= "heavy" then
    table.insert(items, ui.label({
      text = noctalia.tr("panel.blurred-hint"),
      fontSize = 11, color = "surface", textAlign = "center",
    }))
  end
  return ui.column({ gap = 8, align = "center", justify = "center", padding = 16 }, items)
end

-- -------------------------------------------------------------------------
-- List view
-- -------------------------------------------------------------------------
-- -------------------------------------------------------------------------
-- Drag & drop reorder — mirrors the timezone-hub grip-handle pattern.
-- Zone value is encoded as "<group>:<index>" (e.g. "p:2", "u:1") so a drop
-- carries both the target group (pinned/unpinned) and the insertion index
-- within that group. Dragging a note into the other group's zone toggles
-- its pinned state on the service side.
-- -------------------------------------------------------------------------
local function insertionZone(group, index)
  return ui.dropZone({
    key          = "zone-" .. group .. "-" .. index,
    accepts      = { DRAG_TYPE },
    value        = group .. ":" .. index,
    onDrop       = "onZoneDropped",
    height       = 3,
    radius       = 4,
    expandOnDrag = true,
    hitSlop      = 20,
  })
end

function onZoneDropped(payload, value)
  if type(payload) ~= "string" or payload == "" then return end
  if type(value) ~= "string" then return end
  local group, indexStr = value:match("^([pu]):(%d+)$")
  if group == nil then return end
  local index = tonumber(indexStr)
  if index == nil then return end
  sendCmd({ op = "move", id = payload, group = group, index = index })
end

-- Ctrl+Enter in the edit view's multiline input fires this. Gated on the
-- `save_shortcut` setting so users can turn it off.
function onEditSubmit(_value)
  if noctalia.getConfig("save_shortcut") == false then return end
  if editingId ~= nil then leaveEdit() end
end

local function notePreviewCard(note)
  local hex = colorHex(note.color)
  local fontSize = noctalia.getConfig("font_size") or 13
  local dateText = formatDate(note.createdAt)
  local isPinned = note.pinned == true
  local webLink = firstWebLink(note.content)
  local tasks = checklistTasks(note.content)
  local completedTasks = 0
  for _, task in ipairs(tasks) do
    if task.done then completedTasks += 1 end
  end

  local body
  if blurred then
    body = blurOverlay()
  elseif #tasks > 0 then
    local taskRows = {}
    for index, task in ipairs(tasks) do
      if index > 3 then break end
      table.insert(taskRows, ui.row({ gap = 6, align = "center" }, {
        -- ui.toggle is rendered as a wide on/off switch by the shell. A
        -- compact outlined button reads as a familiar task checkbox instead.
        ui.button({
          text = task.done and "✓" or "",
          variant = "outline",
          width = 24,
          height = 24,
          onClick = function()
            updateChecklistTask(note, task, not task.done)
          end,
        }),
        ui.label({
          text = task.text, fontSize = fontSize, color = NOTE_TEXT_COLOR,
          maxLines = 1,
        }),
      }))
    end
    if #tasks > 3 then
      local moreTasks = noctalia.tr("panel.more-tasks", { count = #tasks - 3 })
      -- Translation bundles reload with the plugin rather than its Luau
      -- script. Do not expose the key while a developer hot-reloads this file.
      if moreTasks == "panel.more-tasks" then
        moreTasks = "+" .. tostring(#tasks - 3) .. " more tasks"
      end
      table.insert(taskRows, ui.label({
        text = moreTasks,
        fontSize = 11, color = NOTE_TEXT_COLOR,
      }))
    end
    body = ui.column({ gap = 2, align = "stretch" }, taskRows)
  else
    local preview = previewText(note.content, fontSize)
    body = ui.label({
      text = preview, fontSize = fontSize, color = NOTE_TEXT_COLOR,
      maxLines = 4,
    })
  end

  if pendingDeleteId == note.id then
    return ui.column({
      key = "card-" .. note.id, fill = hex, radius = 8, padding = 10, gap = 6,
    }, {
      body,
      ui.separator({}),
      ui.row({ gap = 6, align = "center", justify = "center" }, {
        ui.label({ text = noctalia.tr("panel.confirm-delete"), fontSize = 11, color = NOTE_TEXT_COLOR }),
        ui.button({
          glyph = "check", text = noctalia.tr("panel.delete-yes"),
          variant = "destructive", controlSize = "sm",
          onClick = function()
            local id = note.id; pendingDeleteId = nil
            sendCmd({ op = "remove", id = id })
          end,
        }),
        ui.button({
          glyph = "close", variant = "outline", controlSize = "sm",
          onClick = function() pendingDeleteId = nil; render() end,
        }),
      }),
    })
  end

  return ui.column({
    key = "card-" .. note.id, fill = hex, radius = 8, padding = 10, gap = 6,
    onClick = not blurred and function()
      editingId = note.id; editingContent = note.content or ""
      pendingDeleteId = nil; editKey += 1; render()
    end or nil,
  }, {
    body,
    ui.separator({}),
    ui.row({ align = "center", justify = "space_between" }, {
      ui.row({ gap = 6, align = "center" }, {
        ui.dragSource({
          key             = "grip-" .. note.id,
          dragType        = DRAG_TYPE,
          payload         = note.id,
          -- Preview = the leading row (grip + date) so it stays inside the
          -- panel. liftFromLayout MUST be false here: the drag source's
          -- ancestor 1 has a sibling (the trailing action row), so lifting
          -- it collapses the card's outer row and leaves the leading row
          -- misplaced when the drag ends without a valid drop.
          previewAncestor = 1,
          liftFromLayout  = false,
          width           = 20,
          height          = 20,
          align           = "center",
          justify         = "center",
          tooltip         = noctalia.tr("panel.drag-hint"),
        }, {
          ui.glyph({ name = "menu-2", size = 12, color = NOTE_TEXT_COLOR }),
        }),
        ui.label({ text = dateText, fontSize = 10, color = NOTE_TEXT_COLOR }),
        #tasks > 0 and ui.label({
          text = completedTasks .. "/" .. #tasks,
          fontSize = 10, color = NOTE_TEXT_COLOR,
        }) or ui.row({}, {}),
      }),
      ui.row({ gap = 4, align = "center" }, {
        webLink ~= nil and ui.button({
          glyph = "external-link", variant = "outline", controlSize = "sm",
          tooltip = noctalia.tr("panel.open-link", { url = webLink }),
          onClick = function() openWebLink(webLink) end,
        }) or ui.row({}, {}),
        ui.button({
          glyph = isPinned and "star-filled" or "star",
          variant = "outline", controlSize = "sm",
          tooltip = isPinned and noctalia.tr("panel.unpin") or noctalia.tr("panel.pin"),
          onClick = function() sendCmd({ op = "toggle_pin", id = note.id }) end,
        }),
        ui.button({
          glyph = "pencil", variant = "outline", controlSize = "sm",
          enabled = not blurred, tooltip = noctalia.tr("panel.edit"),
          onClick = function()
            editingId = note.id; editingContent = note.content or ""
            pendingDeleteId = nil; editKey += 1; render()
          end,
        }),
        ui.button({
          glyph = "trash", variant = "outline", controlSize = "sm",
          tooltip = noctalia.tr("panel.delete"),
          onClick = function() pendingDeleteId = note.id; render() end,
        }),
      }),
    }),
  })
end

local function listView()
  if not notesReady then
    return ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 14 }, {
      ui.glyph({ name = "loader-2", size = 32, color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("panel.loading"), fontSize = 13,
                  color = "on_surface_variant", textAlign = "center" }),
    })
  end

  if #notes == 0 then
    return ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 14 }, {
      ui.glyph({ name = "note", size = 48, color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("panel.empty"), fontSize = 13,
                  color = "on_surface_variant", textAlign = "center" }),
      ui.button({
        text = noctalia.tr("panel.add-first"), glyph = "plus", variant = "outline",
        onClick = function() sendCmd({ op = "add" }) end,
      }),
    })
  end
  -- Storage is already in display order (pinned first, newest-first within
  -- each group — the service enforces this on load and on every mutation).
  local pinned, unpinned = {}, {}
  for _, n in ipairs(notes) do
    if n.pinned then
      table.insert(pinned, n)
    else
      table.insert(unpinned, n)
    end
  end

  local items = {}

  -- Pinned group: one drop zone before each card, one after the last card.
  -- Always emit at least the leading zone so an empty pinned group is a
  -- valid drop target (drag any note into it to pin it).
  table.insert(items, insertionZone("p", 1))
  for i, note in ipairs(pinned) do
    table.insert(items, notePreviewCard(note))
    table.insert(items, insertionZone("p", i + 1))
  end

  if #pinned > 0 and #unpinned > 0 then
    table.insert(items, ui.separator({}))
  end

  table.insert(items, insertionZone("u", 1))
  for i, note in ipairs(unpinned) do
    table.insert(items, notePreviewCard(note))
    table.insert(items, insertionZone("u", i + 1))
  end

  return ui.scroll({ flexGrow = 1, gap = 4, align = "stretch", justify = "start" }, items)
end

-- -------------------------------------------------------------------------
-- Edit view — coloured card (fill) + footer outside the card.
-- -------------------------------------------------------------------------
-- Multiline inputs have their own wheel handler. Give the input enough height
-- for all of its text and let a regular ui.scroll own the viewport instead.
-- Apart from producing smoother scrolling, this avoids the input viewport
-- jumping back toward its caret while reading a long note.
local function editorContentHeight(content, fontSize)
  local charsPerLine = math.max(12, math.floor(320 / fontSize))
  local visualLines = 0
  local startAt = 1

  while true do
    local newlineAt = content:find("\n", startAt, true)
    local endAt = newlineAt ~= nil and newlineAt - 1 or #content
    local lineLength = math.max(0, endAt - startAt + 1)
    visualLines += math.max(1, math.ceil(lineLength / charsPerLine))
    if newlineAt == nil then break end
    startAt = newlineAt + 1
  end

  return math.max(300, math.ceil(visualLines * fontSize * 1.6 + 24))
end

local function editView(note)
  local hex = colorHex(note.color)
  local fontSize = noctalia.getConfig("font_size") or 13
  local content = editingContent or note.content or ""

  local card = ui.column({
    flexGrow = 1, fill = hex, radius = 8, padding = 10, gap = 6,
    align    = "stretch",
  }, {
    colorPicker(note),
    ui.separator({}),
    ui.scroll({ flexGrow = 1, align = "stretch", justify = "start" }, {
      -- Put the content height on a wrapper instead of the input itself. An
      -- explicit input height also scales its native frame, producing a huge
      -- corner radius; flex-growing inside this wrapper keeps normal styling.
      ui.column({ height = editorContentHeight(content, fontSize), align = "stretch" }, {
        ui.input({
          key           = "inp-" .. note.id .. "-" .. tostring(editKey),
          value         = content,
          placeholder   = noctalia.tr("panel.placeholder"),
          multiline     = true,
          flexGrow      = 1,
          fontSize      = fontSize,
          -- On a multiline input Qt fires the submit signal for Ctrl+Enter;
          -- plain Enter keeps inserting newlines. The handler still gates on
          -- the save_shortcut setting so the user can disable it.
          submitOnEnter = true,
          onSubmit      = "onEditSubmit",
          onChange      = function(value)
            -- ui.input owns its current text. Keeping the draft local avoids a
            -- full panel re-render after every keystroke, which preserves scroll.
            editingContent = value
          end,
        }),
      }),
    }),
  })

  -- Footer sits OUTSIDE the coloured card so ghost buttons stay visible.
  local footer
  if pendingDeleteId == note.id then
    footer = ui.row({ gap = 6, align = "center", justify = "center" }, {
      ui.label({ text = noctalia.tr("panel.confirm-delete"), fontSize = 11, color = "on_surface_variant" }),
      ui.button({
        glyph = "check", text = noctalia.tr("panel.delete-yes"),
        variant = "destructive", controlSize = "sm",
        onClick = function()
          local id = note.id; pendingDeleteId = nil; editingId = nil; editingContent = nil
          sendCmd({ op = "remove", id = id })
        end,
      }),
      ui.button({
        glyph = "close", variant = "ghost", controlSize = "sm",
        onClick = function() pendingDeleteId = nil; render() end,
      }),
    })
  else
    local shortcutOn = noctalia.getConfig("save_shortcut") ~= false
    footer = ui.row({ align = "center", justify = "space_between" }, {
      ui.button({
        glyph = "check", text = noctalia.tr("panel.done"),
        variant = "ghost", controlSize = "sm",
        tooltip = shortcutOn and noctalia.tr("panel.done-tooltip") or noctalia.tr("panel.done"),
        onClick = function() leaveEdit() end,
      }),
      ui.button({
        glyph = "trash", variant = "ghost", controlSize = "sm",
        tooltip = noctalia.tr("panel.delete"),
        onClick = function() pendingDeleteId = note.id; render() end,
      }),
    })
  end

  return ui.column({ flexGrow = 1, gap = 6, align = "stretch" }, { card, footer })
end

-- -------------------------------------------------------------------------
-- Render
-- -------------------------------------------------------------------------
function render()
  local editNote = editingId ~= nil and findNote(editingId) or nil
  -- If the note we were editing was deleted, fall back to list.
  if editingId ~= nil and editNote == nil then
    editingId = nil; editingContent = nil; pendingDeleteId = nil
  end
  local inEdit = editNote ~= nil

  local header = ui.row({ align = "center", justify = "space_between" }, {
    ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
      inEdit
        and ui.button({
          glyph = "arrow-left", variant = "ghost", controlSize = "sm",
          tooltip = noctalia.tr("panel.back"),
          onClick = function() leaveEdit() end,
        })
        or ui.glyph({ name = "note", size = 20, color = "primary" }),
      ui.label({ text = inEdit and noctalia.tr("panel.editing") or noctalia.tr("panel.title"),
                  fontSize = 14, fontWeight = "bold" }),
    }),
    ui.row({ gap = 2, align = "center" }, {
      ui.button({
        glyph = blurred and "eye" or "eye-off",
        variant = blurred and "outline" or "ghost",
        selected = blurred, controlSize = "sm",
        tooltip = blurred and noctalia.tr("panel.unblur") or noctalia.tr("panel.blur"),
        onClick = function() sendCmd({ op = "toggle_blur" }) end,
      }),
      not inEdit and notesReady and ui.button({
        glyph = "plus", variant = "ghost", controlSize = "sm",
        tooltip = noctalia.tr("panel.add"),
        onClick = function()
          -- If there is already an empty note, navigate to it instead of
          -- creating another one (prevents unlimited empty-note pile-up).
          for _, n in ipairs(notes) do
            if noctalia.string.trim(n.content or "") == "" then
              editingId = n.id; editingContent = n.content or ""
              pendingDeleteId = nil; editKey += 1; render()
              return
            end
          end
          sendCmd({ op = "add" })
        end,
      }) or ui.row({}, {}),
      ui.button({
        glyph = "close", variant = "ghost", controlSize = "sm",
        onClick = function() panel.close() end,
      }),
    }),
  })

  local body = inEdit and editView(editNote) or listView()

  panel.render(ui.column({
    flexGrow = 1, gap = 8, padding = 8, justify = "start", align = "stretch",
  }, { header, ui.separator({}), body }))
end

-- -------------------------------------------------------------------------
-- State watches
-- -------------------------------------------------------------------------
noctalia.state.watch("sticky_notes.notes", function(value)
  local newNotes = type(value) == "table" and value or {}
  -- Jump to a newly added note (not on initial load). Storage no longer
  -- appends new notes at the tail (addNote inserts at the top of the
  -- unpinned group), so find the one whose id wasn't in the old list.
  if prevNoteCount >= 0 and #newNotes > prevNoteCount then
    local prevIds = {}
    for _, n in ipairs(notes) do prevIds[n.id] = true end
    for _, n in ipairs(newNotes) do
      if not prevIds[n.id] then
        editingId = n.id; editingContent = n.content or ""
        pendingDeleteId = nil; editKey += 1
        break
      end
    end
  end
  prevNoteCount = #newNotes
  notes = newNotes
  render()
end)

-- Only exit the edit view on a false → true transition of blurred, not on
-- every state re-publish. An unconditional `editingId = nil` would otherwise
-- discard an open draft whenever another note action updates shared state.
local prevBlurred = false
noctalia.state.watch("sticky_notes.blurred", function(value)
  local newBlurred = value == true
  if newBlurred and not prevBlurred then editingId = nil; editingContent = nil end
  prevBlurred = newBlurred
  blurred = newBlurred
  render()
end)

noctalia.state.watch("sticky_notes.ready", function(value)
  notesReady = value == true
  render()
end)

-- -------------------------------------------------------------------------
-- Lifecycle
-- -------------------------------------------------------------------------
function onOpen(_context)
  editingId = nil; editingContent = nil; pendingDeleteId = nil
  -- A panel can be instantiated after the service's initial publish. Ask for
  -- the current snapshot so opening it never looks like an empty note list.
  sendCmd({ op = "sync" })
  local autoBlur = noctalia.getConfig("auto_blur")
  if autoBlur == true and not blurred then
    sendCmd({ op = "toggle_blur" })
  end
  render()
end

function onClose()
  saveEditingDraft()
end
