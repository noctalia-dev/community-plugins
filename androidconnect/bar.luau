--!nonstrict
local function render()
  local status = noctalia.state.get("status") or {}
  local preferences = noctalia.state.get("preferences") or {}
  local connected = status.serial and status.serial ~= ""
  local battery = nil
  local name = noctalia.tr("title")
  local names = status.names or {}
  for _, device in status.adb or {} do
    if device.serial == status.serial then name = names["adb:" .. device.serial] or device.name end
  end
  for _, device in status.kde or {} do
    if device.id == status.selectedKde then
      name = names["kde:" .. device.id] or device.name
      if device.reachable and device.paired then
        connected = true
        if device.battery and device.battery >= 0 then battery = device.battery end
      end
    end
  end
  barWidget.setVisible(not preferences.hide or connected == true)
  barWidget.setGlyph(if connected then "device-mobile" else "device-mobile-off")
  barWidget.setGlyphColor(preferences.color or "primary")
  barWidget.setText(if battery and not barWidget.isVertical() then `{battery}%` else "")
  barWidget.setTooltip(name .. "\n" .. noctalia.tr(if connected then "status.connected" else "status.disconnected"))
end

noctalia.state.watch("status", render)
noctalia.state.watch("preferences", render)
function update() render() end
function onClick() noctalia.togglePanel("demencia89/androidconnect:panel") end
function onRightClick() noctalia.openSettings() end
render()
