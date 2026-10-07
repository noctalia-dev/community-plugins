--!nonstrict
-- Control center shortcut tile that opens the Theme Switcher carousel. Also
-- triggerable via IPC so it can be bound to a key:
--   noctalia msg plugin theblackdon/theme-switcher:open all open

local themes = require("./themes.luau")

local function render()
	local current = themes.byId(themes.lastAppliedId())
	shortcut.setLabel((current and current.title) or noctalia.tr("shortcut.label"))
	shortcut.setIcon("palette")
end

local function openPanel()
	noctalia.togglePanel("theblackdon/theme-switcher:carousel")
end

render()
noctalia.state.watch("lastAppliedId", render)
noctalia.state.watch("themes", render)

function onClick()
	openPanel()
end

function onIpc()
	openPanel()
end
