--!nonstrict
-- Config Swap

-- Local variable

local configBox = "~/Config-Swap" 													   -- path for storage

local listConfig = nil
local optionFull = {"all", "not full", "full"}

local pickSlots = {}
local columns = 2
local previewWidth = 470
local previewHeight = 350
local previewImage = "~/Downloads/arme.png"

local selectedView = 1

local previewCache = {}
local previewPending = {}

local configWidth = 800
local configHeight = 600

-- Type function

type config = {
	name: string,
	path: string,
	full: boolean,
}

type infoConfig = {
	name: string,
	author: string,
	origin: string,
	preview: string,
	description: string,
	wallpaperPath: string,
	depedencie: boolean,
}

-- section

local allConfig: { config } = {}

local requestFetchList = {
	url = "https://api.github.com/repos/Tadomika-Ari/Config-Swap-Box/contents/config",
	method = "GET",
  	headers = { "Accept: application/json", "User-Agent: Config-Swap-Box-Plugin" },
  	follow_redirects = true
}

--

function tr(key, subst)
	if subst then
		return noctalia.tr("panel." .. key, subst)
	end
	return noctalia.tr("panel." .. key)
end

-- apply config file

function applyConfig(data: config)
	noctalia.notify(tr("apply_notification_title"))

	local cmd = "cp " .. configBox .. "/" .. data.name .. "/settings.toml " .. "~/.local/state/noctalia/settings.toml"
	noctalia.setWallpaper(configBox .. "/" .. data.name .. "/wallpaper.png")

	noctalia.runAsync(cmd)
end

