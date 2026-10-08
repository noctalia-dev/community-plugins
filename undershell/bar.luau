--!nonstrict
-- undershell bar widget: left click opens the panel, right click toggles the
-- desktop editor.

local function binary()
  local local_bin = noctalia.expandPath("~/.local/bin/undershell")
  if noctalia.fileExists ~= nil and noctalia.fileExists(local_bin) then
    return local_bin
  end
  if noctalia.commandExists("undershell") then
    return "undershell"
  end
  return local_bin
end

local function render()
  barWidget.setGlyph("layout-dashboard")
  barWidget.setTooltip(noctalia.tr("bar.tooltip"))
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("eternalself-2328/undershell:panel")
end

function onRightClick()
  noctalia.runAsync({ binary(), "msg", "edit" })
end

render()
