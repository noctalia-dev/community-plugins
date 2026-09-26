--!nonstrict
local Store = require("./lib/store.luau")
local AI = require("./lib/ai.luau")
local Capture = require("./lib/capture.luau")
local Text = require("./lib/text.luau")

local isOpen = false
local tab = "todos"
local snapshot = noctalia.state.get("snapshot")
local index = noctalia.state.get("index") or {}

local captureText = ""
local captureGeneration = 0
local captureBusy = false
local captureStatus = nil
local aiCapture = noctalia.getConfig("ai_capture") ~= false

local searchText = ""
local searchGeneration = 0
-- Caps how many todos one AI extraction may append, so a runaway or injected
-- response cannot turn into thousands of whole-file rewrites.
local EXTRACT_TODO_LIMIT = 100

local newNoteText = ""
local newNoteGeneration = 0
local showDone = false
local todoStatus = nil
local todoTagFilter = nil
local dueEditor = nil

local noteRel = nil
local noteParts = nil
local noteDraft = nil
local noteTitle = nil
local noteEditing = false
local editGeneration = 0
local noteBusy = false
local noteStatus = nil
local noteDeleteArmed = false
local noteForceSave = false

local rewriteText = ""
local rewriteGeneration = 0

local askText = ""
local askGeneration = 0
local askBusy = false
local askLog = {}

local function shellQuote(value)
  return "'" .. string.gsub(tostring(value), "'", "'\\''") .. "'"
end

local function counts()
  if snapshot ~= nil and snapshot.counts ~= nil then
    return snapshot.counts
  end
  return { open = 0, done = 0, due_today = 0, overdue = 0, notes = 0 }
end

local function plural(n, word)
  return tostring(n) .. " " .. word .. (n == 1 and "" or "s")
end

local function refresh()
  noctalia.state.set("refresh_request", noctalia.nowMs())
end

