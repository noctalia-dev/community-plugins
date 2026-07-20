local showText = noctalia.getConfig("show_text")
local notifyChange = noctalia.getConfig("notify_change")
local hideOnDefault = noctalia.getConfig("hide_on_default")

local currentKeymode = "default"

noctalia.runStream("mmsg watch keymode", function(line)
  local data = noctalia.json.decode(line)
  if data and data.keymode then
    if currentKeymode ~= data.keymode then
      currentKeymode = data.keymode
      if notifyChange then
        noctalia.notify("Keymode changed", currentKeymode)
      end
    end
  end
end)

function update()
  noctalia.setUpdateInterval(1000)
  if hideOnDefault and currentKeymode == "default" then
    barWidget.setVisible(false)
  else
    barWidget.setVisible(true)
    barWidget.setGlyph("keyboard")
    if showText then
      barWidget.setText(currentKeymode)
    else
      barWidget.setText("")
    end
  end
end

function onClick()
  noctalia.notify("Keymode", currentKeymode)
end
