--!nonstrict
-- Scratchpad pad — a stack of plain-text sticky notes, each independently editable.
--   Design: content first, minimal chrome — an Apple Notes-like layout:
--   LEFT  : one-line note rows (title only), hover reveals the delete button;
--           the selected row gets an accent tint.
--   RIGHT : a slim icon toolbar (new / close) over one big plain-text editor;
--           the footer only speaks when it must (unsaved / save failed), with
--           the character count whispered in the corner.
--   (The inline-picture experiment was removed in 0.6.0 — pictures belong to
--   screenshot tools. Old {{img:<id>}} markers are stripped and their files
--   cleaned up on first load, so nothing stale survives the downgrade.)
-- Data:  pluginDataDir()/notes.json — array of { id, text, time, mtime }
--        pluginDataDir()/state.json — { lastId } so reopening shows the note
--        edited last; a corrupt notes.json is kept as notes.json.bak first.
-- Fully local: no network, no model. The only spawned process is `xdg-open`
-- (data-folder button), declared in plugin.toml dependencies.
-- All user-visible text goes through tr() (translations/en.json).

local dataDir       = noctalia.pluginDataDir()
local notesFile     = dataDir .. "/notes.json"
local stateFile     = dataDir .. "/state.json"
local legacyDoc     = dataDir .. "/document.txt"
local imageDir      = dataDir .. "/images"   -- leftovers of the removed picture feature
local openFolderCmd = "xdg-open '" .. dataDir .. "'"

-- Tick rate for update() (auto-save + delete timeout + save-result repaint).
-- This is a persistent setting: call it once at load time, not on every tick.
-- Text input repaints immediately (onTextChange → render) so the list name
-- and footer follow every keystroke; the tick only coalesces the rest.
-- Auto-save is an idle debounce anchored to the LAST KEYSTROKE: the note is
-- written once typing quiets down (SAVE_QUIET_MS), with a slow checkpoint
-- (SAVE_MAX_MS) as a crash safety net while typing non-stop, and a back-off
-- (SAVE_RETRY_MS) so a failing disk is not hammered every tick.
local REFRESH_MS    = 180
local SAVE_QUIET_MS = 900
local SAVE_MAX_MS   = 5000
local SAVE_RETRY_MS = 3000
noctalia.setUpdateInterval(REFRESH_MS)

-- Short, script-driven motion. The shell animates the panel surface itself;
-- these add in-panel feedback without waiting on a layer-surface teardown.
local OPEN_ANIM_MS   = 180
local SWITCH_ANIM_MS = 150
local ANIM_OPEN      = "open"
local ANIM_SWITCH    = "switch"

local notes       = {}      -- array of { id, text, time, mtime }
local currentId   = nil
local dirty       = false
local saveError   = false   -- last writeFile failed; surfaced in the footer
local savedAt     = 0
local lastEditAt  = 0       -- last keystroke (idle-debounce anchor)
local lastAttempt = 0       -- last save attempt, successful or not (back-off)
local uiDirty     = false   -- deferred repaint (typing / status / save result)
local anim        = nil     -- { kind, elapsed, duration }, advanced by onFrameTick
local editorGen   = 0       -- bump ONLY when switching notes, so typing never rebuilds the input
local hoverRow    = nil     -- note id whose list row is hovered
local hoverBtn    = nil     -- note id whose delete button is hovered
local pendingDel  = nil     -- note id awaiting a second click to confirm delete
local pendingAt   = 0       -- when the delete was armed (auto-cancels after a few seconds)
local CONFIRM_MS  = 4000
local ARM_CONFIRM_MS = 400   -- a confirm click sooner than this is a double-click

-- Shorthand: every user-visible string goes through the plugin's translations
-- (community CI requires translation files; zh-Hans keeps the pad Chinese).
local tr = noctalia.tr

local render -- forward declaration

local function nowMs() return noctalia.nowMs() end

local function easeOut(t)
  local u = 1 - t
  return 1 - u * u * u
end

local function animEased()
  if not anim then return 1 end
  return easeOut(math.min(anim.elapsed / anim.duration, 1))
end

