--!nonstrict
local Store = require("./store.luau")
local AI = require("./ai.luau")
local Text = require("./text.luau")

local M = {}

local PROJECT_CONTEXT_LIMIT = 40

local function finish(cb, status)
  Store.markDirty()
  if cb ~= nil then
    cb(status)
  end
end

-- Appends a todo, pulling a due date/time out of the text itself when AI
-- structuring is unavailable. The words stay in the task text so nothing is
-- silently lost.
function M.appendWithHint(text)
  local due, time = Text.parseDueHint(text)
  local target
  if due == nil and time ~= nil then
    due = Text.todayIso()
  end
  Store.appendTodo(text, due, nil, 0, nil, target, time)
  return due, time
end

-- Builds the list of existing project files the AI chooses from, straight
-- from the published snapshot ("- Work.md — Work"). Archive is excluded, and
-- the list is capped so a large notes folder does not bloat every capture.
function M.projectContext()
  local snapshot = noctalia.state.get("snapshot")
  local notes = type(snapshot) == "table" and type(snapshot.notes) == "table" and snapshot.notes or {}
  local archive = string.lower(Store.archiveName())
  local lines = {}
  for _, note in ipairs(notes) do
    local rel = tostring(note.rel or "")
    local title = tostring(note.title or "")
    if rel ~= "" and string.lower(rel) ~= archive then
      lines[#lines + 1] = "- " .. rel .. (title ~= "" and (" — " .. title) or "")
      if #lines >= PROJECT_CONTEXT_LIMIT then
        break
      end
    end
  end
  if #lines == 0 then
    return ""
  end
  return "Existing projects:\n" .. table.concat(lines, "\n")
end

local function slugProjectPath(clean)
  local stem = string.match(clean, "^(.-)%.md$") or clean
  local segments = {}
  for segment in string.gmatch(stem, "[^/]+") do
    local slug = Text.slugify(segment)
    if slug == "" then
      return nil
    end
    segments[#segments + 1] = slug
  end
  if #segments == 0 then
    return nil
  end
  return table.concat(segments, "/") .. ".md"
end

local function projectTitle(clean)  local stem = string.match(clean, "^(.-)%.md$") or clean
  local last = string.match(stem, "([^/]+)$") or stem
  last = string.gsub(last, "[-_]", " ")
  return Text.trim(last)
end

-- Turns the AI's "file" answer into a target note path. Returns the path,
-- a display label, and whether the project file was just created. Empty or
-- unsafe answers fall back to the Inbox (nil target).
local function resolveProject(data)
  local raw = tostring(data.file or "")
  if Text.trim(raw) == "" then
    return nil, nil, false
  end
  local clean = Store.safeProjectPath(raw)
  if clean == nil then
    return nil, nil, false
  end
  local want = string.lower(clean)
  local stem = string.lower(string.match(clean, "^(.-)%.md$") or clean)
  local files = Store.listFiles()
  for _, file in ipairs(files) do
    if string.lower(file.rel) == want or string.lower(file.name) == stem then
      return file.rel, file.name, false
    end
  end
  local slug = slugProjectPath(clean)
  if slug == nil then
    return nil, nil, false
  end
  local title = projectTitle(clean)
  if noctalia.fileExists(M.notesDir() .. "/" .. slug) then
    return slug, title, false
  end
  local abs = Store.createNoteAt(slug, title)
  if abs == nil then
    return nil, nil, false
  end
  return Store.relative(abs), title, true
end

function M.capture(text, useAI, cb, projects)
  text = Text.trim(text)
  if text == "" then
    if cb ~= nil then
      cb("Nothing to capture")
    end
    return
  end

  local aiOk = AI.available()
  if not useAI or not aiOk then
    M.appendWithHint(text)
    finish(cb, "Added todo: " .. Text.truncate(text, 50))
    return
  end

  AI.parseCapture(text, projects or "", function(data, err)
    if data == nil then
      M.appendWithHint(text)
      finish(cb, "AI failed (" .. tostring(err) .. ") · added as a todo")
      return
    end

    if tostring(data.kind or "todo") == "note" then
      local title = tostring(data.text or text)
      Store.createNote(title, tostring(data.body or ""))
      finish(cb, "Saved note: " .. Text.truncate(title, 50))
      return
    end

    local due = tostring(data.due or "")
    if due == "" then
      due = nil
    end
    local time = Text.safeTime(data.time)
    local tags = type(data.tags) == "table" and data.tags or nil
    local priority = tonumber(data.priority) or 0
    local target, label, isNew = resolveProject(data)
    Store.appendTodo(tostring(data.text or text), due, tags, priority, nil, target, time)
    local statusText
    if target ~= nil and label ~= nil then
      statusText = "Added todo to " .. label .. (isNew and " (new project)" or "")
    else
      statusText = "Added todo: " .. Text.truncate(tostring(data.text or text), 50)
    end
    finish(cb, statusText)
  end)
end

return M
