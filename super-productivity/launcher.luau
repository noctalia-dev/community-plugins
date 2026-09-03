--!nonstrict

local common = require("./common.luau")

local current_query = ""
local pending_capture = nil

local function set_results(query)
  local text = common.trim(query)
  current_query = text
  local results = {}

  if text == "" then
    table.insert(results, {
      id = "hint",
      title = noctalia.tr("launcher.capture_title"),
      subtitle = noctalia.tr("launcher.capture_hint"),
      glyph = "plus",
    })
    table.insert(results, {
      id = "open",
      title = noctalia.tr("launcher.open_app"),
      subtitle = noctalia.tr("launcher.open_app_hint"),
      glyph = "external-link",
    })
  else
    table.insert(results, {
      id = "add",
      title = noctalia.tr("launcher.add", { task = common.truncate(text, 90) }),
      subtitle = noctalia.tr("launcher.add_hint"),
      glyph = "plus",
      badge = "Super Productivity",
    })
  end

  launcher.setResults(query, results)
end

function onQuery(text)
  set_results(text or "")
end

function onActivate(id)
  if id == "add" and current_query ~= "" and pending_capture == nil then
    local request_id = common.send_intent("add", { input = current_query, source = "launcher" })
    pending_capture = { requestId = request_id, input = current_query }
  elseif id == "open" then
    common.send_intent("launch")
  elseif id == "hint" then
    launcher.setQuery("")
  end
end

noctalia.state.watch(common.ACTION_KEY, function(next_action)
  if type(pending_capture) ~= "table" or type(next_action) ~= "table" then return end
  if next_action.requestId ~= pending_capture.requestId or not common.terminal_action(next_action) then return end
  if next_action.status == "success" and current_query == pending_capture.input then
    launcher.setQuery("")
  end
  pending_capture = nil
end)

set_results("")
