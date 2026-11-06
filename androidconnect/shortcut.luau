--!nonstrict
local function render()
  local status = noctalia.state.get("status") or {}
  local active = status.serial and status.serial ~= ""
  for _, device in status.kde or {} do
    active = active or (device.id == status.selectedKde and device.paired and device.reachable)
  end
  shortcut.setLabel(noctalia.tr("title"))
  shortcut.setIcon("device-mobile", "device-mobile-off")
  shortcut.setActive(active == true)
  shortcut.setEnabled(true)
end

noctalia.state.watch("status", render)
function onClick() noctalia.togglePanel("demencia89/androidconnect:panel") end
render()