-- download config folder (support: noctalia settings, preview image and json info

function downloadConfig(data: config)
	noctalia.notify(tr("install_notification_title"))

	noctalia.mkdirAll(configBox .. "/" .. data.name)

	local path = data.path .. "/settings.toml"
	local url = "https://raw.githubusercontent.com/Tadomika-Ari/Config-Swap-Box/main/" .. path
	noctalia.download(url, configBox .. "/" .. data.name .. "/settings.toml" , function(ok)
		if ok then
			noctalia.notify(tr("notification_title"), tr("download_ok"))
		else
			noctalia.notify(tr("notification_title"), tr("download_failed"))
		end
	end)
	local path = data.path .. "/info.json"
	local url = "https://raw.githubusercontent.com/Tadomika-Ari/Config-Swap-Box/main/" .. path
	noctalia.download(url, configBox .. "/" .. data.name .. "/info.json" , function(ok)
		if ok then
			noctalia.notify(tr("notification_title"), tr("download_ok"))
		else
			noctalia.notify(tr("notification_title"), tr("download_failed"))
		end
	end)
	local path = data.path .. "/preview.png"
	local url = "https://raw.githubusercontent.com/Tadomika-Ari/Config-Swap-Box/main/" .. path
	noctalia.download(url, configBox .. "/" .. data.name .. "/preview.png" , function(ok)
		if ok then
			noctalia.notify(tr("notification_title"), tr("download_ok"))
		else
			noctalia.notify(tr("notification_title"), tr("download_failed"))
		end
	end)
	local path = data.path .. "/wallpaper.png"
	local url = "https://raw.githubusercontent.com/Tadomika-Ari/Config-Swap-Box/main/" .. path
	noctalia.download(url, configBox .. "/" .. data.name .. "/wallpaper.png" , function(ok)
		if ok then
			noctalia.notify(tr("notification_title"), tr("download_ok"))
		else
			noctalia.notify(tr("notification_title"), tr("download_failed"))
		end
	end)
end 

-- Section Preview for github store

local function previewCachePath(name)
	local dir = noctalia.pluginDataDir() .. "/preview-cache"
	noctalia.mkdirAll(dir)
	return dir .. "/" .. name .. ".png"
end

local function queuePreviewDownload(name)
	if previewCache[name] ~= nil or previewPending[name] then
		return
	end

	local dest = previewCachePath(name)
	if noctalia.fileExists(dest) then
		previewCache[name] = dest
		return
	end

	previewPending[name] = true
	local url = "https://raw.githubusercontent.com/Tadomika-Ari/Config-Swap-Box/main/config/" .. name .. "/preview.png"

	noctalia.download(url, dest, function(ok)
		previewPending[name] = nil
		if ok then
			previewCache[name] = dest
			render()
		end
	end)
end

-- Section render for github Store

local function renderList()

	pickSlots = {}
	local tiles = {}
	local list = listConfig or {}

	for count = 1, #list, 1 do
		local data = list[count]
		local slotIndex = count - 1
		pickSlots[slotIndex] = data.path

		queuePreviewDownload(data.name)

		local imagePath = previewCache[data.name] or previewImage

		table.insert(tiles, ui.column({ gap = 4, key = data.path, align = "center" }, {
			ui.image({
      			path = imagePath,
				width = previewWidth,
				height = previewHeight,
				fit = "cover",
				radius = 8,
      			onClick = "onCloseClicked"
  			}),
			ui.row( {gap = 12, align = "start"}, {
				ui.button({ text = tr("install"), onClick = function()
					downloadConfig(data)
				end
				}),
				ui.label({
				text = data.name,
				fontSize = 11,
				maxLines = 1,
				maxWidth = 120,
				textAlign = "center",
				}),
				ui.button({ text = tr("apply"), onClick = function()
					applyConfig(data)
				end
				}),
			} ), 
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
			ui.label({ text = tr("title"), align = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.label({ text = tr("store_title"), align = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.button({ text = tr("show_list"), onClick = function()
				selectedView = 1
				render()
			end
			}),
			ui.select({ options = optionFull, onChange = "" }),
			ui.button({ text = tr("refresh"), onClick = "getFetchList"}),
			ui.button({ glyph = "close", onClick = "onCloseClicked" }),
		}),
		ui.scroll({ gap = 12, align = "stretch", flexGrow = 1 }, rows),
	}))
end

-- Section render for see config install info

local function renderConfig(data: infoConfig)
	panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
		ui.image({
      		path = configBox .. "/" .. data.name .. "/preview.png",
			width = configWidth,
			height = configHeight,
			fit = "cover",
			radius = 8,
  		}),
		ui.label({ text = data.name, align = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
		ui.label({ text = tr("created_by", { author = data.author }), align = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
		ui.label({ text = tr("origin", { origin = data.origin }), align = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
		ui.label({ text = tr("description", { description = data.description or "" }), align = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
		ui.button({ glyph = "close", onClick = "render" }),
	}))
end

-- Section for list allerady install file

function getListInstall()
	local localPath = configBox
	local list = noctalia.listDir(localPath)
	local listShow: { infoConfig } = {}

	for i, entryName in ipairs(list) do
    	local infoPath = configBox .. "/" .. entryName .. "/info.json"
    	local content = noctalia.readFile(infoPath)
    	local data = content and noctalia.json.decode(content) or nil

    	if not data then
        	table.insert(listShow, {
            	name = entryName,
            	author = "None",
            	origin = "None",
            	preview = nil,
				description = nil,
            	wallpaperPath = nil,
            	depedencie = false,
        	})
        	continue
    	end

    	table.insert(listShow, {
        	name = data.name,
        	author = data.author,
        	origin = data.origin,
        	preview = data.preview,
			description = data.description,
        	wallpaperPath = data.wallpaperPath,
        	depedencie = data.depedencie,
    	})
	end
	return listShow
end

local function renderInstall()
	pickSlots = {}
	local tiles = {}
	local list = getListInstall() or {}
	for count = 1, #list, 1 do
		local data = list[count]
		local slotIndex = count - 1
		pickSlots[slotIndex] = data.path
		table.insert(tiles, ui.column({ gap = 4, key = data.path, align = "center" }, {
			ui.image({
      			path = configBox .. "/" .. data.name .. "/preview.png",
				width = previewWidth,
				height = previewHeight,
				fit = "cover",
				radius = 8,
      			onClick = function()
					renderConfig(data)
				end
  			}),
			ui.row( {gap = 12, align = "start"}, {
				ui.button({ text = "install", onClick = function()
					downloadConfig(data)
				end
				}),
				ui.label({
				text = data.name,
				fontSize = 11,
				maxLines = 1,
				maxWidth = 120,
				textAlign = "center",
				}),
				ui.button({ text = "apply", onClick = function()
					applyConfig(data)
				end
				}),
			} ), 
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
			ui.label({ text = tr("title"), align = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.label({ text = tr("installed_title"), align = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.button({ text = tr("show_store"), onClick = function()
				selectedView = 2
				render()
			end
			}),
			ui.select({ options = optionFull, onChange = "" }),
			ui.button({ text = tr("refresh"), onClick = "getFetchList"}),
			ui.button({ glyph = "close", onClick = "onCloseClicked" }),
		}),
		ui.scroll({ gap = 12, align = "stretch", flexGrow = 1 }, rows),
	}))
end

-- Render Choice

function render()
	if selectedView == 1 then 
		renderInstall()
	end
	if selectedView == 2 then
		renderList()
	end
end

-- Get all config on github

function getFetchList(onDone)
	noctalia.http(requestFetchList, function(respond)
		noctalia.log("raw body: " .. tostring(respond.body))
		if not respond.ok then
			noctalia.notify("Error", respond.status)
		end
		local data, err = noctalia.json.decode(respond.body)
		if err then
			noctalia.log(err)
			return
		end
		for i, item in ipairs(data) do
			table.insert(allConfig, {
				name = item.name,
				path = item.path,
				full = false
			})
		end
		listConfig = data
		render()
	end)
end

-- Other function

function onOpen(_context)
	render()
end

function onCloseClicked()
	panel.close()
end