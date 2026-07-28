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

-- load personnal path

local dir = noctalia.pluginDataDir()
local path = dir .. "/data.json"
local raw = noctalia.readFile(path)
if raw then
	local data = noctalia.json.decode(raw)
	if data and data.personnalPath then
		for _, p in ipairs(data.personnalPath) do
			table.insert(wallpaperPath, p)
		end
	end
end

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

function isValidPid(screen, pid)
	local path = "/tmp/w-engine-" .. screen .. ".pid"
	if noctalia.fileExists(path) then
		local fileTmp = noctalia.readFile(path)
		if not fileTmp then
			return false
		end
		local file = trim(fileTmp)
		if file == pid then

			local check = "/proc/" .. pid .. "/cmdline"
			local checkContentTmp = noctalia.readFile(check)
			if not checkContentTmp then
				return false
			end
			local checkContent = trim(checkContentTmp)
			local match = "^linux%-wallpaperengine"
			if checkContent:match(match) then
				return true
			end
		end
	end
	return false
end

function getStoredPid(screen)
	for _, entry in ipairs(pidList) do
		if entry.output == screen then
			if isValidPid(screen, entry.pid) then
				return entry.pid
			end
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
	local oldPid = getStoredPid(lastOutputUse) -- here
	if oldPid then
		noctalia.runAsync("kill " .. oldPid, function() -- here
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
      			onClick = function()
          		loadWallpaper(pickSlots[slotIndex])
          		noctalia.notify(tr("panel.title"), tr("panel.apply", { id = pickSlots[slotIndex] }))
      			end,
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