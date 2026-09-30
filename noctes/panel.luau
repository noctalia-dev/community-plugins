--!nonstrict
-- Noctes panel - the only surface that can take keyboard focus, so it owns all
-- typing. A post-it hands its note over by setting noctes.editing.
--
-- One view: the editor. There was a list too, and it was in the way - the
-- notes are already on screen, and picking one means clicking it, not scrolling
-- a second copy of the same wall. What the list did that the editor now does:
-- new and delete.
--
-- Edits are kept as a local draft and flushed to the service on a second-tick
-- debounce, on close, and on Save, so typing never round-trips through state on
-- every keystroke.

local colors = require("./colors.luau")

local FLUSH_AFTER_MS = 1200

local notes = {}
local boundKeys = {}
-- Assumed until the service says otherwise: the probe answers a moment after
-- the panel can already be open, and a hint that flickers is worse than late.
local sheetsReady = true
local themeColors = false
local currentId = ""
local draftTitle = ""
local draftContent = ""
local dirty = false
local lastChangeMs = 0
local pendingDelete = ""

-- The seed a note's generated look hangs off: its key when it has one, so the
-- chips match the sheet on the desktop, else its id.
local function seedOf(note)
  return (note.key or "") ~= "" and note.key or note.id
end

-- The output the note's post-it sits on, or nil when no widget is bound to it.
-- The widgets live in Noctalia's settings, so the service reads them back and
-- publishes the list.
local function stuckOn(note)
  local key = note.key or ""
  if key == "" then
    return nil
  end
  for _, bound in ipairs(boundKeys) do
    if bound.key == key then
      return bound.output or "?"
    end
  end
  return nil
end

local function findNote(id)
  for _, note in ipairs(notes) do
    if note.id == id then
      return note
    end
  end
  return nil
end

-- Keeps the editor on a note that exists. The one it showed can go out from
-- under it - deleted here, or gone with a reload - and its drafts have to go
-- with it: left behind, the inputs would show the old note's text under the
-- next note's toolbar, and a Save that looked like it worked would write
-- nowhere. With nothing selected it lands on the most recently touched note;
-- notes arrives newest first.
local function settle()
  if currentId ~= "" and findNote(currentId) ~= nil then
    return
  end
  local note = notes[1]
  currentId = note ~= nil and note.id or ""
  draftTitle = note ~= nil and (note.title or "") or ""
  draftContent = note ~= nil and (note.content or "") or ""
  dirty = false
  pendingDelete = ""
end

local function currentNote()
  return findNote(currentId)
end

-- `force` is the Save button. Autosave refuses to wipe a note that had text in
-- it: ui.input is uncontrolled, so a stray empty onChange would otherwise erase
-- the note silently. Clearing one on purpose still works, through Save.
local function flush(force)
  if not dirty or currentId == "" then
    dirty = false
    return
  end
  if not force then
    local stored = findNote(currentId)
    local wipes = noctalia.string.trim(draftTitle) == "" and noctalia.string.trim(draftContent) == ""
    local hadText = stored ~= nil and (noctalia.string.trim(stored.content or "") ~= ""
      or noctalia.string.trim(stored.title or "") ~= "")
    if wipes and hadText then
      return
    end
  end
  noctalia.state.set("noctes.cmd", {
    op = "update",
    id = currentId,
    title = draftTitle,
    content = draftContent,
  })
  dirty = false
end

local render

local function openNote(id)
  if id == currentId then
    return
  end
  flush()
  local note = findNote(id)
  if note == nil then
    return
  end
  currentId = id
  draftTitle = note.title or ""
  draftContent = note.content or ""
  dirty = false
  pendingDelete = ""
  render()
end

-- New means new post-it: the service creates the note and its desktop widget
-- together, then selects it, so the editor lands on the new sheet.
--
-- The open note rides along, so the new sheet lands on the screen that one is
-- on. Without it the sheet follows the focused window instead, and clicking a
-- sheet or the panel never moves window focus: it would land on whichever
-- screen was last typed in.
local function addPostit()
  local note = currentNote()
  noctalia.state.set("noctes.cmd", {
    op = "spawn_widget",
    near = note ~= nil and note.key or nil,
  })
end

-- Hands the desk over to Noctalia's widget editor, which is the only thing that
-- can move, resize or rotate a sheet. The panel gets out of the way first: it
-- floats over the very desk being rearranged.
local function moveMode()
  noctalia.state.set("noctes.cmd", { op = "toggle_edit" })
  panel.close()
end

