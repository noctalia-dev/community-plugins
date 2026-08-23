label = noctalia.getConfig("label")
icon = noctalia.getConfig("icon")
cmd = noctalia.getConfig("onclick_cmd")

local function render()
    shortcut.setLabel(label)
    shortcut.setIcon(icon)
end

render()

function onClick()
    noctalia.runAsync(cmd)
end
