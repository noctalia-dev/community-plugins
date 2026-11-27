--!nonstrict
-- Control-centre shortcut: hides or restores the lyric overlay without touching
-- the plugin's saved settings.

local function hidden()
  return noctalia.state.get("lyrics_hidden") == true
end

local function sync(active)
  shortcut.setActive(active)
end

shortcut.setLabel(noctalia.tr("shortcut.label"))
shortcut.setIcon("music", "eye-off")
sync(not hidden())

function onClick()
  noctalia.state.set("lyrics_hidden", not hidden())
  sync(not hidden())
end

function onRightClick()
  noctalia.togglePanel("alitura/desktop-lyrics:controls")
end