-- Repaint immediately for structural changes (switch/new/delete/hover); text
-- input paints directly too (onTextChange → render), so every path is live.
local function startAnimation(kind, duration)
  anim = { kind = kind, elapsed = 0, duration = duration or SWITCH_ANIM_MS }
  panel.setNeedsFrameTick(true)
  render()
end

local function stopAnimation()
  if not anim then return end
  anim = nil
  panel.setNeedsFrameTick(false)
end

-- UTF-8 awareness: count and truncate by code point, never by bytes, so CJK
-- text is neither miscounted nor cut mid-character. Emoji get the same care:
-- truncation never ends on a dangling ZWJ / skin-tone / variation selector.
local UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"
local codePoint = (type(utf8) == "table" and type(utf8.codepoint) == "function")
                  and utf8.codepoint or nil

local function charCount(s)
  local n = 0
  for _ in (s or ""):gmatch(UTF8_CHAR) do n += 1 end
  return n
end

local function isGraphemeExtender(ch)
  if not codePoint then return false end
  local ok, cp = pcall(codePoint, ch)
  if not ok or not cp then return false end
  return (cp >= 0x0300 and cp <= 0x036F)   -- combining marks
      or cp == 0x200D                       -- ZWJ (family / profession emoji)
      or cp == 0xFE0E or cp == 0xFE0F       -- variation selectors
      or cp == 0x20E3                       -- combining keycap
      or (cp >= 0x1F3FB and cp <= 0x1F3FF)  -- skin-tone modifiers
end

local function truncate(s, maxChars)
  local out = {}
  local n = 0
  for ch in s:gmatch(UTF8_CHAR) do
    n += 1
    if n > maxChars then
      while #out > 0 and isGraphemeExtender(out[#out]) do out[#out] = nil end
      return table.concat(out) .. "…"
    end
    out[n] = ch
  end
  return table.concat(out)
end

local function idExists(id)
  for _, n in ipairs(notes) do
    if n.id == id then return true end
  end
  return false
end

-- Note ids: millisecond stamp + a per-run sequence, so same-millisecond
-- creations can never exhaust the id space (the old 10-99 random could, in
-- theory, loop forever under a same-millisecond flood). The idExists guard
-- also covers collisions with ids left behind by older plugin versions.
local idSeq = 0

local function makeId()
  local stamp = tostring(math.floor(nowMs()))
  local id
  repeat
    idSeq += 1
    id = "n_" .. stamp .. "_" .. idSeq
  until not idExists(id)
  return id
end

local function makeNote(text)
  local stamp = nowMs()
  return {
    id    = makeId(),
    text  = text or "",
    time  = stamp,
    mtime = stamp,
  }
end

local function currentNote()
  for _, n in ipairs(notes) do
    if n.id == currentId then return n end
  end
  return notes[1]
end

local function persistLastId()
  -- Best effort: losing this only means the pad reopens on the first note.
  noctalia.writeFile(stateFile, noctalia.json.encode({ lastId = currentId }))
end

local function saveNotes()
  lastAttempt = nowMs()   -- counted even on failure, for the retry back-off
  local ok, encoded = pcall(noctalia.json.encode, notes)
  if not ok or encoded == nil then
    saveError = true
    return
  end
  -- Treat only an explicit `false` as failure, so hosts that return nothing
  -- still count as success.
  if noctalia.writeFile(notesFile, encoded) == false then
    saveError = true
    return
  end
  dirty = false
  saveError = false
  savedAt = nowMs()
end

