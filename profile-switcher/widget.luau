--!nonstrict

local activeProfile =
    noctalia.state.get("activeProfile")

local activeProfileName =
    noctalia.state.get("activeProfileName")


local function render()
    local text =
        activeProfileName
        or activeProfile
        or noctalia.tr("common.profiles")

    barWidget.setGlyph("palette")
    barWidget.setText(text)
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
