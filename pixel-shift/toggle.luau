--!nonstrict
-- Control-center tile: pause or resume shifting. Right click opens the lab.

local paused = noctalia.state.get("paused") == true
local seqN = 0

local function render()
	shortcut.setLabel(noctalia.tr(if paused then "toggle.off" else "toggle.on"))
	shortcut.setIcon("arrows-move-horizontal", "player-pause")
	shortcut.setActive(not paused)
	shortcut.setEnabled(true)
end

noctalia.state.watch("paused", function(v)
	paused = v == true
	render()
end)

function onClick()
	seqN += 1
	noctalia.state.set("lab:cmd", { seq = `toggle-{noctalia.nowMs()}-{seqN}`, cmd = "toggle" })
end

function onRightClick()
	noctalia.togglePanel("mgeldi/pixel-shift:lab")
end

render()