local function loadNotes()
  local raw = noctalia.readFile(notesFile)
  local ok, decoded = false, nil
  if raw and raw ~= "" then
    ok, decoded = pcall(function() return noctalia.json.decode(raw) end)
  end
  if ok and type(decoded) == "table" and #decoded > 0 then
    -- Keep only usable entries so a half-corrupt file cannot crash the pad.
    local loaded = {}
    for _, n in ipairs(decoded) do
      if type(n) == "table" and type(n.id) == "string" then
        loaded[#loaded + 1] = n
      end
    end
    if #loaded > 0 then
      notes = loaded
      local migrated = false
      for _, n in ipairs(notes) do
        -- Type-harden what a corrupt or hand-edited file may bend: a
        -- non-string text would crash every :match call further on.
        if type(n.text) ~= "string" then
          n.text = tostring(n.text or "")
          migrated = true
        end
        -- 0.6.0 downgrade migration: the removed picture experiment stored
        -- images as {{img:<id>}} markers plus an attachments array. Plain
        -- text again — strip the markers, drop the records and their files,
        -- and never let a stale images field linger in the JSON.
        local imgs = n.images
        n.images = nil
        if imgs ~= nil then migrated = true end
        if type(imgs) == "table" then
          for _, img in ipairs(imgs) do
            noctalia.removeFile(imageDir .. "/" .. tostring(img.file))
          end
        end
        local stripped = tostring(n.text):gsub("{{img:[^}]+}}", "")
        if stripped ~= n.text then
          n.text = stripped
          migrated = true
        end
        -- Drop the old title field entirely. If it held usable text, fold it
        -- into the body first so nothing is lost; the body's first line is now
        -- the name. A non-string title is corruption: drop it without folding.
        if n.title ~= nil then
          if type(n.title) == "string" and n.title ~= "" then
            if n.text == "" then n.text = n.title
            else n.text = n.title .. "\n" .. n.text end
          end
          n.title = nil
          migrated = true
        end
      end
      if migrated then saveNotes() end
      -- Reopen on the note that was edited last (falls back to the first one).
      currentId = nil
      local rawState = noctalia.readFile(stateFile)
      if rawState and rawState ~= "" then
        local okState, state = pcall(function() return noctalia.json.decode(rawState) end)
        local lastId = okState and type(state) == "table" and state.lastId or nil
        if lastId then
          for _, n in ipairs(notes) do
            if n.id == lastId then currentId = lastId break end
          end
        end
      end
      if not currentId then currentId = notes[1].id end
      dirty = false
      saveError = false
      savedAt = nowMs()
      persistLastId()
      return
    end
  end

  -- Fresh start, or migrating the old single-document layout into note #1.
  -- If the old file held anything, keep it as notes.json.bak before rebuilding.
  if raw and raw ~= "" then
    noctalia.writeFile(dataDir .. "/notes.json.bak", raw)
  end
  notes = {}
  local first = makeNote("")
  local legacy = noctalia.readFile(legacyDoc)
  if legacy and legacy ~= "" then first.text = legacy end
  notes[1] = first
  currentId = first.id
  dirty = false
  saveError = false
  saveNotes()
  persistLastId()
end

-- A sticky note has no title field: its name is the first line of its body.
local function noteTitle(n)
  local first = (tostring(n.text or ""):match("([^\n]+)") or ""):gsub("^%s+", "")
  local t = truncate(first, 12)
  if t == "" then t = tr("empty_note") end
  return t
end

local function noteLabel(n, i)
  return tostring(i) .. ". " .. noteTitle(n)
end

local function noteChanged()
  local n = currentNote()
  if n then n.mtime = nowMs() end
  dirty = true
  lastEditAt = nowMs()   -- idle-debounce anchor for auto-save
  uiDirty = true
end

-- Clipboard text copied from browsers often carries invisible artifacts in
-- its text/plain flavor: zero-width spaces, BOM leftovers, soft hyphens and
-- Windows CRLF endings. They cannot be seen but pollute the note data, the
-- char count and any later copy-out. ZWJ (U+200D) is deliberately kept —
-- composed emoji need it.
local function sanitizeText(s)
  s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
  s = s:gsub("\226\128\139", "")   -- U+200B zero-width space
  s = s:gsub("\239\187\191", "")   -- U+FEFF BOM / zero-width no-break space
  s = s:gsub("\194\173", "")       -- U+00AD soft hyphen
  return s
end

-- Hover state is tracked per row AND per delete button. The delete button only
-- stays visible while either the row or the button itself is hovered — moving
-- the mouse onto the button makes the ROW report "false", so the button's own
-- hover must keep it alive. Only re-render when a value actually changes.
local function makeHover(id, which)
  return function(state)
    local v = (state == "true") and id or nil
    local old
    if which == "row" then old = hoverRow; hoverRow = v
    else old = hoverBtn; hoverBtn = v end
    if old ~= v then render() end
  end
end

local function clearPending()
  pendingDel = nil
  pendingAt  = 0
end

local function selectNote(id)
  if id == currentId then return end
  local exists = false
  for _, x in ipairs(notes) do if x.id == id then exists = true break end end
  if not exists then return end   -- e.g. a click bubbled from a just-deleted row
  if pendingDel then clearPending() end   -- switching away cancels an armed delete
  if dirty then saveNotes() end
  currentId = id
  persistLastId()
  editorGen += 1          -- new key => editor is re-seeded with THIS note's text
  startAnimation(ANIM_SWITCH)
end

local function newNote(firstText)
  if pendingDel then clearPending() end
  if dirty then saveNotes() end
  local n = makeNote(firstText or "")
  notes[#notes + 1] = n
  currentId = n.id
  persistLastId()
  editorGen += 1
  saveNotes()
  startAnimation(ANIM_SWITCH)
end

local function deleteNote(id)
  local idx = nil
  for i, n in ipairs(notes) do
    if n.id == id then idx = i break end
  end
  if not idx then return end
  table.remove(notes, idx)
  local switched = false
  if #notes == 0 then
    local n = makeNote("")
    notes[1] = n
    currentId = n.id
    switched = true
  elseif currentId == id then
    currentId = notes[math.min(idx, #notes)].id
    switched = true
  end
  if switched then
    persistLastId()
    editorGen += 1   -- only rebuild the editor when the visible note changed
  end
  clearPending()
  hoverRow, hoverBtn = nil, nil
  saveNotes()
  if switched then startAnimation(ANIM_SWITCH) else render() end
end

-- Two-step delete: first click arms this note's button, second click confirms.
-- Arming another note switches the target; switching notes / timeout cancels it.
-- A confirm click within 400 ms of arming is treated as a double-click and
-- ignored — two fast clicks must never delete in one motion.
local function requestDelete(id)
  if pendingDel == id then
    if nowMs() - pendingAt < ARM_CONFIRM_MS then return end
    deleteNote(id)
    return
  end
  if dirty then saveNotes() end
  pendingDel = id
  pendingAt  = nowMs()
  render()
end

render = function()
  uiDirty = false
  local n        = currentNote()
  local text     = n and n.text or ""

  local e         = animEased()
  local opening   = anim and anim.kind == ANIM_OPEN
  local switching = anim and anim.kind == ANIM_SWITCH
  local pageOpacity = opening and (0.30 + 0.70 * e) or 1
  local pageY       = opening and ((1 - e) * 8) or 0
  local cardOpacity = switching and (0.40 + 0.60 * e) or 1
  local cardY       = switching and ((1 - e) * 12) or 0

  -- LEFT: one-line note rows — title only, hover reveals the squared-off
  -- delete button; the accent tint marks the open note (Apple Notes style).
  local items = {}
  for i, item in ipairs(notes) do
    local id      = item.id
    local active  = (id == currentId)
    local armed   = (pendingDel == id)
    local visible = (hoverRow == id) or (hoverBtn == id)
    local bg
    if armed then bg = "error/0.16"           -- red-ish tint while awaiting confirmation
    elseif active then bg = "primary/0.14"
    elseif visible then bg = "surface_container/0.60"
    else bg = "surface_container/0.28" end
    items[#items + 1] = ui.row({
      key       = "note-" .. id,
      gap       = 8,
      paddingH  = 10,
      paddingV  = 8,
      align     = "center",
      fill      = bg,
      radius    = 12,
      translateX = (switching and active) and ((1 - e) * 10) or 0,
      onClick   = function()
        -- Ignore the click that bubbles from arming the button right below.
        if pendingDel == id and nowMs() - pendingAt < 250 then return end
        -- A deliberate click on an armed row cancels the pending delete.
        if pendingDel == id then clearPending(); render(); return end
        selectNote(id)
      end,
      onHover   = makeHover(id, "row"),
    }, {
      ui.label({
        text = noteTitle(item),
        fontSize = 13,
        fontWeight = active and "bold" or "normal",
        color = active and "on_surface" or "on_surface_variant",
        flexGrow = 1,
        maxLines = 1,
      }),
      -- Squared-off delete control, drawn as a 20×20 block: ui.button has no
      -- radius prop, so a custom block is the way to get 方正 corners. It
      -- tints red on hover and turns solid red while delete is armed.
      ui.row({
        key = "del-" .. id,
        width  = 20,
        height = 20,
        radius = 3,
        align  = "center",
        fill   = armed and "error"
                 or ((hoverBtn == id) and "error/0.35" or "surface_container/0.55"),
        tooltip = armed and tr("delete_armed_tooltip") or tr("delete_hint"),
        visible = armed or visible,   -- stay visible while awaiting confirmation
        onClick  = function() requestDelete(id) end,
        onHover  = makeHover(id, "btn"),
      }, {
        ui.spacer({ flexGrow = 1 }),
        ui.label({
          text = "×", fontSize = 14, fontWeight = "bold",
          color = armed and "on_error" or "on_surface_variant",
        }),
        ui.spacer({ flexGrow = 1 }),
      }),
    })
  end
  local listCol = ui.column({ width = 180, padding = 10, gap = 6 }, {
    ui.row({ height = 32, align = "center" }, {
      ui.spacer({ flexGrow = 1 }),
      ui.label({
        text = tr("list_heading"),
        fontSize = 15, fontWeight = "bold", color = "on_surface",
      }),
      ui.spacer({ flexGrow = 1 }),
    }),
    ui.scroll({
      flexGrow = 1, gap = 6,
      revealKey = "note-" .. tostring(currentId),
    }, items),
  })

  -- RIGHT: a slim icon toolbar over one sheet of paper. Saved state is silent
  -- (auto-save is assumed); the footer only speaks when it must.
  local statusText, statusColor
  if saveError then
    statusText, statusColor = tr("status_save_failed"), "error"
  elseif dirty then
    statusText, statusColor = tr("status_unsaved"), "primary"
  else
    statusText, statusColor = "", "on_surface_variant"
  end
  local editorCol = ui.column({
    flexGrow = 1, padding = 14, gap = 8,
    opacity = cardOpacity, translateY = cardY,
  }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.spacer({ flexGrow = 1 }),
      ui.button({
        glyph = "plus", variant = "ghost", controlSize = "sm",
        tooltip = tr("new_note"), onClick = "onNewNote",
      }),
      ui.button({
        glyph = "close", variant = "ghost", controlSize = "sm",
        tooltip = tr("close"), onClick = "onCloseClicked",
      }),
    }),
    ui.input({
      key = "editor-" .. tostring(currentId) .. "-" .. tostring(editorGen),
      value = text,
      placeholder = tr("placeholder"),
      multiline = true,
      flexGrow = 1,
      fontSize = 14,
      frameVisible = false,
      focus = true,
      onChange = "onTextChange",
      onSubmit = "onTextSubmit",
    }),
    ui.row({ gap = 8, align = "center", height = 20 }, {
      ui.label({ text = statusText, fontSize = 10, color = statusColor }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({
        text = tr("stats", { chars = charCount(text) }),
        fontSize = 10, color = "on_surface_variant",
      }),
      ui.button({
        glyph = "folder-open", variant = "ghost", controlSize = "sm", height = 20,
        glyphSize = 13,
        tooltip = tr("open_folder"), onClick = "onOpenFolder",
      }),
    }),
  })

  panel.render(ui.column({
    flexGrow = 1,
    opacity = pageOpacity, translateY = pageY,
  }, {
    -- Body only: no banner, no big title — the content is the hero. Sidebar
    -- and canvas run edge-to-edge with a hairline divider between them, like
    -- a native app window rather than a page floating in a box.
    ui.row({ flexGrow = 1, align = "stretch", clip = true }, {
      listCol,
      ui.separator({ thickness = 1, orientation = "vertical" }),
      editorCol,
    }),
  }))
end

function onOpen(_context)
  loadNotes()
  clearPending()
  hoverRow, hoverBtn = nil, nil
  savedAt = nowMs()
  -- A fresh key re-seeds the editor (so it focuses on a persistent surface
  -- that was previously closed) and gives the opening slide something to run.
  editorGen += 1
  startAnimation(ANIM_OPEN, OPEN_ANIM_MS)
end

function onClose()
  if dirty then saveNotes() end
  clearPending()
  stopAnimation()
  uiDirty = false
end

-- Flush pending edits on hot reload / disable / shutdown so nothing typed in
-- the last second is lost. Cleanup must stay short and idempotent.
function onExit(_signal, _reason)
  if dirty then saveNotes() end
  stopAnimation()
end

function update()
  local t = nowMs()
  if pendingDel and t - pendingAt > CONFIRM_MS then
    clearPending()
    render()
  end
  -- Idle debounce (900 ms after the last keystroke) with a 5 s checkpoint
  -- while typing non-stop; the attempt gate backs off to 3 s on failures.
  if dirty and t - lastAttempt >= SAVE_RETRY_MS
     and (t - lastEditAt >= SAVE_QUIET_MS or t - savedAt >= SAVE_MAX_MS) then
    saveNotes()
    uiDirty = true
  end
  -- One repaint per tick, however many keystrokes arrived in between.
  if uiDirty then render() end
end

-- Frame ticks run only while an animation is in flight; the host coalesces
-- them for a slow script, so cap big deltas instead of jumping past the end.
function onFrameTick(deltaMs)
  if not anim then return end
  local dt = tonumber(deltaMs) or 16
  if dt < 0 then dt = 0 elseif dt > 64 then dt = 64 end
  anim.elapsed += dt
  if anim.elapsed >= anim.duration then stopAnimation() end
  render()
end

function onTextChange(value)
  local n = currentNote()
  if not n then return end
  local clean = sanitizeText(value or "")
  n.text = clean
  -- Typing cancels an armed delete: a user who goes back to editing clearly
  -- does not intend the pending confirm.
  if pendingDel then clearPending() end
  noteChanged()
  -- Bytes were actually cleaned (a paste carried invisible artifacts): re-seed
  -- the input so its displayed text matches the clean note. Rare — ordinary
  -- typing never hits this branch, so the caret is never disturbed.
  if clean ~= (value or "") then editorGen += 1 end
  -- Paint immediately: the list name and footer must follow the keystroke
  -- instead of waiting for the next update tick. The retained tree with
  -- stable keys makes a per-keystroke rebuild cheap.
  render()
end

function onTextSubmit(value)
  local n = currentNote()
  if not n then return end
  n.text = value or ""
  noteChanged()
  saveNotes()
  render()
end

function onNewNote()     newNote() end
function onOpenFolder()  noctalia.runAsync(openFolderCmd) end
function onCloseClicked() panel.close() end

-- Declared in plugin.toml capture_keys. A chord is consumed by the panel
-- while focused; plain typing and ordinary Ctrl+V still go to the editor —
-- the field is plain-text, so pasted formatting is dropped automatically.
function onKey(chord, pressed)
  if pressed ~= true and pressed ~= "true" then return end
  if chord == "ctrl+n" then newNote() end
end

-- IPC (panel must be open). add/append edit current note; new [text]/select/delete manage the list.
function onIpc(event, payload)
  if event == "add" or event == "append" then
    local n = currentNote()
    if not n then return end
    if n.text ~= "" and not n.text:match("\n$") then n.text = n.text .. "\n" end
    n.text = n.text .. sanitizeText(payload or "")
    noteChanged()
    saveNotes(); editorGen += 1; render()
  elseif event == "new" then
    newNote(payload)
  elseif event == "select" then
    local idx = tonumber(payload)
    if idx and notes[idx] then selectNote(notes[idx].id) end
  elseif event == "delete" then
    -- Explicit shell command: delete immediately (a typed command is itself intent).
    local n = currentNote(); if n then deleteNote(n.id) end
  elseif event == "confirm-delete" then
    -- Two-step path (same one the UI button uses): first call arms, second deletes.
    local n = currentNote(); if n then requestDelete(n.id) end
  elseif event == "list" then
    -- Cap the notification so a long list cannot flood it.
    local parts = {}
    for i, x in ipairs(notes) do
      if i > 10 then parts[#parts + 1] = "…" break end
      parts[#parts + 1] = noteLabel(x, i)
    end
    noctalia.notify(tr("title"),
      tr("notes_listed", { count = #notes, list = table.concat(parts, " | ") }))
  end
end
