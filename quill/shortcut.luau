--!nonstrict
local PANEL_ID = "fel/quill:panel"

local snapshot = noctalia.state.get("snapshot")

local function render()
  local counts = snapshot ~= nil and snapshot.counts or nil
  if counts == nil then
    shortcut.setIcon("notes")
    shortcut.setLabel("Quill")
    shortcut.setActive(false)
    return
  end

  shortcut.setIcon("notes")
  if counts.open > 0 then
    shortcut.setLabel("Quill · " .. tostring(counts.open))
  else
    shortcut.setLabel("Quill")
  end
  shortcut.setActive(counts.overdue > 0 or counts.due_today > 0)
end

noctalia.state.watch("snapshot", function(value)
  snapshot = value
  render()
end)

function update()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

render()