local function removeNote(id)
  noctalia.state.set("noctes.cmd", { op = "remove", id = id })
  -- Out of the local copy now rather than when the service republishes, so the
  -- editor settles on a note that is staying, not on this one for a moment.
  local kept = {}
  for _, note in ipairs(notes) do
    if note.id ~= id then
      table.insert(kept, note)
    end
  end
  notes = kept
  pendingDelete = ""
  settle()
  render()
end

local function setColor(id, color)
  noctalia.state.set("noctes.cmd", { op = "set_color", id = id, color = color })
end

-- ── Pieces ──────────────────────────────────────────────────────────────────

local function colorPicker(note)
  local isAuto = not colors.isKnown(note.color)

  -- A chip shows the paper it would give the sheet. The two that are not simply
  -- a colour carry a glyph, painted in that paper's own text color - which is
  -- the one shade guaranteed to be readable on it, whatever the theme does.
  local function chip(name, glyph)
    local selected = name == "" and isAuto or note.color == name
    local fill, ink = colors.paper(name, seedOf(note), themeColors)

    local children = {}
    if glyph ~= nil then
      table.insert(children, ui.glyph({ name = glyph, size = 14, color = ink }))
    end

    return ui.row({
      key = "swatch-" .. (name ~= "" and name or "auto"),
      width = 24,
      height = 24,
      radius = 12,
      align = "center",
      justify = "center",
      fill = fill,
      border = selected and "on_surface" or "outline/0.4",
      borderWidth = selected and 2 or 1,
      onClick = function()
        setColor(note.id, name)
      end,
    }, children)
  end

  -- Dynamic first and glass second: the two that behave rather than just sit
  -- there. Black third, since it is the other one that is not simply a shade of
  -- paper. Then the eight papers.
  local swatches = { chip("", "wand"), chip(colors.GLASS, "droplet"), chip(colors.BLACK, nil) }
  for _, name in ipairs(colors.NAMES) do
    table.insert(swatches, chip(name, nil))
  end

  -- A tooltip would be the obvious place for this, but `tooltip` on a box or a
  -- flex container needs plugin API 32 and this shell caps out below that. A
  -- caption under the chips says the same thing without a hover, and it says it
  -- to someone who never thinks to hover.
  local caption
  if isAuto then
    caption = themeColors and noctalia.tr("panel.color_dynamic_theme")
      or noctalia.tr("panel.color_dynamic_classic")
  elseif note.color == colors.GLASS then
    caption = noctalia.tr("panel.color_glass")
  else
    caption = noctalia.tr("panel.color_fixed")
  end

  return ui.column({ gap = 4, align = "stretch" }, {
    ui.row({ gap = 6, align = "center" }, swatches),
    ui.label({ text = caption, fontSize = 10, color = "on_surface/0.6", maxLines = 2 }),
  })
end

local function toolbar(note)
  local armed = pendingDelete == note.id
  local screen = stuckOn(note)

  return ui.row({ gap = 6, align = "center" }, {
    -- Where this sheet is. Quiet when it is on a screen, because that is the
    -- normal case and a badge for it would be noise; loud when it is not,
    -- because that is the one worth knowing about. A label, not a button: a
    -- note without a sheet gets one back through the `stick` IPC event.
    ui.label({
      text = screen ~= nil and screen
        or (sheetsReady and noctalia.tr("panel.not_on_screen") or noctalia.tr("panel.no_helper")),
      fontSize = 10,
      color = screen ~= nil and "on_surface/0.45" or "primary",
      flexGrow = 1,
      maxLines = 1,
    }),
    ui.button({
      glyph = "settings",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.settings"),
      onClick = function()
        noctalia.openSettings()
      end,
    }),
    ui.button({
      glyph = "arrows-move",
      variant = "secondary",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.move"),
      onClick = moveMode,
    }),
    ui.button({
      glyph = "plus",
      variant = "primary",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.new"),
      onClick = addPostit,
    }),
    ui.button({
      glyph = armed and "check" or "trash",
      variant = armed and "destructive" or "ghost",
      controlSize = "sm",
      tooltip = armed and noctalia.tr("panel.delete_confirm") or noctalia.tr("panel.delete"),
      onClick = function()
        if armed then
          removeNote(note.id)
        else
          pendingDelete = note.id
          render()
        end
      end,
    }),
  })
end

