local config = {
    label = noctalia.getConfig("label"),
    icon = noctalia.getConfig("icon"),
    cmd = noctalia.getConfig("onclick_cmd"),
}

local function render()
    shortcut.setLabel(config.label)
    shortcut.setIcon(config.icon)
end

render()

function onClick()
    noctalia.runAsync(config.cmd)
end