-- Noctalia runs terminal commands through a login shell, so every word of
-- $EDITOR is quoted individually rather than pasted in as one string.
local function editor()
  local value = noctalia.getenv("EDITOR")
  if value == nil or Text.trim(value) == "" then
    return shellQuote("vi")
  end
  local words = {}
  for word in string.gmatch(value, "%S+") do
    words[#words + 1] = shellQuote(word)
  end
  if #words == 0 then
    return shellQuote("vi")
  end
  return table.concat(words, " ")
end

local function todoMeta(todo)
  local parts = { todo.path }
  local due = Text.fmtDue(todo.due, todo.time)
  if due ~= nil then
    parts[#parts + 1] = due
  end
  if todo.rolled then
    parts[#parts + 1] = "recurring"
  end
  if todo.recurrence ~= nil then
    parts[#parts + 1] = "@" .. todo.recurrence
  end
  if #todo.tags > 0 then
    parts[#parts + 1] = "#" .. table.concat(todo.tags, " #")
  end
  if todo.priority == 2 then
    parts[#parts + 1] = "urgent"
  end
  return table.concat(parts, " · ")
end

local function isOverdue(todo)
  return not todo.done and Text.isOverdue(todo.due, todo.time)
end

local render
local rewriteNote

local function openNote(rel)
  local note = Store.findNote(snapshot, rel)
  local parts, err = Store.readNote(rel)
  if parts == nil then
    noctalia.notifyError("Quill", err or ("Could not read " .. tostring(rel)))
    return
  end
  noteRel = rel
  noteParts = parts
  noteDraft = parts.body
  noteTitle = note ~= nil and note.title or rel
  noteEditing = false
  noteStatus = nil
  noteDeleteArmed = false
  noteForceSave = false
  tab = "notes"
  if isOpen then
    render()
  end
end

local function toggleTodo(todo, done)
  local ok, err = Store.setTodoDone(todo.path, todo.line, done)
  if not ok then
    noctalia.notifyError("Quill", err or "could not update the todo")
    return
  end
  if done and todo.recurrence ~= nil then
    local nextDue = Text.nextRecurrence(todo.due, todo.recurrence)
    Store.appendTodo(todo.text, nextDue, todo.tags, todo.priority, todo.recurrence, todo.path, todo.time)
    local nextLabel = nextDue ~= nil and (nextDue .. (todo.time ~= nil and (" " .. todo.time) or "")) or nil
    noctalia.notify("Quill", "Recurring todo rescheduled" .. (nextLabel ~= nil and (" for " .. nextLabel) or ""))
  end
  Store.markDirty()
  if isOpen then
    render()
  end
end

local function deleteTodo(todo)
  local ok, err = Store.deleteLine(todo.path, todo.line)
  if not ok then
    noctalia.notifyError("Quill", err or "could not delete the todo")
    return
  end
  Store.markDirty()
  todoStatus = "Deleted: " .. Text.truncate(todo.text, 44)
  if isOpen then
    render()
  end
end

local function openDueEditor(todo)
  dueEditor = {
    path = todo.path,
    line = todo.line,
    date = todo.due,
    time = todo.time,
    dateInput = todo.due or "",
    timeInput = todo.time or "",
    generation = (dueEditor ~= nil and dueEditor.generation or 0) + 1,
  }
  render()
end

local function closeDueEditor()
  dueEditor = nil
  render()
end

local function saveDueEditor()
  if dueEditor == nil then
    return
  end
  local dateValue = Text.trim(dueEditor.dateInput or "")
  if dateValue == "" then
    dueEditor.date = nil
  elseif string.match(dateValue, "^%d%d%d%d%-%d%d%-%d%d$") ~= nil and Text.isoEpoch(dateValue) ~= nil then
    dueEditor.date = dateValue
  else
    noctalia.notifyError("Quill", "Use a date in YYYY-MM-DD format")
    return
  end
  dueEditor.dateInput = dueEditor.date or ""
  if dueEditor.date == nil then
    dueEditor.time = nil
    dueEditor.timeInput = ""
  else
    local timeValue = Text.safeTime(dueEditor.timeInput or "")
    if timeValue ~= nil then
      dueEditor.time = timeValue
      dueEditor.timeInput = timeValue
    end
  end
  local ok, err = Store.setTodoDue(dueEditor.path, dueEditor.line, dueEditor.date, dueEditor.time)
  if not ok then
    noctalia.notifyError("Quill", err or "Could not set the due date")
    return
  end
  dueEditor = nil
  Store.markDirty()
  render()
end

local function applyDueDateInput()
  if dueEditor == nil then
    return
  end
  local value = Text.trim(dueEditor.dateInput or "")
  if value == "" then
    dueEditor.date = nil
    dueEditor.time = nil
    dueEditor.timeInput = ""
    render()
    return
  end
  if string.match(value, "^%d%d%d%d%-%d%d%-%d%d$") == nil or Text.isoEpoch(value) == nil then
    noctalia.notifyError("Quill", "Use a date in YYYY-MM-DD format")
    return
  end
  dueEditor.date = value
  render()
end

local function applyDueTimeInput()
  if dueEditor == nil then
    return
  end
  if dueEditor.date == nil then
    noctalia.notifyError("Quill", "Choose a date before setting a time")
    return
  end
  local value = Text.safeTime(dueEditor.timeInput or "")
  if value == nil then
    noctalia.notifyError("Quill", "Use a 24-hour time in HH:MM format")
    return
  end
  dueEditor.time = value
  dueEditor.timeInput = value
  render()
end

local function dueSelectData()
  local today = Text.todayIso()
  local values = { "" }
  local labels = { "No date" }
  for offset = 0, 29 do
    local date = Text.addDays(today, offset)
    values[#values + 1] = date
    if offset == 0 then
      labels[#labels + 1] = "Today · " .. date
    elseif offset == 1 then
      labels[#labels + 1] = "Tomorrow · " .. date
    else
      labels[#labels + 1] = "In " .. tostring(offset) .. " days · " .. date
    end
  end
  local selected = 0
  local found = false
  for index, value in ipairs(values) do
    if value == (dueEditor ~= nil and dueEditor.date or "") then
      selected = index - 1
      found = true
      break
    end
  end
  if not found and dueEditor ~= nil and dueEditor.date ~= nil and dueEditor.date ~= "" then
    values[#values + 1] = dueEditor.date
    labels[#labels + 1] = "Custom · " .. dueEditor.date
    selected = #values - 1
  end
  return values, labels, selected
end

local function timeSelectData()
  local values = { "" }
  local labels = { "No time" }
  for slot = 0, 95 do
    local minutes = slot * 15
    local value = string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
    values[#values + 1] = value
    labels[#labels + 1] = value
  end
  local selected = 0
  for index, value in ipairs(values) do
    if value == (dueEditor ~= nil and dueEditor.time or "") then
      selected = index - 1
      break
    end
  end
  return values, labels, selected
end

local function renderDueEditor()
  if dueEditor == nil then
    return nil
  end
  local dateValues, dateLabels, dateIndex = dueSelectData()
  local timeValues, timeLabels, timeIndex = timeSelectData()
  return ui.column({
    key = "due-editor-" .. tostring(dueEditor.generation),
    fill = "surface_variant",
    radius = 10,
    padding = 10,
    gap = 6,
  }, {
    ui.label({ text = "Due date and time", fontSize = 13, fontWeight = "bold" }),
    ui.label({ text = "Date", fontSize = 10, color = "on_surface_variant" }),
    ui.select({
      key = "due-date-select-" .. tostring(dueEditor.generation),
      options = dateLabels,
      selectedIndex = dateIndex,
      onChange = function(index, _text)
        local selected = tonumber(index) or 0
        dueEditor.date = dateValues[selected + 1]
        dueEditor.dateInput = dueEditor.date or ""
        if dueEditor.date == nil or dueEditor.date == "" then
          dueEditor.time = nil
          dueEditor.timeInput = ""
        end
        render()
      end,
    }),
    ui.input({
      key = "due-date-input-" .. tostring(dueEditor.generation) .. "-" .. tostring(dueEditor.date),
      value = dueEditor.dateInput,
      placeholder = "YYYY-MM-DD",
      onChange = function(value)
        dueEditor.dateInput = value
      end,
      onSubmit = function()
        applyDueDateInput()
      end,
    }),
    ui.label({ text = "Time", fontSize = 10, color = "on_surface_variant" }),
    ui.select({
      key = "due-time-select-" .. tostring(dueEditor.generation),
      options = timeLabels,
      selectedIndex = timeIndex,
      enabled = dueEditor.date ~= nil,
      onChange = function(index, _text)
        local selected = tonumber(index) or 0
        dueEditor.time = timeValues[selected + 1]
        dueEditor.timeInput = dueEditor.time or ""
        render()
      end,
    }),
    ui.input({
      key = "due-time-input-" .. tostring(dueEditor.generation) .. "-" .. tostring(dueEditor.time),
      value = dueEditor.timeInput,
      placeholder = "HH:MM (24-hour)",
      enabled = dueEditor.date ~= nil,
      onChange = function(value)
        dueEditor.timeInput = value
      end,
      onSubmit = function()
        applyDueTimeInput()
      end,
    }),
    ui.row({ gap = 6, justify = "end" }, {
      ui.button({ text = "Cancel", variant = "ghost", onClick = closeDueEditor }),
      ui.button({ text = "Save", variant = "primary", onClick = saveDueEditor }),
    }),
  })
end

local function clearDone()
  local removed = Store.archiveCompleted()
  if removed > 0 then
    Store.markDirty()
    noctalia.notify("Quill", "Archived " .. tostring(removed) .. " completed todo(s)")
  end
  if isOpen then
    render()
  end
end

local function undoLast()
  local label = Store.undoLast()
  if label == nil then
    noctalia.notify("Quill", "Nothing to undo")
    return
  end
  Store.markDirty()
  noctalia.notify("Quill", "Undid the last change in " .. label)
  if isOpen then
    render()
  end
end

local function openDaily()
  local _, rel = Store.dailyNote()
  if rel == nil then
    noctalia.notifyError("Quill", "Could not create the daily note")
    return
  end
  Store.markDirty()
  openNote(rel)
end

local function saveNote()
  if noteRel == nil or noteDraft == nil then
    return
  end
  local current = Store.readNote(noteRel)
  if current ~= nil and noteParts ~= nil and current.raw ~= noteParts.raw and not noteForceSave then
    noteForceSave = true
    noteStatus = "Changed on disk — Save again to overwrite"
    render()
    return
  end
  noteForceSave = false
  Store.writeBody(noteRel, noteDraft)
  noteParts = Store.readNote(noteRel)
  Store.markDirty()
  noteEditing = false
  noteStatus = "Saved"
  if isOpen then
    render()
  end
end

local function buildContext(question)
  local limit = tonumber(noctalia.getConfig("max_context_notes")) or 4
  local chosen = Store.relevantNotes(question, snapshot, index, limit)
  local parts = {}

  local openTodos = {}
  for _, todo in ipairs(snapshot ~= nil and snapshot.todos or {}) do
    if not todo.done then
      openTodos[#openTodos + 1] = "- " .. todo.text .. (todo.due ~= nil and (" (due " .. todo.due .. (todo.time ~= nil and (" " .. todo.time) or "") .. ")") or "")
      if #openTodos >= 30 then
        break
      end
    end
  end
  if #openTodos > 0 then
    parts[#parts + 1] = "## Open todos\n" .. table.concat(openTodos, "\n")
  end

  for _, note in ipairs(chosen) do
    local read = Store.readParts(note.abs)
    local body = read ~= nil and read.body or ""
    parts[#parts + 1] = "## " .. note.title .. " (" .. note.rel .. ")\n" .. Text.truncate(body, 6000)
  end

  if #parts == 0 then
    parts[#parts + 1] = "(no notes or todos found)"
  end
  return table.concat(parts, "\n\n"), chosen
end

local function pushAskTurn(role, content, sources)
  askLog[#askLog + 1] = { role = role, content = content, sources = sources }
  while #askLog > 20 do
    table.remove(askLog, 1)
  end
end

local function submitAsk(text)
  text = Text.trim(text)
  if text == "" or askBusy then
    return
  end
  local ok, reason = AI.available()
  if not ok then
    noctalia.notifyError("Quill", reason or "AI is unavailable")
    return
  end

  local history = {}
  for _, turn in ipairs(askLog) do
    if turn.role == "user" or turn.role == "assistant" then
      history[#history + 1] = turn
    end
  end

  askText = ""
  askGeneration = askGeneration + 1
  pushAskTurn("user", text)
  askBusy = true
  if isOpen then
    render()
  end

  local context, sources = buildContext(text)
  AI.ask(text, context, history, function(answer, err)
    askBusy = false
    if answer == nil then
      pushAskTurn("error", tostring(err))
    else
      local titles = {}
      for _, source in ipairs(sources) do
        titles[#titles + 1] = source.title
      end
      pushAskTurn("assistant", answer, titles)
    end
    if isOpen then
      render()
    end
  end)
end

local function runPlanDay()
  if askBusy then
    return
  end
  local ok, reason = AI.available()
  if not ok then
    noctalia.notifyError("Quill", reason or "AI is unavailable")
    return
  end
  local todos = {}
  for _, todo in ipairs(snapshot ~= nil and snapshot.todos or {}) do
    if not todo.done then
      todos[#todos + 1] = "- " .. todo.text
        .. (todo.due ~= nil and (" (due " .. todo.due .. (todo.time ~= nil and (" " .. todo.time) or "") .. ")") or "")
        .. (todo.priority == 2 and " (urgent)" or "")
      if #todos >= 40 then
        break
      end
    end
  end
  if #todos == 0 then
    noctalia.notify("Quill", "No open todos to plan")
    return
  end
  tab = "ask"
  pushAskTurn("user", "Plan my day")
  askBusy = true
  render()
  AI.planDay(todos, function(out, err)
    askBusy = false
    if out == nil then
      pushAskTurn("error", tostring(err))
    else
      pushAskTurn("assistant", out, { "open todos" })
    end
    if isOpen then
      render()
    end
  end)
end

local function runWeeklyReview()
  if askBusy then
    return
  end
  local ok, reason = AI.available()
  if not ok then
    noctalia.notifyError("Quill", reason or "AI is unavailable")
    return
  end
  local done, open = {}, {}
  for _, todo in ipairs(snapshot ~= nil and snapshot.todos or {}) do
    if todo.done then
      done[#done + 1] = "- " .. todo.text
    else
      open[#open + 1] = "- " .. todo.text
    end
  end
  local recent = {}
  for i, note in ipairs(snapshot ~= nil and snapshot.notes or {}) do
    recent[#recent + 1] = "- " .. note.title
    if i >= 15 then
      break
    end
  end
  local context = "Today is " .. Text.todayIso()
    .. ".\n\nCompleted todos:\n" .. (#done > 0 and table.concat(done, "\n") or "(none)")
    .. "\n\nStill open:\n" .. (#open > 0 and table.concat(open, "\n") or "(none)")
    .. "\n\nRecently touched notes:\n" .. (#recent > 0 and table.concat(recent, "\n") or "(none)")
  tab = "ask"
  pushAskTurn("user", "Weekly review")
  askBusy = true
  render()
  AI.weeklyReview(context, function(out, err)
    askBusy = false
    if out == nil then
      pushAskTurn("error", tostring(err))
    else
      pushAskTurn("assistant", out, { "your notes" })
    end
    if isOpen then
      render()
    end
  end)
end

local function handlePending()
  local pending = noctalia.state.get("pending_action")
  if type(pending) ~= "table" or pending.kind == nil or pending.kind == "none" then
    return
  end
  noctalia.state.set("pending_action", { kind = "none" })
  if pending.kind == "ask" then
    tab = "ask"
    onAsk(pending.text or "")
  elseif pending.kind == "open_note" then
    openNote(pending.path or "")
  elseif pending.kind == "capture" then
    tab = "todos"
    if pending.text ~= nil and pending.text ~= "" then
      onCapture(pending.text)
    end
  elseif pending.kind == "rewrite" then
    if pending.path ~= nil and pending.path ~= "" then
      openNote(pending.path)
    end
    if pending.text ~= nil and pending.text ~= "" then
      rewriteNote(pending.text)
    end
  end
end

local function handleContext(context)
  if string.sub(context, 1, 4) == "ask:" then
    tab = "ask"
    onAsk(string.sub(context, 5))
  elseif string.sub(context, 1, 5) == "note:" then
    openNote(string.sub(context, 6))
  elseif context == "todos" or context == "notes" or context == "ask" then
    tab = context
  end
end

local COMMANDS_HELP = table.concat({
  "**Chat commands**",
  "",
  "- `/clear` — clear this conversation",
  "- `/plan` — plan my day from open todos",
  "- `/review` — weekly review",
  "- `/todo <text>` — capture a todo",
  "- `/note <title>` — create a note",
  "- `/daily` — open today's daily note",
  "- `/save [title]` — save the last answer as a note",
  "- `/copy` — copy the last answer",
  "- `/undo` — undo the last change",
  "",
  "Anything else is a question over your notes.",
}, "\n")

local function lastAssistant()
  for i = #askLog, 1, -1 do
    if askLog[i].role == "assistant" then
      return askLog[i]
    end
  end
  return nil
end

local function runCommand(text)
  local cmd, rest = string.match(text, "^/([%a][%w%-]*)(.*)$")
  if cmd == nil then
    pushAskTurn("error", "That is not a command. Try /help")
    return
  end
  cmd = string.lower(cmd)
  rest = Text.trim(rest)

  if cmd == "clear" or cmd == "cls" or cmd == "reset" then
    askLog = {}
    return
  end
  if cmd == "help" then
    pushAskTurn("assistant", COMMANDS_HELP)
    return
  end
  if cmd == "plan" then
    runPlanDay()
    return
  end
  if cmd == "review" then
    runWeeklyReview()
    return
  end
  if cmd == "daily" then
    openDaily()
    return
  end
  if cmd == "undo" then
    undoLast()
    return
  end
  if cmd == "todo" then
    if rest == "" then
      pushAskTurn("error", "Usage: /todo <text>")
      return
    end
    Capture.capture(rest, aiCapture, function(status)
      pushAskTurn("assistant", status)
      if isOpen then
        render()
      end
    end, Capture.projectContext())
    return
  end
  if cmd == "note" then
    if rest == "" then
      pushAskTurn("error", "Usage: /note <title>")
      return
    end
    Store.createNote(rest)
    Store.markDirty()
    pushAskTurn("assistant", "Created note **" .. rest .. "**")
    return
  end
  if cmd == "copy" then
    local last = lastAssistant()
    if last == nil then
      pushAskTurn("error", "Nothing to copy yet")
      return
    end
    noctalia.copyToClipboard(last.content, "text/plain")
    pushAskTurn("assistant", "Copied the last answer.")
    return
  end
  if cmd == "save" then
    local last = lastAssistant()
    if last == nil then
      pushAskTurn("error", "Nothing to save yet")
      return
    end
    local title = rest
    if title == "" then
      local heading = string.match(last.content, "^#+%s*(.+)")
      title = Text.stripMarkdown(heading or Text.firstLine(last.content) or "AI answer")
      title = Text.truncate(title, 60)
    end
    Store.createNote(title, last.content)
    Store.markDirty()
    pushAskTurn("assistant", "Saved as note **" .. title .. "**")
    return
  end

  pushAskTurn("error", "Unknown command /" .. cmd .. ". Try /help")
end

-- Callbacks (named so the UI tree can reference them).

function onCaptureChange(value)
  captureText = value or ""
end

function onCapture(value)
  local text = Text.trim((value ~= nil and value ~= "" and value) or captureText)
  if text == "" then
    return
  end
  captureText = ""
  captureGeneration = captureGeneration + 1
  todoStatus = nil

  if aiCapture and AI.available() then
    captureBusy = true
    captureStatus = "Thinking…"
    render()
  end

  Capture.capture(text, aiCapture, function(status)
    captureBusy = false
    captureStatus = status
    if isOpen then
      render()
    end
  end, Capture.projectContext())
end

function onSearchChange(value)
  searchText = value or ""
  if isOpen then
    render()
  end
end

function onNewNoteChange(value)
  newNoteText = value or ""
end

function onNewNote(value)
  local title = Text.trim((value ~= nil and value ~= "" and value) or newNoteText)
  if title == "" then
    title = "Untitled"
  end
  newNoteText = ""
  newNoteGeneration = newNoteGeneration + 1
  local abs = Store.createNote(title)
  Store.markDirty()
  openNote(Store.relative(abs))
  noteEditing = true
  editGeneration = editGeneration + 1
  if isOpen then
    render()
  end
end

function onNewNoteClick()
  onNewNote(newNoteText)
end

function onEditChange(value)
  noteDraft = value or ""
end

function onSaveNote()
  saveNote()
end

function onAskChange(value)
  askText = value or ""
end

function onAsk(value)
  local text = Text.trim((value ~= nil and value ~= "" and value) or askText)
  if text == "" then
    return
  end
  if string.sub(text, 1, 1) == "/" then
    askText = ""
    askGeneration = askGeneration + 1
    runCommand(text)
    if isOpen then
      render()
    end
    return
  end
  submitAsk(text)
end

local function summarizeNote()
  if noteParts == nil then
    return
  end
  local ok, reason = AI.available()
  if not ok then
    noctalia.notifyError("Quill", reason or "AI is unavailable")
    return
  end
  noteBusy = true
  noteStatus = "Summarizing…"
  render()
  AI.summarize(noteTitle or "", noteParts.body, function(out, err)
    noteBusy = false
    if out == nil then
      noteStatus = "AI failed: " .. tostring(err)
    else
      noteDraft = noteParts.body .. "\n\n---\n\n## Summary\n\n" .. out .. "\n"
      noteEditing = true
      editGeneration = editGeneration + 1
      noteStatus = "Review the summary, then Save"
    end
    if isOpen then
      render()
    end
  end)
end

rewriteNote = function(instruction)
  if noteParts == nil then
    return
  end
  instruction = Text.trim(instruction)
  if instruction == "" then
    return
  end
  local ok, reason = AI.available()
  if not ok then
    noctalia.notifyError("Quill", reason or "AI is unavailable")
    return
  end
  noteBusy = true
  noteStatus = "Rewriting…"
  render()
  AI.rewrite(instruction, noteTitle or "", noteParts.body, function(out, err)
    noteBusy = false
    if out == nil then
      noteStatus = "AI failed: " .. tostring(err)
    else
      noteDraft = out
      noteEditing = true
      editGeneration = editGeneration + 1
      noteStatus = "Review the rewrite, then Save"
    end
    if isOpen then
      render()
    end
  end)
end

function onRewriteChange(value)
  rewriteText = value or ""
end

function onRewrite(value)
  local instruction = Text.trim((value ~= nil and value ~= "" and value) or rewriteText)
  rewriteText = ""
  rewriteGeneration = rewriteGeneration + 1
  rewriteNote(instruction)
end

function onRewriteClick()
  onRewrite(rewriteText)
end

local function extractTodosFromNote()
  if noteParts == nil then
    return
  end
  local ok, reason = AI.available()
  if not ok then
    noctalia.notifyError("Quill", reason or "AI is unavailable")
    return
  end
  noteBusy = true
  noteStatus = "Extracting…"
  render()
  AI.extractTodos(noteTitle or "", noteParts.body, function(todos, err)
    noteBusy = false
    if todos == nil then
      noteStatus = "AI failed: " .. tostring(err)
    else
      local added, skipped = 0, 0
      for _, item in ipairs(todos) do
        if added >= EXTRACT_TODO_LIMIT then
          skipped = skipped + 1
        else
          local text = Text.trim(tostring(type(item) == "table" and (item.text or "") or item))
          if text ~= "" then
            local due = nil
            if type(item) == "table" and type(item.due) == "string" and item.due ~= "" then
              due = item.due
            end
            local priority = type(item) == "table" and (tonumber(item.priority) or 0) or 0
            local time = type(item) == "table" and Text.safeTime(item.time) or nil
            Store.appendTodo(Text.truncate(text, 200), due, nil, priority, nil, nil, time)
            added = added + 1
          end
        end
      end
      noteStatus = "Added " .. tostring(added) .. " todo(s) to " .. Store.inboxName()
      if skipped > 0 then
        noteStatus = noteStatus .. " · skipped " .. tostring(skipped) .. " over the limit of " .. tostring(EXTRACT_TODO_LIMIT)
      end
      Store.markDirty()
    end
    if isOpen then
      render()
    end
  end)
end

local function copyNote()
  if noteDraft == nil then
    return
  end
  noctalia.copyToClipboard(noteDraft, "text/plain")
  noteStatus = "Copied to clipboard"
  render()
end

local function editNoteInTerminal()
  if noteRel == nil then
    return
  end
  local abs = Store.safeAbs(noteRel)
  if abs == nil then
    noctalia.notifyError("Quill", "Unsafe note path")
    return
  end
  noctalia.runInTerminal(editor() .. " " .. shellQuote(abs))
  panel.close()
end

local function askDeleteNote()
  if not noteDeleteArmed then
    noteDeleteArmed = true
    noteStatus = "Click delete again to confirm"
    render()
    return
  end
  local rel = noteRel
  Store.deleteNote(rel)
  noteRel = nil
  noteParts = nil
  noteDraft = nil
  noteEditing = false
  noteDeleteArmed = false
  noteStatus = nil
  Store.markDirty()
  render()
end

-- Rendering.

local function tabButton(id, label, glyph)
  return ui.button({
    text = label,
    glyph = glyph,
    variant = "ghost",
    selected = tab == id,
    onClick = function()
      tab = id
      captureStatus = nil
      todoStatus = nil
      render()
    end,
  })
end

local function todoRow(todo)
  local children = {
    ui.toggle({
      checked = todo.done,
      onChange = function(value)
        toggleTodo(todo, value == "true")
      end,
    }),
    ui.column({
      flexGrow = 1,
      gap = 1,
      onClick = function()
        openNote(todo.path)
      end,
    }, {
      ui.label({
        text = todo.text,
        fontSize = 13,
        maxLines = 2,
        color = todo.done and "on_surface_variant" or nil,
      }),
      ui.label({
        text = todoMeta(todo),
        fontSize = 10,
        maxLines = 1,
        color = isOverdue(todo) and "error" or "on_surface_variant",
      }),
    }),
  }
  if todo.rolled then
    children[#children + 1] = ui.glyph({ name = "repeat", size = 13, color = "primary" })
  end
  if todo.priority == 2 then
    children[#children + 1] = ui.glyph({ name = "flame", size = 14, color = "error" })
  end
  children[#children + 1] = ui.button({
    glyph = "calendar-plus",
    variant = "ghost",
    tooltip = todo.due ~= nil and ("Due " .. (Text.fmtDue(todo.due, todo.time) or todo.due) .. " · click to edit") or "Set date and time",
    onClick = function()
      openDueEditor(todo)
    end,
  })
  children[#children + 1] = ui.button({
    glyph = "trash",
    variant = "ghost",
    tooltip = "Delete · undo from the header",
    onClick = function()
      deleteTodo(todo)
    end,
  })
  return ui.row({ key = todo.id, gap = 6, align = "center", paddingV = 3 }, children)
end

local function renderTodos()
  local children = {}
  local ok = AI.available()

  children[#children + 1] = ui.row({ gap = 8, align = "center" }, {
    ui.input({
      key = "capture-" .. tostring(captureGeneration),
      placeholder = aiCapture and "Capture a thought… AI files it" or "Add a todo…",
      flexGrow = 1,
      focus = true,
      enabled = not captureBusy,
      onSubmit = "onCapture",
      onChange = "onCaptureChange",
    }),
    ui.button({
      glyph = "sparkles",
      variant = aiCapture and "primary" or "ghost",
      tooltip = aiCapture and "AI capture is on" or "AI capture is off",
      enabled = ok,
      selected = aiCapture,
      onClick = function()
        aiCapture = not aiCapture
        render()
      end,
    }),
  })

  if captureStatus ~= nil then
    children[#children + 1] = ui.label({
      text = captureStatus,
      fontSize = 11,
      color = captureBusy and "on_surface_variant" or "primary",
      maxLines = 2,
    })
  end

  if todoStatus ~= nil then
    children[#children + 1] = ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = todoStatus, fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
      ui.button({
        key = "todo-undo",
        text = "Undo",
        variant = "ghost",
        onClick = function()
          undoLast()
          todoStatus = nil
          if isOpen then
            render()
          end
        end,
      }),
    })
  end

  local dueEditorNode = renderDueEditor()
  if dueEditorNode ~= nil then
    children[#children + 1] = dueEditorNode
    children[#children + 1] = ui.separator({ spacing = 2 })
  end

  local rows = {}
  local tagFilter = todoTagFilter
  for _, todo in ipairs(snapshot ~= nil and snapshot.todos or {}) do
    local matchesTag = tagFilter == nil
    if not matchesTag then
      for _, tag in ipairs(todo.tags or {}) do
        if tag == tagFilter then
          matchesTag = true
          break
        end
      end
    end
    if (showDone or not todo.done) and matchesTag then
      rows[#rows + 1] = todoRow(todo)
    end
  end
  if #rows == 0 then
    rows[#rows + 1] = ui.label({
      text = tagFilter ~= nil and ("No open todos tagged #" .. tagFilter .. ".") or "Nothing to do. Capture something above.",
      fontSize = 12,
      color = "on_surface_variant",
    })
  end

  local tagList = snapshot ~= nil and snapshot.tags or {}
  if #tagList > 0 then
    local chips = {
      ui.button({
        text = "All",
        variant = tagFilter == nil and "primary" or "ghost",
        onClick = function()
          todoTagFilter = nil
          render()
        end,
      }),
    }
    for index, entry in ipairs(tagList) do
      if index > 12 then
        break
      end
      local tag = entry.tag
      chips[#chips + 1] = ui.button({
        key = "tag-" .. tag,
        text = "#" .. tag,
        variant = tagFilter == tag and "primary" or "ghost",
        tooltip = tostring(entry.count) .. " todo(s) tagged #" .. tag,
        onClick = function()
          todoTagFilter = tagFilter == tag and nil or tag
          render()
        end,
      })
    end
    children[#children + 1] = ui.row({ gap = 4, wrap = true }, chips)
  end

  children[#children + 1] = ui.scroll({ flexGrow = 1, gap = 2 }, rows)

  local c = counts()
  children[#children + 1] = ui.row({ justify = "space_between", align = "center" }, {
    ui.label({
      text = tostring(c.open) .. " open · " .. tostring(c.due_today) .. " today · " .. tostring(c.overdue) .. " overdue",
      fontSize = 10,
      color = "on_surface_variant",
    }),
    ui.row({ gap = 4 }, {
      ui.button({
        text = "Clear done",
        variant = "ghost",
        enabled = c.done > 0,
        tooltip = "Move completed todos to " .. Store.archiveName(),
        onClick = clearDone,
      }),
      ui.button({
        text = showDone and "Hide done" or "Show done",
        variant = "ghost",
        onClick = function()
          showDone = not showDone
          render()
        end,
      }),
    }),
  })
  return children
end

local function noteRow(note)
  local ago = Text.relTime(os.time() - (note.mtime or os.time()))
  local meta = ago
  if note.open_todos > 0 then
    meta = meta .. " · " .. tostring(note.open_todos) .. " open"
  end
  if note.preview ~= "" then
    meta = meta .. " · " .. note.preview
  end
  return ui.row({
    key = note.rel,
    gap = 10,
    align = "center",
    paddingV = 4,
  }, {
    ui.glyph({ name = "file-text", size = 18 }),
    ui.column({
      flexGrow = 1,
      gap = 2,
      onClick = function()
        openNote(note.rel)
      end,
    }, {
      ui.label({ text = note.title, fontSize = 13, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = meta, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.button({
      glyph = "external-link",
      variant = "ghost",
      tooltip = "Edit in $EDITOR",
      onClick = function()
        noctalia.runInTerminal(editor() .. " " .. shellQuote(note.abs))
        panel.close()
      end,
    }),
  })
end

local function renderNoteView()
  local children = {}
  local ok = AI.available()

  local header = {
    ui.button({
      key = "note-back",
      glyph = "arrow-left",
      variant = "ghost",
      tooltip = "Back to notes",
      onClick = function()
        noteRel = nil
        noteParts = nil
        noteDraft = nil
        noteEditing = false
        noteStatus = nil
        noteDeleteArmed = false
        noteForceSave = false
        render()
      end,
    }),
    ui.column({ flexGrow = 1, gap = 1 }, {
      ui.label({ text = noteTitle or noteRel or "", fontSize = 14, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = noteRel or "", fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
    }),
  }
  header[#header + 1] = ui.button({
    key = "note-edit-toggle",
    glyph = noteEditing and "eye" or "pencil",
    variant = "ghost",
    tooltip = noteEditing and "Preview" or "Edit",
    onClick = function()
      noteEditing = not noteEditing
      if noteEditing then
        editGeneration = editGeneration + 1
      end
      noteStatus = nil
      noteForceSave = false
      render()
    end,
  })
  if ok then
    header[#header + 1] = ui.button({
      key = "note-summarize",
      glyph = "sparkles",
      variant = "ghost",
      tooltip = "Summarize",
      enabled = not noteBusy,
      onClick = summarizeNote,
    })
    header[#header + 1] = ui.button({
      key = "note-extract",
      glyph = "list-check",
      variant = "ghost",
      tooltip = "Extract todos",
      enabled = not noteBusy,
      onClick = extractTodosFromNote,
    })
  end
  header[#header + 1] = ui.button({
    key = "note-copy",
    glyph = "copy",
    variant = "ghost",
    tooltip = "Copy",
    onClick = copyNote,
  })
  header[#header + 1] = ui.button({
    key = "note-open-editor",
    glyph = "external-link",
    variant = "ghost",
    tooltip = "Open in $EDITOR",
    onClick = editNoteInTerminal,
  })
  header[#header + 1] = ui.button({
    key = "note-delete",
    glyph = "trash",
    variant = noteDeleteArmed and "destructive" or "ghost",
    tooltip = noteDeleteArmed and "Confirm delete" or "Delete note",
    onClick = askDeleteNote,
  })
  children[#children + 1] = ui.row({ gap = 6, align = "center" }, header)

  if noteStatus ~= nil then
    children[#children + 1] = ui.label({
      text = noteStatus,
      fontSize = 11,
      color = noteForceSave and "error" or "primary",
      maxLines = 2,
    })
  end

  if ok and not noteEditing then
    children[#children + 1] = ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = "rewrite-" .. tostring(rewriteGeneration),
        placeholder = "AI edit: improve · shorten · fix grammar · make it formal…",
        flexGrow = 1,
        enabled = not noteBusy,
        onSubmit = "onRewrite",
        onChange = "onRewriteChange",
      }),
      ui.button({
        key = "note-ai-edit",
        glyph = "sparkles",
        variant = "outline",
        tooltip = "Rewrite this note with AI",
        enabled = not noteBusy,
        onClick = "onRewriteClick",
      }),
    })
  end

  if noteEditing then
    children[#children + 1] = ui.input({
      key = "edit-" .. tostring(editGeneration),
      value = noteDraft or "",
      multiline = true,
      submitOnEnter = true,
      flexGrow = 1,
      onChange = "onEditChange",
      onSubmit = "onSaveNote",
    })
    children[#children + 1] = ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Enter saves · Shift+Enter newline", fontSize = 10, color = "on_surface_variant", flexGrow = 1 }),
      ui.button({
        key = "note-save",
        text = "Save",
        variant = "primary",
        enabled = true,
        onClick = "onSaveNote",
      }),
    })
  else
    local scrollChildren = { ui.markdown({ text = noteDraft or "" }) }
    local links = Text.wikilinks(noteDraft or "")
    if #links > 0 then
      local linkChildren = {
        ui.label({ text = "Links", fontSize = 10, color = "on_surface_variant" }),
      }
      for _, target in ipairs(links) do
        local resolved = Store.resolveLink(snapshot, target)
        linkChildren[#linkChildren + 1] = ui.button({
          key = "link-" .. target,
          text = target,
          glyph = "file-text",
          variant = "ghost",
          contentAlign = "start",
          enabled = resolved ~= nil,
          tooltip = resolved ~= nil and ("Open " .. resolved.rel) or ("No note named " .. target),
          onClick = function()
            if resolved ~= nil then
              openNote(resolved.rel)
            end
          end,
        })
      end
      scrollChildren[#scrollChildren + 1] = ui.column({ gap = 2, paddingV = 6 }, linkChildren)
    end
    children[#children + 1] = ui.scroll({ key = "note-preview", flexGrow = 1 }, scrollChildren)
  end
  return children
end

local function renderNotes()
  if noteRel ~= nil then
    return renderNoteView()
  end

  local children = {}
  children[#children + 1] = ui.input({
    key = "search-" .. tostring(searchGeneration),
    placeholder = "Search notes and their contents…",
    onChange = "onSearchChange",
  })
  children[#children + 1] = ui.row({ gap = 8, align = "center" }, {
    ui.input({
      key = "new-note-" .. tostring(newNoteGeneration),
      placeholder = "New note title…",
      flexGrow = 1,
      onSubmit = "onNewNote",
      onChange = "onNewNoteChange",
    }),
    ui.button({
      glyph = "plus",
      variant = "outline",
      tooltip = "Create note",
      onClick = "onNewNoteClick",
    }),
    ui.button({
      glyph = "calendar-plus",
      variant = "outline",
      tooltip = "Today's daily note",
      onClick = openDaily,
    }),
  })

  local notes = Store.search(snapshot, index, searchText, 60)
  if #notes == 0 then
    children[#children + 1] = ui.label({
      text = searchText == "" and "No notes yet. Create one above." or "No notes match.",
      fontSize = 12,
      color = "on_surface_variant",
    })
    return children
  end

  local rows = {}
  for _, note in ipairs(notes) do
    rows[#rows + 1] = noteRow(note)
  end
  children[#children + 1] = ui.scroll({ flexGrow = 1, gap = 2 }, rows)
  return children
end

local function askBubble(turn, index)
  if turn.role == "user" then
    return ui.row({ key = "u" .. tostring(index), justify = "end" }, {
      ui.column({ fill = "primary/0.15", radius = 10, padding = 8 }, {
        ui.label({ text = turn.content, fontSize = 12 }),
      }),
    })
  end
  if turn.role == "error" then
    return ui.row({ gap = 8, align = "start" }, {
      ui.glyph({ name = "alert-triangle", size = 14, color = "error" }),
      ui.label({ text = turn.content, fontSize = 11, color = "error" }),
    })
  end
  local children = {
    ui.markdown({ text = turn.content }),
  }
  if turn.sources ~= nil and #turn.sources > 0 then
    children[#children + 1] = ui.label({
      text = "Sources: " .. table.concat(turn.sources, ", "),
      fontSize = 10,
      color = "on_surface_variant",
    })
  end
  return ui.column({ gap = 4 }, children)
end

local function renderAsk()
  local children = {}
  local c = counts()
  local ok = AI.available()

  children[#children + 1] = ui.label({
    text = "Context: " .. plural(c.notes, "note") .. " · " .. plural(c.open, "open todo"),
    fontSize = 10,
    color = "on_surface_variant",
  })

  children[#children + 1] = ui.row({ gap = 6 }, {
    ui.button({
      text = "Plan my day",
      glyph = "calendar-stats",
      variant = "outline",
      enabled = not askBusy and ok,
      onClick = runPlanDay,
    }),
    ui.button({
      text = "Weekly review",
      glyph = "history",
      variant = "outline",
      enabled = not askBusy and ok,
      onClick = runWeeklyReview,
    }),
  })

  local rows = {}
  if #askLog == 0 then
    rows[#rows + 1] = ui.label({
      text = ok and "Ask a question about your notes and todos, or type /help for commands." or "AI is unavailable. Enable a backend in the plugin settings.",
      fontSize = 12,
      color = "on_surface_variant",
    })
  end
  for index, turn in ipairs(askLog) do
    rows[#rows + 1] = askBubble(turn, index)
  end
  if askBusy then
    rows[#rows + 1] = ui.label({ text = "Thinking…", fontSize = 11, color = "on_surface_variant" })
  end
  children[#children + 1] = ui.scroll({ flexGrow = 1, gap = 10, stickToBottom = true }, rows)

  children[#children + 1] = ui.row({ gap = 8, align = "center" }, {
    ui.input({
      key = "ask-" .. tostring(askGeneration),
      placeholder = "Ask your notes… or /help",
      flexGrow = 1,
      enabled = not askBusy and ok,
      onSubmit = "onAsk",
      onChange = "onAskChange",
    }),
    ui.button({
      glyph = "send",
      variant = "primary",
      enabled = not askBusy and ok,
      onClick = function()
        submitAsk(askText)
      end,
    }),
  })
  return children
end

render = function()
  local c = counts()
  local ok = AI.available()
  local backend = AI.backend()

  local children = {}

  local subtitle
  if snapshot == nil then
    subtitle = "indexing…"
  else
    subtitle = plural(c.open, "open") .. " · " .. plural(c.notes, "note")
    if c.overdue > 0 then
      subtitle = subtitle .. " · " .. tostring(c.overdue) .. " overdue"
    end
    if backend == "off" then
      subtitle = subtitle .. " · AI off"
    elseif not ok then
      subtitle = subtitle .. " · AI unavailable"
    end
  end

  children[#children + 1] = ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "notes", size = 24 }),
    ui.column({ flexGrow = 1, gap = 2 }, {
      ui.label({ text = "Quill", fontSize = 16, fontWeight = "bold" }),
      ui.label({ text = subtitle, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.button({
      glyph = "arrow-back-up",
      variant = "ghost",
      enabled = Store.canUndo(),
      tooltip = Store.canUndo() and ("Undo " .. tostring(Store.undoLabel())) or "Nothing to undo",
      onClick = undoLast,
    }),
    ui.button({
      glyph = "settings",
      variant = "ghost",
      tooltip = "Plugin settings",
      onClick = function()
        noctalia.openSettings()
      end,
    }),
    ui.button({
      glyph = "refresh",
      variant = "ghost",
      tooltip = "Rescan now",
      onClick = function()
        refresh()
        render()
      end,
    }),
    ui.button({
      glyph = "close",
      variant = "ghost",
      onClick = function()
        panel.close()
      end,
    }),
  })

  children[#children + 1] = ui.row({ gap = 6 }, {
    tabButton("todos", "Todos", "checkbox"),
    tabButton("notes", "Notes", "file-text"),
    tabButton("ask", "Ask", "sparkles"),
  })
  children[#children + 1] = ui.separator({ spacing = 2 })

  local body
  if tab == "notes" then
    body = renderNotes()
  elseif tab == "ask" then
    body = renderAsk()
  else
    body = renderTodos()
  end
  children[#children + 1] = ui.column({ flexGrow = 1, gap = 8 }, body)

  panel.render(ui.column({
    gap = 10,
    padding = 14,
    fill = "surface",
    radius = 16,
    border = "outline",
    borderWidth = 1,
    flexGrow = 1,
  }, children))
end

noctalia.state.watch("snapshot", function(value)
  snapshot = value
  if isOpen then
    render()
  end
end)

noctalia.state.watch("index", function(value)
  index = value or {}
end)

noctalia.state.watch("pending_action", function()
  if isOpen then
    handlePending()
  end
end)

function onOpen(context)
  isOpen = true
  if type(context) == "string" and context ~= "" then
    handleContext(context)
  end
  handlePending()
  noctalia.state.set("refresh_request", noctalia.nowMs())
  render()
end

function onClose()
  isOpen = false
  captureStatus = nil
  noteStatus = nil
  noteDeleteArmed = false
  noteForceSave = false
  todoStatus = nil
end

-- Scriptable surface, e.g. from a keybind:
--   noctalia msg plugin fel/quill:panel all ask '{"text":"what is due today?"}'
--   noctalia msg plugin fel/quill:panel all capture '{"text":"book a haircut friday"}'
--   noctalia msg plugin fel/quill:panel all open '{"path":"Inbox.md"}'
--   noctalia msg plugin fel/quill:panel all rewrite '{"path":"Inbox.md","text":"shorten"}'
function onIpc(event, payload)
  if event == "ask" then
    local text = Text.payloadField(payload, "text")
    tab = "ask"
    if isOpen then
      onAsk(text)
    else
      noctalia.state.set("pending_action", { kind = "ask", text = text })
      noctalia.togglePanel("fel/quill:panel")
    end
  elseif event == "capture" then
    local text = Text.payloadField(payload, "text")
    if isOpen then
      tab = "todos"
      onCapture(text)
    else
      noctalia.state.set("pending_action", { kind = "capture", text = text })
      noctalia.togglePanel("fel/quill:panel")
    end
  elseif event == "open" then
    local path = Text.payloadField(payload, "path")
    if isOpen then
      openNote(path)
    else
      noctalia.state.set("pending_action", { kind = "open_note", path = path })
      noctalia.togglePanel("fel/quill:panel")
    end
  elseif event == "rewrite" then
    local path = Text.payloadField(payload, "path")
    local instruction = Text.payloadField(payload, "text")
    if isOpen then
      if path ~= "" then
        openNote(path)
      end
      rewriteNote(instruction)
    else
      noctalia.state.set("pending_action", { kind = "rewrite", path = path, text = instruction })
      noctalia.togglePanel("fel/quill:panel")
    end
  elseif event == "undo" then
    undoLast()
  elseif event == "daily" then
    openDaily()
  elseif event == "clear_done" then
    clearDone()
  elseif event == "plan" then
    runPlanDay()
  elseif event == "review" then
    runWeeklyReview()
  end
end