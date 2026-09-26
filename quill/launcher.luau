--!nonstrict
local Store = require("./lib/store.luau")
local Text = require("./lib/text.luau")

local PANEL_ID = "fel/quill:panel"

local snapshot = noctalia.state.get("snapshot")

noctalia.state.watch("snapshot", function(value)
  snapshot = value
end)

local function result(id, title, subtitle, glyph, score)
  return { id = id, title = title, subtitle = subtitle, glyph = glyph, score = score }
end

local function openPanelAction(action)
  noctalia.state.set("pending_action", action)
  noctalia.togglePanel(PANEL_ID)
end

function onQuery(text)
  local query = Text.trim(text)
  if query == "" then
    local results = {
      result("panel", "Open Quill", "browse todos, notes and AI", "notes", 100),
    }
    if snapshot ~= nil then
      local shown = 0
      for _, todo in ipairs(snapshot.todos) do
        if not todo.done then
          results[#results + 1] = result(
            "toggle:" .. todo.path .. ":" .. tostring(todo.line),
            todo.text,
            "complete · " .. todo.path .. (todo.due ~= nil and (" · " .. todo.due .. (todo.time ~= nil and (" " .. todo.time) or "")) or ""),
            "check",
            50
          )
          shown = shown + 1
          if shown >= 8 then
            break
          end
        end
      end
    end
    launcher.setResults(text, results)
    return
  end

  local lower = string.lower(query)
  if string.sub(query, 1, 2) == "+ " or string.sub(lower, 1, 5) == "todo " then
    local body = string.sub(query, 3)
    if string.sub(lower, 1, 5) == "todo " then
      body = string.sub(query, 6)
    end
    launcher.setResults(text, {
      result("todo:" .. body, "Add todo: " .. Text.truncate(body, 60), "Inbox", "square-plus", 100),
    })
    return
  end
  if string.sub(query, 1, 2) == "# " or string.sub(lower, 1, 5) == "note " then
    local body = string.sub(query, 3)
    if string.sub(lower, 1, 5) == "note " then
      body = string.sub(query, 6)
    end
    launcher.setResults(text, {
      result("note:" .. body, "New note: " .. Text.truncate(body, 60), "Markdown file", "note", 100),
    })
    return
  end
  if string.sub(query, 1, 2) == "? " then
    local body = string.sub(query, 3)
    launcher.setResults(text, {
      result("ask:" .. body, "Ask AI: " .. Text.truncate(body, 60), "over your notes", "sparkles", 100),
    })
    return
  end

  local results = {}
  local notes, todos = Store.search(snapshot, nil, query, 12)
  for _, todo in ipairs(todos) do
    results[#results + 1] = result(
      "toggle:" .. todo.path .. ":" .. tostring(todo.line),
      todo.text,
      "complete · " .. todo.path,
      "check",
      80
    )
  end
  for _, note in ipairs(notes) do
    results[#results + 1] = result(
      "open:" .. note.rel,
      note.title,
      note.rel .. (note.preview ~= "" and (" · " .. note.preview) or ""),
      "file-text",
      60
    )
  end
  results[#results + 1] = result("todo:" .. query, "Add todo: " .. Text.truncate(query, 60), "Inbox", "square-plus", 20)
  results[#results + 1] = result("note:" .. query, "New note: " .. Text.truncate(query, 60), "Markdown file", "note", 15)
  results[#results + 1] = result("ask:" .. query, "Ask AI: " .. Text.truncate(query, 60), "over your notes", "sparkles", 10)

  launcher.setResults(text, results)
end

function onActivate(id)
  local action, payload = string.match(id, "^(%a+):(.*)$")
  if action == nil then
    return
  end

  if action == "panel" then
    noctalia.togglePanel(PANEL_ID)
    return
  end

  if action == "todo" then
    Store.appendTodo(payload)
    noctalia.state.set("refresh_request", noctalia.nowMs())
    noctalia.notify("Quill", "Added todo: " .. Text.truncate(payload, 60))
    return
  end

  if action == "note" then
    Store.createNote(payload)
    noctalia.state.set("refresh_request", noctalia.nowMs())
    noctalia.notify("Quill", "Created note: " .. Text.truncate(payload, 60))
    return
  end

  if action == "ask" then
    openPanelAction({ kind = "ask", text = payload })
    return
  end

  if action == "open" then
    openPanelAction({ kind = "open_note", path = payload })
    return
  end

  if action == "toggle" then
    local path, line = string.match(payload, "^(.*):(%d+)$")
    if path ~= nil then
      Store.setTodoDone(path, tonumber(line), true)
      noctalia.state.set("refresh_request", noctalia.nowMs())
    end
    return
  end
end