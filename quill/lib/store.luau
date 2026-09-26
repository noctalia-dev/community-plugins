--!nonstrict
local Text = require("./text.luau")

local M = {}

local TODO_PATTERN = "^(%s*)[%-%*] %[([ xX])%]%s?(.*)$"
local UNDO_LIMIT = 25
local MAX_PARSE_BYTES = 262144

local undoStack = {}

-- Parsed notes are cached per file, keyed by mtime and size, so a poll that
-- finds no changes costs a stat per file instead of a full re-parse. This
-- keeps every callback far inside Noctalia's 12 ms CPU budget.
local parseCache = {}

local function config(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then
    return fallback
  end
  return value
end

-- Settings that name a file or folder are restricted to a single path
-- segment, so a value like "../../.bashrc" can never point outside the
-- notes folder.
local function safeName(name, fallback)
  local value = Text.trim(tostring(name or ""))
  if value == "" or value == ".." then
    return fallback
  end
  if string.sub(value, 1, 1) == "." then
    return fallback
  end
  if string.find(value, "/", 1, true) ~= nil or string.find(value, "\\", 1, true) ~= nil then
    return fallback
  end
  if string.find(value, "\0", 1, true) ~= nil then
    return fallback
  end
  return value
end

function M.notesDir()
  local raw = tostring(config("notes_dir", "~/notes"))
  if Text.trim(raw) == "" then
    raw = "~/notes"
  end
  return noctalia.expandPath(raw)
end

function M.inboxName()
  local name = safeName(config("inbox_file", "Inbox.md"), "Inbox.md")
  if string.sub(name, -3) ~= ".md" then
    name = name .. ".md"
  end
  return name
end

function M.archiveName()
  local name = safeName(config("archive_file", "Archive.md"), "Archive.md")
  if string.sub(name, -3) ~= ".md" then
    name = name .. ".md"
  end
  return name
end

function M.inboxPath()
  return M.notesDir() .. "/" .. M.inboxName()
end

function M.archivePath()
  return M.notesDir() .. "/" .. M.archiveName()
end

function M.ensureDir()
  local dir = M.notesDir()
  noctalia.mkdirAll(dir)
  local inbox = M.safeAbs(M.inboxName())
  if inbox ~= nil and not noctalia.fileExists(inbox) then
    noctalia.writeFile(inbox, "# Inbox\n\n")
  end
  return dir
end

function M.listFiles()
  local dir = M.notesDir()
  local depth = tonumber(config("scan_depth", 3)) or 3
  local archive = M.archiveName()

  local function walk(abs, rel, level, out)
    local names = noctalia.listDir(abs)
    if names == nil then
      return
    end
    table.sort(names)
    for _, name in ipairs(names) do
      if string.sub(name, 1, 1) ~= "." then
        local childAbs = abs .. "/" .. name
        local info = noctalia.fileInfo(childAbs)
        if info ~= nil then
          local childRel = rel == "" and name or (rel .. "/" .. name)
          if info.isDir then
            if level < depth then
              walk(childAbs, childRel, level + 1, out)
            end
          elseif string.sub(name, -3) == ".md" and childRel ~= archive then
            table.insert(out, {
              abs = childAbs,
              rel = childRel,
              name = string.sub(name, 1, #name - 3),
              mtime = info.mtime,
              size = info.size,
            })
          end
        end
      end
    end
  end

  local files = {}
  walk(dir, "", 0, files)
  return files
end

function M.markDirty()
  noctalia.state.set("notes_dirty", noctalia.nowMs())
  noctalia.state.set("refresh_request", noctalia.nowMs())
end

-- Undo -------------------------------------------------------------------

local function isUnsafeRel(rel)
  if rel == nil then
    return true
  end
  rel = tostring(rel)
  if rel == "" or string.sub(rel, 1, 1) == "/" or string.sub(rel, 1, 2) == "~/" then
    return true
  end
  if string.find(rel, "\0", 1, true) ~= nil then
    return true
  end
  for segment in string.gmatch(rel, "[^/]+") do
    if segment == ".." or string.sub(segment, 1, 1) == "." then
      return true
    end
  end
  return false
end

-- Resolves a note path relative to the notes folder, refusing anything that
-- escapes it (absolute paths, ~, .. segments, NUL). Returns nil when unsafe.
function M.safeAbs(rel)
  if isUnsafeRel(rel) then
    return nil
  end
  return M.notesDir() .. "/" .. rel
end

-- Normalises an AI-supplied project name into a safe relative note path
-- ("Work", "work.md", "Home Renovation" -> "Work.md"/"home-renovation.md"
-- style paths are slugified by the caller). Returns nil when unsafe.
function M.safeProjectPath(value)
  if type(value) ~= "string" then
    return nil
  end
  local clean = Text.trim(value)
  clean = string.gsub(clean, "\\", "/")
  clean = string.gsub(clean, "/+$", "")
  clean = string.gsub(clean, "//+", "/")
  if clean == "" or string.sub(clean, 1, 1) == "/" or string.find(clean, "\0", 1, true) ~= nil then
    return nil
  end
  for segment in string.gmatch(clean, "[^/]+") do
    if segment == ".." or segment == "~" or string.sub(segment, 1, 1) == "." then
      return nil
    end
  end
  if string.sub(clean, -3) ~= ".md" then
    clean = clean .. ".md"
  end
  return clean
end

local function absFor(path)
  return M.safeAbs(path)
end

local function safeDue(due)
  if type(due) ~= "string" then
    return nil
  end
  return string.match(due, "(%d%d%d%d%-%d%d%-%d%d)")
end

local function safeTag(tag)
  if tag == nil then
    return nil
  end
  return string.match(tostring(tag), "([%w%-_/]+)")
end

local function safeRecurrence(rule)
  if rule == "daily" or rule == "weekly" or rule == "monthly" then
    return rule
  end
  return nil
end

function M.pushUndo(path, label)
  local abs = absFor(path)
  if abs == nil then
    return
  end
  undoStack[#undoStack + 1] = {
    entries = { { abs = abs, content = noctalia.readFile(abs) } },
    label = label or M.relative(abs),
  }
  while #undoStack > UNDO_LIMIT do
    table.remove(undoStack, 1)
  end
end

function M.pushUndoGroup(label, paths)
  local entries = {}
  for _, path in ipairs(paths) do
    local abs = absFor(path)
    if abs ~= nil then
      entries[#entries + 1] = { abs = abs, content = noctalia.readFile(abs) }
    end
  end
  if #entries == 0 then
    return
  end
  undoStack[#undoStack + 1] = { entries = entries, label = label }
  while #undoStack > UNDO_LIMIT do
    table.remove(undoStack, 1)
  end
end

function M.canUndo()
  return #undoStack > 0
end

function M.undoLabel()
  local entry = undoStack[#undoStack]
  if entry == nil then
    return nil
  end
  return entry.label
end

function M.undoLast()
  local entry = table.remove(undoStack)
  if entry == nil then
    return nil
  end
  for _, file in ipairs(entry.entries) do
    if file.content == nil then
      noctalia.removeFile(file.abs)
    else
      noctalia.writeFile(file.abs, file.content)
    end
  end
  return entry.label
end

-- Parsing ----------------------------------------------------------------

local function splitFrontmatter(content)
  if string.sub(content, 1, 3) ~= "---" then
    return nil, content
  end
  local lines = Text.splitLines(content)
  if lines[1] == nil or Text.trim(lines[1]) ~= "---" then
    return nil, content
  end
  local closeIdx = nil
  for i = 2, #lines do
    if Text.trim(lines[i]) == "---" then
      closeIdx = i
      break
    end
  end
  if closeIdx == nil then
    return nil, content
  end
  local front = {}
  for i = 1, closeIdx do
    table.insert(front, lines[i])
  end
  local body = {}
  for i = closeIdx + 1, #lines do
    table.insert(body, lines[i])
  end
  return table.concat(front, "\n") .. "\n", table.concat(body, "\n")
end

local function parseMeta(front)
  local meta = {}
  if front == nil then
    return meta
  end
  for line in string.gmatch(front, "[^\n]+") do
    local key, value = string.match(line, "^([%w_%-]+)%s*:%s*(.*)$")
    if key ~= nil then
      meta[string.lower(key)] = Text.trim(value)
    end
  end
  return meta
end

local function parseTags(value)
  local tags = {}
  if value == nil or value == "" then
    return tags
  end
  local inner = string.match(value, "^%[(.*)%]$") or value
  for part in string.gmatch(inner, "[^,]+") do
    local tag = Text.trim(part)
    tag = string.gsub(tag, "^#", "")
    tag = Text.trim(string.gsub(tag, "^['\"]", ""))
    tag = Text.trim(string.gsub(tag, "['\"]$", ""))
    if tag ~= "" then
      tags[#tags + 1] = tag
    end
  end
  return tags
end

local function parseTodoLine(line, rel, title, lineNo)
  local _, mark, rest = string.match(line, TODO_PATTERN)
  if mark == nil then
    return nil
  end
  rest = Text.trim(rest)

  local tags = {}
  local seen = {}
  for tag in string.gmatch(rest, "#([%w%-_/]+)") do
    local lower = string.lower(tag)
    if not seen[lower] then
      seen[lower] = true
      tags[#tags + 1] = lower
    end
  end

  local due, todoTime = string.match(rest, "(%d%d%d%d%-%d%d%-%d%d)[T ]+(%d%d?:%d%d)")
  if due == nil then
    due = string.match(rest, "(%d%d%d%d%-%d%d%-%d%d)")
  end
  todoTime = Text.safeTime(todoTime)

  local recurrence = string.match(rest, "@(%a+)")
  if recurrence ~= "daily" and recurrence ~= "weekly" and recurrence ~= "monthly" then
    recurrence = nil
  end

  local priority = 0
  if string.find(rest, "!!", 1, true) ~= nil or string.find(rest, "#urgent", 1, true) ~= nil then
    priority = 2
  elseif string.find(rest, "!p1", 1, true) ~= nil or string.find(rest, "#important", 1, true) ~= nil then
    priority = 1
  end

  local text = rest
  text = string.gsub(text, "#[%w%-_/]+", "")
  local duePattern = due ~= nil and string.gsub(due, "%-", "%%-") or nil
  if duePattern ~= nil and todoTime ~= nil then
    text = string.gsub(text, duePattern .. "[T ]+" .. todoTime, "", 1)
  elseif duePattern ~= nil then
    text = string.gsub(text, duePattern, "", 1)
  end
  local hh, mm = string.match(text, "%s(%d%d?):(%d%d)%s*$")
  if hh ~= nil and string.find(rest, "%d%d%d%d%-%d%d%-%d%d") ~= nil then
    local hours, minutes = tonumber(hh), tonumber(mm)
    if hours ~= nil and minutes ~= nil and hours <= 23 and minutes <= 59 then
      text = string.gsub(text, "%s*" .. hh .. ":" .. mm .. "%s*$", "")
    end
  end
  text = string.gsub(text, "[Dd]ue:%s*", "")
  text = string.gsub(text, "\u{1F4C5}%s*", "")
  text = string.gsub(text, "@%a+", "")
  text = string.gsub(text, "!!", "")
  text = string.gsub(text, "!p1", "")
  text = string.gsub(text, "%*%*", "")
  text = Text.collapseSpaces(text)
  if text == "" then
    return nil
  end

  return {
    id = rel .. ":" .. tostring(lineNo),
    text = text,
    done = mark == "x" or mark == "X",
    due = due,
    time = todoTime,
    recurrence = recurrence,
    priority = priority,
    tags = tags,
    path = rel,
    line = lineNo,
    title = title,
    raw = line,
    storedDue = due,
  }
end
local function noteTitle(meta, body, fallback)
  if meta.title ~= nil and meta.title ~= "" then
    return string.gsub(meta.title, '^"(.*)"$', "%1")
  end
  local heading = string.match(body, "^%s*#+%s*([^\n]+)")
  if heading ~= nil and Text.trim(heading) ~= "" then
    return Text.stripMarkdown(heading)
  end
  return fallback
end

local function notePreview(body)
  local seen = 0
  for line in string.gmatch(body, "[^\n]+") do
    seen = seen + 1
    if seen > 40 then
      break
    end
    local trimmed = Text.trim(line)
    if trimmed ~= "" and string.sub(trimmed, 1, 1) ~= "#" and string.match(trimmed, TODO_PATTERN) == nil then
      local plain = Text.stripMarkdown(trimmed)
      if plain ~= "" then
        return Text.truncate(plain, 140)
      end
    end
  end
  return ""
end

local function buildHaystack(title, tags, body)
  return string.lower(title .. "\n" .. table.concat(tags, " ") .. "\n" .. string.sub(body, 1, 2000))
end

local function todoLess(a, b)
  if a.done ~= b.done then
    return not a.done
  end
  local aHas, bHas = a.due ~= nil, b.due ~= nil
  if aHas ~= bHas then
    return aHas
  end
  if aHas and a.due ~= b.due then
    return a.due < b.due
  end
  if aHas then
    local aTime = a.time or "99:99"
    local bTime = b.time or "99:99"
    if aTime ~= bTime then
      return aTime < bTime
    end
  end
  if a.priority ~= b.priority then
    return a.priority > b.priority
  end
  if a.path ~= b.path then
    return a.path < b.path
  end
  return a.line < b.line
end

-- Incremental scan -------------------------------------------------------
--
-- Noctalia gives each callback a small CPU budget (25 ms for update()), and a
-- todo-heavy line costs a noticeable fraction of a millisecond here. Parsing a
-- whole file in one callback can therefore blow the budget, which both drops
-- that file's todos and poisons the rest of the callback. So a scan is a small
-- state machine: beginScan() queues only the files whose mtime/size changed,
-- and scanStep() walks a bounded number of lines per call until the snapshot
-- is complete.

local scanState = nil

local function beginFile(file)
  local content = noctalia.readFile(file.abs) or ""
  if #content > MAX_PARSE_BYTES then
    content = string.sub(content, 1, MAX_PARSE_BYTES)
  end
  local front, body = splitFrontmatter(content)
  local meta = parseMeta(front)
  local title = noteTitle(meta, body, file.name)
  local tags = parseTags(meta.tags)
  local lineStart, lineNo = 1, 1
  if front ~= nil then
    lineStart = #front + 1
    lineNo = select(2, string.gsub(front, "\n", "")) + 1
  end
  return {
    file = file,
    body = body,
    title = title,
    tags = tags,
    content = content,
    lineStart = lineStart,
    lineNo = lineNo,
    todos = {},
    openCount = 0,
    doneCount = 0,
  }
end

local function finishFile(state)
  local file = state.file
  local tags = state.tags
  local seen = {}
  for _, tag in ipairs(tags) do
    seen[tag] = true
  end
  for tag in string.gmatch(state.body, "#([%w%-_/]+)") do
    local lower = string.lower(tag)
    if not seen[lower] then
      seen[lower] = true
      tags[#tags + 1] = lower
    end
  end
  local haystack = buildHaystack(state.title, tags, state.body)
  return {
    abs = file.abs,
    rel = file.rel,
    name = file.name,
    title = state.title,
    preview = notePreview(state.body),
    tags = tags,
    mtime = file.mtime,
    size = file.size,
    open_todos = state.openCount,
    done_todos = state.doneCount,
  }, state.todos, haystack
end

local function buildSnapshot(state)
  local notes, todos = state.notes, state.todos
  table.sort(notes, function(a, b)
    return (a.mtime or 0) > (b.mtime or 0)
  end)
  for _, todo in ipairs(todos) do
    todo.storedDue = todo.due
    if not todo.done and todo.recurrence ~= nil then
      todo.due = Text.rollRecurrence(todo.due, todo.recurrence, Text.todayIso())
      if todo.due ~= todo.storedDue then
        todo.rolled = true
      end
    end
  end
  table.sort(todos, todoLess)

  local today = Text.todayIso()
  local counts = { open = 0, done = 0, due_today = 0, overdue = 0, notes = #notes, tags = {} }
  for _, todo in ipairs(todos) do
    if todo.done then
      counts.done = counts.done + 1
    else
      counts.open = counts.open + 1
      if todo.due ~= nil then
        if todo.due == today then
          counts.due_today = counts.due_today + 1
        end
        if Text.isOverdue(todo.due, todo.time) then
          if todo.due == today then
            counts.due_today = counts.due_today - 1
          end
          counts.overdue = counts.overdue + 1
        end
      end
    end
    for _, tag in ipairs(todo.tags or {}) do
      counts.tags[tag] = (counts.tags[tag] or 0) + 1
    end
  end

  local tagList = {}
  for tag, count in pairs(counts.tags) do
    tagList[#tagList + 1] = { tag = tag, count = count }
  end
  table.sort(tagList, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return a.tag < b.tag
  end)

  return {
    dir = M.notesDir(),
    inbox = M.inboxPath(),
    scanned_at = noctalia.nowMs(),
    signature = state.signature,
    notes = notes,
    todos = todos,
    counts = counts,
    tags = tagList,
  }
end

local function remember(file, note, todos, haystack)
  parseCache[file.rel] = {
    mtime = file.mtime,
    size = file.size,
    note = note,
    todos = todos,
    haystack = haystack,
  }
end

function M.beginScan(signature, files)
  files = files or M.listFiles()
  local queue, notes, todos, index = {}, {}, {}, {}
  local present = {}
  for _, file in ipairs(files) do
    present[file.rel] = true
    local entry = parseCache[file.rel]
    if entry ~= nil and entry.mtime == file.mtime and entry.size == file.size then
      if entry.note ~= nil then
        notes[#notes + 1] = entry.note
        for _, todo in ipairs(entry.todos or {}) do
          todos[#todos + 1] = todo
        end
        index[file.rel] = entry.haystack
      end
    else
      queue[#queue + 1] = file
    end
  end
  for rel in pairs(parseCache) do
    if not present[rel] then
      parseCache[rel] = nil
    end
  end

  scanState = {
    signature = signature,
    queue = queue,
    index = 1,
    current = nil,
    notes = notes,
    todos = todos,
    index_map = index,
  }
  if #queue == 0 then
    return M.finishScan()
  end
  return nil
end

function M.finishScan()
  local state = scanState
  scanState = nil
  if state == nil then
    return nil
  end
  return buildSnapshot(state), state.index_map
end

function M.scanActive()
  return scanState ~= nil
end

-- Parses at most `maxLines` lines of the pending scan, or up to two files'
-- worth of setup, then returns. Returns the finished snapshot on the call that
-- completes the last queued file.
function M.scanStep(maxLines)
  local state = scanState
  if state == nil then
    return nil
  end
  local budget = maxLines or 20
  local used = 0
  local filesStarted = 0

  while used < budget and filesStarted < 2 do
    if state.current == nil then
      if state.index > #state.queue then
        return M.finishScan()
      end
      local file = state.queue[state.index]
      state.index = state.index + 1
      filesStarted = filesStarted + 1
      local ok, current = pcall(beginFile, file)
      if not ok then
        noctalia.log("notes: could not read " .. tostring(file.rel) .. ": " .. tostring(current))
      else
        state.current = current
      end
    else
      local current = state.current
      local content = current.content
      local last = #content
      local done = false
      local ok, err = pcall(function()
        while used < budget do
          if current.lineStart > last then
            done = true
            return
          end
          local nl = string.find(content, "\n", current.lineStart, true)
          local lineEnd = nl and (nl - 1) or last
          local todo = parseTodoLine(
            string.sub(content, current.lineStart, lineEnd),
            current.file.rel,
            current.title,
            current.lineNo
          )
          if todo ~= nil then
            current.todos[#current.todos + 1] = todo
            if todo.done then
              current.doneCount = current.doneCount + 1
            else
              current.openCount = current.openCount + 1
            end
          end
          used = used + 1
          if nl == nil then
            current.lineStart = last + 1
            done = true
            return
          end
          current.lineStart = nl + 1
          current.lineNo = current.lineNo + 1
        end
      end)

      if not ok then
        noctalia.log("notes: parse failed in " .. tostring(current.file.rel) .. ": " .. tostring(err))
        current.failures = (current.failures or 0) + 1
        if current.failures >= 3 then
          state.current = nil
        end
      elseif done then
        local fok, note, fileTodos, haystack = pcall(finishFile, current)
        if fok and note ~= nil then
          state.notes[#state.notes + 1] = note
          for _, todo in ipairs(fileTodos or {}) do
            state.todos[#state.todos + 1] = todo
          end
          state.index_map[current.file.rel] = haystack
          remember(current.file, note, fileTodos, haystack)
        else
          noctalia.log("notes: could not parse " .. tostring(current.file.rel) .. ": " .. tostring(note))
        end
        state.current = nil
      end
    end
  end
  return nil
end

function M.snapshotFiles()
  local files = M.listFiles()
  local parts = {}
  for _, file in ipairs(files) do
    parts[#parts + 1] = file.rel .. ":" .. tostring(file.mtime) .. ":" .. tostring(file.size)
  end
  table.sort(parts)
  return files, table.concat(parts, "|")
end

function M.signature()
  local _, signature = M.snapshotFiles()
  return signature
end

-- Mutation ---------------------------------------------------------------

function M.appendRaw(path, text)
  local abs = absFor(path)
  if abs == nil then
    return false, "unsafe path"
  end
  M.pushUndo(path)
  local content = noctalia.readFile(abs)
  if content == nil then
    content = ""
  end
  if content ~= "" and string.sub(content, -1) ~= "\n" then
    content = content .. "\n"
  end
  noctalia.writeFile(abs, content .. text)
end

function M.appendLine(path, line)
  M.appendRaw(path, line .. "\n")
end

function M.appendTodo(text, due, tags, priority, recurrence, targetPath, time)
  M.ensureDir()
  local line = "- [ ] " .. Text.collapseSpaces(text)
  local cleanDue = safeDue(due)
  local cleanTime = Text.safeTime(time)
  if cleanDue ~= nil then
    line = line .. " \u{1F4C5} " .. cleanDue
    if cleanTime ~= nil then
      line = line .. " " .. cleanTime
    end
  end
  priority = tonumber(priority) or 0
  if priority == 2 then
    line = line .. " #urgent"
  elseif priority == 1 then
    line = line .. " #important"
  end
  local cleanRecurrence = safeRecurrence(recurrence)
  if cleanRecurrence ~= nil then
    line = line .. " @" .. cleanRecurrence
  end
  if type(tags) == "table" then
    for _, tag in ipairs(tags) do
      local clean = safeTag(tag)
      if clean ~= nil then
        line = line .. " #" .. clean
      end
    end
  end
  M.appendLine(targetPath or M.inboxName(), line)
  return line
end

function M.appendBullet(text)
  M.ensureDir()
  M.appendLine(M.inboxPath(), "- " .. Text.collapseSpaces(text))
end

function M.setTodoDone(path, lineNo, done)
  local abs = absFor(path)
  if abs == nil then
    return false, "unsafe path"
  end
  local content = noctalia.readFile(abs)
  if content == nil then
    return false, "could not read " .. path
  end
  local lines = Text.splitLines(content)
  local target = lines[lineNo]
  if target == nil then
    return false, "line " .. tostring(lineNo) .. " not found"
  end
  local replaced, count = string.gsub(target, "^(%s*[%-%*] %[)[ xX](%])", "%1" .. (done and "x" or " ") .. "%2", 1)
  if count == 0 then
    return false, "not a todo line"
  end
  M.pushUndo(path)
  lines[lineNo] = replaced
  noctalia.writeFile(abs, Text.joinLines(lines))
  return true
end

function M.setTodoDue(path, lineNo, due, time)
  local abs = absFor(path)
  if abs == nil then
    return false, "unsafe path"
  end
  local content = noctalia.readFile(abs)
  if content == nil then
    return false, "could not read " .. path
  end
  local lines = Text.splitLines(content)
  local target = lines[lineNo]
  if target == nil then
    return false, "line not found"
  end
  local indent, mark, rest = string.match(target, TODO_PATTERN)
  if mark == nil then
    return false, "not a todo line"
  end
  local text = rest
  text = string.gsub(text, "\u{1F4C5}%s*%d%d%d%d%-%d%d%-%d%d[T ]+%d%d?:%d%d", "")
  text = string.gsub(text, "\u{1F4C5}%s*%d%d%d%d%-%d%d%-%d%d", "")
  text = string.gsub(text, "[Dd]ue:%s*%d%d%d%d%-%d%d%-%d%d[T ]+%d%d?:%d%d", "")
  text = string.gsub(text, "[Dd]ue:%s*%d%d%d%d%-%d%d%-%d%d", "")
  text = string.gsub(text, "@%d%d%d%d%-%d%d%-%d%d", "")
  local hh, mm = string.match(text, "%s(%d%d?):(%d%d)%s*$")
  if hh ~= nil and string.find(target, "%d%d%d%d%-%d%d%-%d%d") ~= nil then
    local hours, minutes = tonumber(hh), tonumber(mm)
    if hours ~= nil and minutes ~= nil and hours <= 23 and minutes <= 59 then
      text = string.gsub(text, "%s*" .. hh .. ":" .. mm .. "%s*$", "")
    end
  end
  text = Text.collapseSpaces(text)
  local rebuilt = indent .. "- [" .. mark .. "] " .. text
  local cleanDue = safeDue(due)
  local cleanTime = Text.safeTime(time)
  if cleanDue ~= nil then
    rebuilt = rebuilt .. " \u{1F4C5} " .. cleanDue
    if cleanTime ~= nil then
      rebuilt = rebuilt .. " " .. cleanTime
    end
  end
  M.pushUndo(path)
  lines[lineNo] = rebuilt
  noctalia.writeFile(abs, Text.joinLines(lines))
  return true
end

function M.deleteLine(path, lineNo)
  local abs = absFor(path)
  if abs == nil then
    return false, "unsafe path"
  end
  local content = noctalia.readFile(abs)
  if content == nil then
    return false, "could not read " .. path
  end
  local lines = Text.splitLines(content)
  if lines[lineNo] == nil then
    return false, "line not found"
  end
  M.pushUndo(path)
  table.remove(lines, lineNo)
  noctalia.writeFile(abs, Text.joinLines(lines))
  return true
end

function M.archiveCompleted()
  local files = M.listFiles()
  local changes = {}
  local sections = {}
  local removed = 0
  for _, file in ipairs(files) do
    local content = noctalia.readFile(file.abs)
    if content ~= nil then
      local lines = Text.splitLines(content)
      local kept, moved = {}, {}
      for _, line in ipairs(lines) do
        local _, mark = string.match(line, TODO_PATTERN)
        if mark == "x" or mark == "X" then
          moved[#moved + 1] = line
        else
          kept[#kept + 1] = line
        end
      end
      if #moved > 0 then
        changes[#changes + 1] = { rel = file.rel, abs = file.abs, content = Text.joinLines(kept) }
        sections[#sections + 1] = "## " .. file.rel .. "\n\n" .. table.concat(moved, "\n")
        removed = removed + #moved
      end
    end
  end

  if removed == 0 then
    return 0
  end

  local archiveRel = M.archiveName()
  local archiveAbs = M.safeAbs(archiveRel)
  if archiveAbs == nil then
    return 0
  end
  local archiveContent = noctalia.readFile(archiveAbs) or ""
  if archiveContent ~= "" and string.sub(archiveContent, -1) ~= "\n" then
    archiveContent = archiveContent .. "\n"
  end
  archiveContent = archiveContent
    .. "\n\n# Archived "
    .. Text.todayIso()
    .. "\n\n"
    .. table.concat(sections, "\n\n")
    .. "\n"
  changes[#changes + 1] = { rel = archiveRel, abs = archiveAbs, content = archiveContent }

  local paths = {}
  for _, change in ipairs(changes) do
    paths[#paths + 1] = change.rel
  end
  M.pushUndoGroup("archive completed", paths)
  for _, change in ipairs(changes) do
    noctalia.writeFile(change.abs, change.content)
  end
  return removed
end

-- Refuses to materialise a note larger than the scan cap: the incremental
-- scanner already truncates, so opening one must not be the way around it.
function M.readParts(abs)
  local info = noctalia.fileInfo(abs)
  if info ~= nil and (info.size or 0) > MAX_PARSE_BYTES then
    return nil, "note is too large to open (" .. tostring(math.floor((info.size or 0) / 1024)) .. " KB)"
  end
  local raw = noctalia.readFile(abs)
  if raw == nil then
    return nil, "could not read " .. tostring(abs)
  end
  local front, body = splitFrontmatter(raw)
  return { raw = raw, frontmatter = front, body = body }
end

function M.readNote(rel)
  local abs = absFor(rel)
  if abs == nil then
    return nil, "unsafe path"
  end
  local parts, reason = M.readParts(abs)
  if parts == nil then
    return nil, reason
  end
  return parts
end

function M.writeBody(rel, body)
  local abs = absFor(rel)
  if abs == nil then
    return false, "unsafe path"
  end
  local parts = M.readParts(abs)
  local out
  if parts ~= nil and parts.frontmatter ~= nil then
    out = parts.frontmatter .. body
  else
    out = body
  end
  if out ~= "" and string.sub(out, -1) ~= "\n" then
    out = out .. "\n"
  end
  M.pushUndo(rel)
  return noctalia.writeFile(abs, out)
end

function M.uniquePath(slug)
  local dir = M.notesDir()
  for i = 1, 200 do
    local name = i == 1 and (slug .. ".md") or (slug .. "-" .. tostring(i) .. ".md")
    local abs = dir .. "/" .. name
    if not noctalia.fileExists(abs) then
      return abs
    end
  end
  return dir .. "/" .. tostring(math.floor(noctalia.nowMs())) .. ".md"
end

function M.createNoteAt(rel, title, body, overwrite)
  local abs = M.safeAbs(rel)
  if abs == nil then
    return nil
  end
  M.ensureDir()
  if not overwrite and noctalia.fileExists(abs) then
    return nil
  end
  title = Text.collapseSpaces(title)
  if title == "" then
    title = "Untitled"
  end
  body = body or ""
  local content = "---\n"
    .. "title: " .. Text.yamlString(title) .. "\n"
    .. "created: " .. os.date("%Y-%m-%dT%H:%M:%S") .. "\n"
    .. "---\n"
  if string.sub(body, 1, 1) == "#" then
    content = content .. "\n" .. body
  else
    content = content .. "\n# " .. title .. "\n"
    if Text.trim(body) ~= "" then
      content = content .. "\n" .. body
    end
  end
  if string.sub(content, -1) ~= "\n" then
    content = content .. "\n"
  end
  local parent = string.match(abs, "^(.*)/[^/]+$")
  if parent ~= nil then
    noctalia.mkdirAll(parent)
  end
  noctalia.writeFile(abs, content)
  return abs
end

function M.createNote(title, body)
  M.ensureDir()
  title = Text.collapseSpaces(title)
  if title == "" then
    title = "Untitled"
  end
  local slug = Text.slugify(title)
  if slug == "" then
    slug = "note-" .. tostring(math.floor(noctalia.nowMs() / 1000))
  end
  local abs = M.uniquePath(slug)
  return M.createNoteAt(M.relative(abs), title, body)
end

function M.dailyNote(dateIso)
  dateIso = dateIso or Text.todayIso()
  local dirName = safeName(config("daily_dir", "Daily"), "Daily")
  local rel = dirName .. "/" .. dateIso .. ".md"
  local abs = M.safeAbs(rel)
  if abs == nil then
    return nil, nil
  end
  noctalia.mkdirAll(M.notesDir() .. "/" .. dirName)
  if not noctalia.fileExists(abs) then
    local content = "---\n"
      .. "title: " .. dateIso .. "\n"
      .. "date: " .. dateIso .. "\n"
      .. "tags: [daily]\n"
      .. "---\n\n"
      .. "# " .. dateIso .. "\n\n"
      .. "## Tasks\n\n"
      .. "## Notes\n\n"
    noctalia.writeFile(abs, content)
  end
  return abs, M.relative(abs)
end

function M.deleteNote(rel)
  local abs = absFor(rel)
  if abs == nil then
    return false, "unsafe path"
  end
  M.pushUndo(rel, rel)
  return noctalia.removeFile(abs)
end

function M.relative(abs)
  local dir = M.notesDir()
  if string.sub(abs, 1, #dir + 1) == dir .. "/" then
    return string.sub(abs, #dir + 2)
  end
  return abs
end

-- Queries ----------------------------------------------------------------

function M.findNote(snapshot, rel)
  if snapshot == nil then
    return nil
  end
  for _, note in ipairs(snapshot.notes) do
    if note.rel == rel then
      return note
    end
  end
  return nil
end

function M.resolveLink(snapshot, target)
  if snapshot == nil then
    return nil
  end
  local lower = string.lower(Text.trim(target))
  if lower == "" then
    return nil
  end
  for _, note in ipairs(snapshot.notes) do
    if string.lower(note.title) == lower or string.lower(note.name) == lower or string.lower(note.rel) == lower then
      return note
    end
  end
  for _, note in ipairs(snapshot.notes) do
    if string.find(string.lower(note.title), lower, 1, true) ~= nil then
      return note
    end
  end
  return nil
end

local function haystackOf(index, note)
  if index ~= nil then
    local haystack = index[note.rel]
    if haystack ~= nil then
      return haystack
    end
  end
  return string.lower(note.title .. "\n" .. note.preview)
end

function M.search(snapshot, index, query, limit)
  limit = limit or 40
  local notes, todos = {}, {}
  if snapshot == nil then
    return notes, todos
  end
  local q = Text.trim(query)
  if q == "" then
    for _, note in ipairs(snapshot.notes) do
      notes[#notes + 1] = note
      if #notes >= limit then
        break
      end
    end
    return notes, todos
  end

  local scored = {}
  for _, note in ipairs(snapshot.notes) do
    local score = noctalia.fuzzyScore(q, note.title)
    if score ~= nil then
      score = score + 100
    else
      score = noctalia.fuzzyScore(q, haystackOf(index, note))
    end
    if score ~= nil then
      scored[#scored + 1] = { score = score, note = note }
    end
  end
  table.sort(scored, function(a, b)
    return a.score > b.score
  end)
  for _, entry in ipairs(scored) do
    notes[#notes + 1] = entry.note
    if #notes >= limit then
      break
    end
  end

  for _, todo in ipairs(snapshot.todos) do
    if not todo.done then
      local score = noctalia.fuzzyScore(q, todo.text)
      if score ~= nil then
        todos[#todos + 1] = todo
      end
    end
    if #todos >= limit then
      break
    end
  end
  return notes, todos
end

function M.relevantNotes(query, snapshot, index, limit)
  limit = limit or 4
  if snapshot == nil then
    return {}
  end
  local words = Text.keywords(query)
  if #words == 0 then
    local out = {}
    for i = 1, math.min(limit, #snapshot.notes) do
      out[#out + 1] = snapshot.notes[i]
    end
    return out
  end

  local scored = {}
  for _, note in ipairs(snapshot.notes) do
    local haystack = haystackOf(index, note)
    local score = 0
    for _, word in ipairs(words) do
      if string.find(haystack, word, 1, true) ~= nil then
        score = score + 1
        if string.find(string.lower(note.title), word, 1, true) ~= nil then
          score = score + 2
        end
      end
    end
    if score > 0 then
      scored[#scored + 1] = { score = score, note = note }
    end
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return (a.note.mtime or 0) > (b.note.mtime or 0)
  end)
  local out = {}
  for i = 1, math.min(limit, #scored) do
    out[#out + 1] = scored[i].note
  end
  return out
end

return M