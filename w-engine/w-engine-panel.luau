--!nonstrict
-- W-Engine panel — picks a Wallpaper Engine workshop item and applies it via
-- linux-wallpaperengine.

-- Local variable

wallpaperPath = {"~/.steam/steam/steamapps/workshop/content/431960/",
"~/.local/share/Steam/steamapps/workshop/content/431960/",
"~/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/workshop/content/431960/",
"~/snap/steam/common/.local/share/Steam/steamapps/workshop/content/431960/",
"~/snap/steam/common/.local/share/steam/steamapps/workshop/content/431960/"}
wallpaperPathSelected = nil

local pickSlots = {}
local columns = 4
local previewWidth = 180
local previewHeight = 100

local outputFinalList = {}
local outputSelectedName = nil
local lastOutputUse = nil

local pidList: { killSystem } = {}

-- 
type Wallpaper = {
	nb: string,
	name: string,
	preview: string,
}

type killSystem = {
	pid: number,
	output: string,
}

function tr(key, subst)
	if subst then
		return noctalia.tr(key, subst)
	end
	return noctalia.tr(key)
end

function takeWallpaper()
	local wallpaper: { Wallpaper } = {}

	for count = 1, #wallpaperPath, 1 do
		if noctalia.listDir(wallpaperPath[count]) then
			wallpaperPathSelected = wallpaperPath[count]
		end
	end

	local entries, err = noctalia.listDir(wallpaperPathSelected)
	if not entries then
		warn(err or "impossible de lister")
		noctalia.notify(tr("panel.title"), tr("panel.list_failed"))
		return wallpaper
	end
	for _, entryName in entries do

		if not tonumber(entryName) then -- test if is a id 
			continue
		end

		local content, readErr = noctalia.readFile(wallpaperPathSelected .. entryName .. "/project.json")
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
			noctalia.notify(tr("panel.title"), tr("panel.missing_project_json", { name = entryName }))
		end
	end
	return wallpaper
end

function trim(s) -- personnal trim
   return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function getStoredPid(screen)
	for _, entry in ipairs(pidList) do
		if entry.output == screen then
			return entry.pid
		end
	end
	return nil
end

function setStoredPid(screen, pid)
	for _, entry in ipairs(pidList) do
		if entry.output == screen then
			entry.pid = pid
			return
		end
	end
	table.insert(pidList, { pid = pid, output = screen })
end


function launchWallpaper(screen, id, pidFile)
	local cmd = "setsid linux-wallpaperengine --screen-root " .. screen .. " " .. id
		.. " > /dev/null 2>&1 & echo $! > " .. pidFile

	noctalia.runAsync(cmd, function(result)
		local pidContent = noctalia.readFile(pidFile)
		if pidContent then
			local pid = trim(pidContent)
			setStoredPid(screen, pid)
		end
	end, 5000)
end

function loadWallpaper(id)
	lastOutputUse = outputSelectedName or takeOutput()
	local pidFile = "/tmp/w-engine-" .. lastOutputUse .. ".pid"
	if noctalia.fileExists(pidFile) == true then
		local pidT = noctalia.readFile(pidFile)
		local pid = trim(pidT)
		for _, outputLink in ipairs(pidList) do
			if outputLink.pid == pid then
				local killCmd = "kill -o " .. pid
				noctalia.runAsync(killCmd)
			end
		end
	end
	local oldPid = getStoredPid(lastOutputUse)
	if oldPid then
		noctalia.runAsync("kill " .. oldPid, function()
			launchWallpaper(lastOutputUse, id, pidFile)
		end, 3000)
	else
		launchWallpaper(lastOutputUse, id, pidFile)
	end
end

function onPickAt(slot)
	local id = pickSlots[slot]
	if id ~= nil then
		loadWallpaper(id)
		noctalia.notify(tr("panel.title"), tr("panel.apply", { id = id }))
	end
end

local function render()
	pickSlots = {}
	local tiles = {}
	local list = takeWallpaper()
	for count = 1, #list, 1 do
		local data = list[count]
		local slotIndex = count - 1
		pickSlots[slotIndex] = data.nb
		table.insert(tiles, ui.column({ gap = 4, key = data.nb, align = "center" }, {
			ui.image({
				path = wallpaperPathSelected .. data.nb .. "/" .. data.preview,
				width = previewWidth,
				height = previewHeight,
				fit = "cover",
				radius = 8,
				onClick = `onWallpaperClick{slotIndex}`,
			}),
			ui.label({
				text = data.name,
				fontSize = 11,
				maxLines = 1,
				maxWidth = 120,
				textAlign = "center",
			}),
		}))
	end
	local rows = {}
	local row = {}
	for i, tile in ipairs(tiles) do
		table.insert(row, tile)
		if #row == columns or i == #tiles then
			table.insert(rows, ui.row({ gap = 12, align = "start" }, row))
			row = {}
		end
end
	panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.label({ text = tr("panel.title"), align = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.select({ options = getOutput(), onChange = "outputSelected" }),
			ui.button({ glyph = "close", onClick = "onCloseClicked" }),
		}),
		ui.scroll({ gap = 12, align = "stretch", flexGrow = 1 }, rows),
	}))
end

function takeOutput()
	local output = noctalia.outputs()
	for _, outputF in ipairs(output) do
		return outputF.name
	end
end 

function outputSelected(index, label)
	if type(label) == "string" and label ~= "" then
		outputSelectedName = label
		noctalia.notify("Output change :", outputSelectedName)
	end
end

function getOutput()
	outputFinalList = {}
	local outputsList = noctalia.outputs()
	if not outputsList then
		return
	end
	for _, output in ipairs(outputsList) do
		noctalia.log(output.name)
		table.insert(outputFinalList, output.name)
	end
	return outputFinalList
end

function onOpen(_context)
	outputSelectedName = takeOutput()
	render()
end

function onCloseClicked()
	panel.close()
end

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
function onWallpaperClick30() onPickAt(30) end
function onWallpaperClick31() onPickAt(31) end
function onWallpaperClick32() onPickAt(32) end
function onWallpaperClick33() onPickAt(33) end
function onWallpaperClick34() onPickAt(34) end
function onWallpaperClick35() onPickAt(35) end
function onWallpaperClick36() onPickAt(36) end
function onWallpaperClick37() onPickAt(37) end
function onWallpaperClick38() onPickAt(38) end
function onWallpaperClick39() onPickAt(39) end
function onWallpaperClick40() onPickAt(40) end
function onWallpaperClick41() onPickAt(41) end
function onWallpaperClick42() onPickAt(42) end
function onWallpaperClick43() onPickAt(43) end
function onWallpaperClick44() onPickAt(44) end
function onWallpaperClick45() onPickAt(45) end
function onWallpaperClick46() onPickAt(46) end
function onWallpaperClick47() onPickAt(47) end
function onWallpaperClick48() onPickAt(48) end
function onWallpaperClick49() onPickAt(49) end
function onWallpaperClick50() onPickAt(50) end
function onWallpaperClick51() onPickAt(51) end
function onWallpaperClick52() onPickAt(52) end
function onWallpaperClick53() onPickAt(53) end
function onWallpaperClick54() onPickAt(54) end
function onWallpaperClick55() onPickAt(55) end
function onWallpaperClick56() onPickAt(56) end
function onWallpaperClick57() onPickAt(57) end
function onWallpaperClick58() onPickAt(58) end
function onWallpaperClick59() onPickAt(59) end
function onWallpaperClick60() onPickAt(60) end