local function editor(note)
  return ui.column({ gap = 10, flexGrow = 1, align = "stretch" }, {
    toolbar(note),
    ui.input({
      key = "title-" .. note.id,
      value = draftTitle,
      placeholder = noctalia.tr("panel.title_placeholder"),
      controlSize = "md",
      focus = true,
      onChange = function(value)
        draftTitle = value
        dirty = true
        lastChangeMs = noctalia.nowMs()
      end,
      onSubmit = function(value)
        draftTitle = value
        dirty = true
        flush()
      end,
    }),
    ui.input({
      key = "content-" .. note.id,
      value = draftContent,
      placeholder = noctalia.tr("panel.content_placeholder"),
      multiline = true,
      flexGrow = 1,
      onChange = function(value)
        draftContent = value
        dirty = true
        lastChangeMs = noctalia.nowMs()
      end,
      onSubmit = function(value)
        draftContent = value
        dirty = true
        flush()
      end,
    }),
    colorPicker(note),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({
        text = dirty and noctalia.tr("panel.unsaved") or noctalia.tr("panel.saved"),
        fontSize = 11,
        color = "on_surface/0.6",
        flexGrow = 1,
      }),
      ui.button({
        text = noctalia.tr("panel.save"),
        variant = "primary",
        controlSize = "sm",
        onClick = function()
          -- Save is the end of the errand: write it and get out of the way.
          flush(true)
          panel.close()
        end,
      }),
    }),
  })
end

local function emptyState()
  return ui.column({ gap = 10, flexGrow = 1, align = "center", justify = "center" }, {
    ui.glyph({ name = "note", size = 32, color = "on_surface/0.35" }),
    ui.label({ text = noctalia.tr("panel.empty"), color = "on_surface/0.6" }),
    ui.button({
      text = noctalia.tr("panel.new"),
      glyph = "plus",
      variant = "primary",
      controlSize = "sm",
      onClick = addPostit,
    }),
  })
end

-- ── Wiring ──────────────────────────────────────────────────────────────────

render = function()
  local note = currentNote()
  local body = note ~= nil and editor(note) or emptyState()
  panel.render(ui.column({ padding = 12, gap = 10, flexGrow = 1, align = "stretch" }, { body }))
end

noctalia.state.watch("noctes.notes", function(value)
  notes = type(value) == "table" and value or {}
  settle()
  render()
end)

noctalia.state.watch("noctes.boundKeys", function(value)
  boundKeys = type(value) == "table" and value or {}
  render()
end)

-- The host wakes a watcher on every set, changed or not, so these two check
-- before paying for a render.
noctalia.state.watch("noctes.themeColors", function(value)
  local next = value == true
  if next == themeColors then
    return
  end
  themeColors = next
  render()
end)

noctalia.state.watch("noctes.sheetsReady", function(value)
  local next = value ~= false
  if next == sheetsReady then
    return
  end
  sheetsReady = next
  render()
end)

-- A post-it (and the service, after it creates one) selects a note here.
noctalia.state.watch("noctes.editing", function(value)
  if type(value) == "string" and value ~= "" then
    openNote(value)
  end
end)

function onOpen()
  noctalia.state.set("noctes.panelOpen", true)
  -- The desktop-widget editor can add or delete post-its behind this plugin's
  -- back, so the bound-key list is re-read every time the panel opens.
  noctalia.state.set("noctes.cmd", { op = "refresh" })

  local wanted = noctalia.state.get("noctes.editing")
  if type(wanted) == "string" and wanted ~= "" then
    openNote(wanted)
  end
  settle()

  -- The drafts outlive a close. Whatever changed the note since - a reload, an
  -- IPC edit - is what the editor should open on, unless there is typing of
  -- its own still waiting to be saved.
  local note = currentNote()
  if note ~= nil and not dirty then
    draftTitle = note.title or ""
    draftContent = note.content or ""
  end
  render()
end

function onClose()
  flush()
  noctalia.state.set("noctes.panelOpen", false)
  noctalia.state.set("noctes.editing", "")
  pendingDelete = ""
end

-- Debounced autosave: typing marks the draft dirty, the tick flushes it once
-- the user pauses.
function update()
  if dirty and (noctalia.nowMs() - lastChangeMs) >= FLUSH_AFTER_MS then
    flush()
    render()
  end
end

panel.setWantsSecondTicks(true)

local initial = noctalia.state.get("noctes.notes")
notes = type(initial) == "table" and initial or {}
local initialBound = noctalia.state.get("noctes.boundKeys")
boundKeys = type(initialBound) == "table" and initialBound or {}
sheetsReady = noctalia.state.get("noctes.sheetsReady") ~= false
themeColors = noctalia.state.get("noctes.themeColors") == true
noctalia.state.set("noctes.panelOpen", false)
settle()
render()
