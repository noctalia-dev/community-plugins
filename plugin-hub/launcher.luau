--!nonstrict
-- Plugin Hub launcher provider: type /hub in Noctalia's launcher to search every action of
-- the hub, Noctalia's panels, your plugins' panels and commands and your own, and press Enter
-- to run one. The first result opens the hub. Reads "hub.model" and sends actions on
-- "hub.command".

local PANEL = "omerfuyar/plugin-hub:panel"
local MAX_RESULTS = 40

local function send(command)
  command.n = noctalia.nowMs()
  noctalia.state.set("hub.command", command)
end

function onQuery(text)
  local query = noctalia.string.trim(text):lower()
  local model = noctalia.state.get("hub.model")
  local results = {}
  if query == "" then
    table.insert(results, { id = "open", title = noctalia.tr("launcher.open"), glyph = "apps", score = 1000 })
  end
  for _, group in ipairs(model and model.groups or {}) do
    if group.enabled ~= false then
      for _, action in ipairs(group.actions) do
        local haystack = (group.title .. " " .. action.title .. " " .. action.command):lower()
        if query == "" or haystack:find(query, 1, true) then
          local key = model.keys[action.command]
          table.insert(results, {
            id = "run " .. action.command,
            title = action.title,
            subtitle = group.title,
            badge = key,
            glyph = action.kind == "panel" and "layout-sidebar" or "terminal-2",
          })
          if #results >= MAX_RESULTS then
            launcher.setResults(text, results)
            return
          end
        end
      end
    end
  end
  launcher.setResults(text, results)
end

function onActivate(id)
  if id == "open" then
    noctalia.togglePanel(PANEL)
    return
  end
  local command = id:match("^run (.+)$")
  if command then
    send({ action = "run", command = command })
  end
end
