-- Launcher provider behind the `/zakker` prefix: search reminders,
-- select one to copy it and show it as a notification.

local reminders = require("./lib/reminders.luau")

local function all()
  return reminders.collect(true, true)
end

function onQuery(text)
  local items = all()
  local results = {}
  for i, item in ipairs(items) do
    local match = text == ""
    if not match then
      match = noctalia.fuzzyScore(text, item.text) ~= nil
        or noctalia.fuzzyScore(text, item.hint) ~= nil
    end
    if match then
      table.insert(results, {
        id = tostring(i),
        title = item.text,
        subtitle = item.hint,
        glyph = "moon",
      })
    end
    if #results >= 20 then
      break
    end
  end
  if #results == 0 then
    results = { { id = "none", title = "No reminder matches", glyph = "moon" } }
  end
  launcher.setResults(text, results)
end

function onActivate(id)
  local items = all()
  local idx = tonumber(id)
  if idx == nil or items[idx] == nil then
    return
  end
  local item = items[idx]
  noctalia.copyToClipboard(item.text, "text/plain")
  noctalia.state.set("zakker/latest", item.text)
  noctalia.notify(item.title, item.text)
end
