--!nonstrict
-- W-Engine panel — picks a Wallpaper Engine workshop item and applies it via
-- linux-wallpaperengine.
--
-- Same pattern as the official mpvpaper plugin: onClick only ever receives a
-- global function *name* (no args), so each visible slot gets its own tiny
-- pre-declared function (onWallpaperClick0..N). A table (pickSlots) maps the
-- slot index to the actual wallpaper id for the *current* render, and the
-- slot handler just looks itself up in that table.

wallpaperPath = "~/.steam/steam/steamapps/workshop/content/431960/"

local pickSlots = {}

type Wallpaper = {
	nb: string,
	name: string,
	preview: string,
}

local function getNb(t)
	local count = 0
	for _ in pairs(t) do
		count += 1
	end
	return count
end

function takeWallpaper()
	local wallpaper: { Wallpaper } = {}
	local entries, err = noctalia.listDir(wallpaperPath)
	if not entries then
		warn("impossible de lister")
		noctalia.notify("W Engine", "not work")
		return wallpaper
	end

	for _, entryName in entries do
		local content, readErr = noctalia.readFile(wallpaperPath .. entryName .. "/project.json")
		if content then
			local value = noctalia.json.decode(content)
			local name = value.title or entryName
			local preview = value.preview or "no preview"
			table.insert(wallpaper, {
				nb = entryName,
				name = name,
				preview = preview,
			})
		else
			noctalia.notify("W Engine", "no data for " .. entryName)
		end
	end
	return wallpaper
end

function loadWallpaper(id)
	noctalia.runAsync("pkill -f linux-wallpaper", function()
		local cmd = "setsid linux-wallpaperengine --screen-root eDP-1 " .. id .. " > /dev/null 2>&1"
		noctalia.runAsync(cmd)
	end, 5000)
end
local function onPickAt(slot)
	local id = pickSlots[slot]
	if id ~= nil then
		loadWallpaper(id)
		noctalia.notify("W Engine", "wallpaper: " .. id)
	end
end

local function render()
	pickSlots = {}
	local buttons = {}
	local list = takeWallpaper()
	local nbList = getNb(list)
	for count = 1, nbList, 1 do
		local data = list[count]
		local slotIndex = count - 1
		pickSlots[slotIndex] = data.nb
		table.insert(buttons, ui.button({
			text = data.name,
			key = data.nb,
			onClick = `onWallpaperClick{slotIndex}`,
		}))
	end
	panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.label({ text = "W Engine", align = "center" ,fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.button({ glyph = "close", onClick = "onCloseClicked" }),
		}),
		ui.scroll({ gap = 8, align = "stretch", flexGrow = 1 }, buttons),
	}))
end

function onOpen(_context)
	render()
end

function onCloseClicked()
	panel.close()
end

-- Pre-declared slot handler
function onWallpaperClick0() onPickAt(0) end
function onWallpaperClick1() onPickAt(1) end
function onWallpaperClick2() onPickAt(2) end
function onWallpaperClick3() onPickAt(3) end
function onWallpaperClick4() onPickAt(4) end
function onWallpaperClick5() onPickAt(5) end
function onWallpaperClick6() onPickAt(6) end
function onWallpaperClick7() onPickAt(7) end
function onWallpaperClick8() onPickAt(8) end
function onWallpaperClick9() onPickAt(9) end
function onWallpaperClick10() onPickAt(10) end
function onWallpaperClick11() onPickAt(11) end
function onWallpaperClick12() onPickAt(12) end
function onWallpaperClick13() onPickAt(13) end
function onWallpaperClick14() onPickAt(14) end
function onWallpaperClick15() onPickAt(15) end
function onWallpaperClick16() onPickAt(16) end
function onWallpaperClick17() onPickAt(17) end
function onWallpaperClick18() onPickAt(18) end
function onWallpaperClick19() onPickAt(19) end
function onWallpaperClick20() onPickAt(20) end
function onWallpaperClick21() onPickAt(21) end
function onWallpaperClick22() onPickAt(22) end
function onWallpaperClick23() onPickAt(23) end
function onWallpaperClick24() onPickAt(24) end
function onWallpaperClick25() onPickAt(25) end
function onWallpaperClick26() onPickAt(26) end
function onWallpaperClick27() onPickAt(27) end
function onWallpaperClick28() onPickAt(28) end
function onWallpaperClick29() onPickAt(29) end