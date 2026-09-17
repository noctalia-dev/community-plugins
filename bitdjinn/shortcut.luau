--!nonstrict
-- BitDjinn Control Center Shortcut — Quick toggle for blockchain transaction alerts.

local notifyEnabled = true

local function render()
  local summary = noctalia.state.get("bitdjinn.summary")
  if type(summary) == "table" and summary.notifyEnabled ~= nil then
    notifyEnabled = summary.notifyEnabled
  end

  shortcut.setLabel(if notifyEnabled then noctalia.tr("shortcut.label_on") else noctalia.tr("shortcut.label_off"))
  shortcut.setIcon("currency-bitcoin")
  shortcut.setActive(notifyEnabled)
  shortcut.setEnabled(true)
end

function onClick()
  noctalia.state.set("bitdjinn.cmd", { op = "toggle_notify" })
  notifyEnabled = not notifyEnabled
  render()
end

noctalia.state.watch("bitdjinn.summary", function()
  render()
end)

render()
