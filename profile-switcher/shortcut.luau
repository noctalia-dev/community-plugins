--!nonstrict

local activeProfile =
    noctalia.state.get("activeProfile")

local activeProfileName =
    noctalia.state.get("activeProfileName")


local function render()
    local label =
        activeProfileName
        or activeProfile
        or noctalia.tr("common.profiles")

    shortcut.setIcon("palette")
    shortcut.setLabel(label)
    shortcut.setActive(activeProfile ~= nil)
    shortcut.setEnabled(true)
end


function onClick()
    noctalia.togglePanel(
        "m4sc/profile-switcher:panel"
    )
end


function onRightClick()
    noctalia.togglePanel(
        "m4sc/profile-switcher:editor"
    )
end


noctalia.state.watch(
    "activeProfile",
    function(value)
        activeProfile = value
        render()
    end
)


noctalia.state.watch(
    "activeProfileName",
    function(value)
        activeProfileName = value
        render()
    end
)


render()
