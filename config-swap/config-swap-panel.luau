--!nonstrict
-- Config Swap

-- Local variable

local configBox = "~/Config-Swap" 			
local pathLocal = "~/.local/state/noctalia/settings.toml"		-- path for settings

local listConfig = nil
local optionFull = {"all", "not full", "full"}

local pickSlots = {}
local columns = 2
local previewWidth = 470
local previewHeight = 350
local previewImage = ""

local selectedView = 1

local previewCache = {}
local previewPending = {}

local configWidth = 800
local configHeight = 600

-- Type function

type infoConfig = {
	name: string,  				-- name config
	author: string,				-- author config
	origin: string,				-- origin congig (Nixos, Arch, CachOS,..)
	preview: string,			-- preview config (path to preview.png)
	path: string,				-- config path (example: config/{name})
	description: string,		-- little description
	wallpaperPath: string,		-- wallpaper path
	depedencie: boolean,		-- other depedencie for your config
}

-- section for get all config

local allConfig: { infoConfig } = {}

local requestFetchList = {
	url = "https://api.github.com/repos/Tadomika-Ari/Config-Swap-Box/contents/config",
	method = "GET",
  	headers = { "Accept: application/json", "User-Agent: Config-Swap-Box-Plugin" },
  	follow_redirects = true
}

-- translate section

function tr(key, subst)
	if subst then
		return noctalia.tr("panel." .. key, subst)
	end
	return noctalia.tr("panel." .. key)
end

-- function get position of settings noctalia

function takePosSetting()
	local dir = noctalia.pluginDataDir()
	local path = dir .. "/data.json"
	local raw = noctalia.readFile(path)
	if raw then
		local data = noctalia.json.decode(raw)
		if data and data.settingsPath then
			return data.settingsPath
		end
	end
end

-- Section protection shell commande

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- apply config file and wallpaper

function applyConfig(data: infoConfig)
	noctalia.notify(tr("apply_notification_title"))

	local pathSettings = takePosSetting()
	if not pathSettings then
		noctalia.notify(tr("notification_title"), "Path not found, please check your data.json")
		return
	end

	local src = shellQuote(noctalia.expandPath(configBox .. "/" .. data.name .. "/settings.toml"))
	local dest = shellQuote(noctalia.expandPath(pathSettings))
	local cmd = "cp " .. src .. " " .. dest

	noctalia.runAsync(cmd, function(result)
	noctalia.notify("debug cp", "exit=" .. tostring(result and result.exitCode) .. " err=[" .. tostring(result and result.stderr) .. "]")
		if result and result.exitCode == 0 then
			noctalia.setWallpaper(configBox .. "/" .. data.name .. "/wallpaper.png")
		else
			noctalia.notify(tr("notification_title"), "cp failed")
		end
	end)
end

-- download config folder (support: noctalia settings, preview image and json info

function downloadConfig(data: infoConfig)
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

-- Section delete install file

local function delete(name)

	if not name or name == "" then
		noctalia.notify("Delete", "invalid name")
		return
	end

	local target = noctalia.expandPath(configBox .. "/" .. name)
	local cmd = "rm -rf " .. shellQuote(target)
	noctalia.runAsync(cmd, function(result)
		if result and result.exitCode == 0 then
			noctalia.notify("Delete Ok")
		else
			noctalia.notify("Delete failed")
		end
	end)
	render()
end

local function renderDeleteConfirmation(name)
	panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
		ui.label({ text = "Are you sure too delete " .. name .. "?", align = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
		ui.button({ text = "delete", onClick = function()
			delete(name)
		end
		}),
		ui.button({ glyph = "close", onClick = "render" }),
	}))
end

-- Section for setting and reset / save config

local function renderSetting(name)
	panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
		ui.label({ text = "Setting section", align = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
		ui.button({ text = "en cours", onClick = "getFetchList"}),
		ui.button({ glyph = "en cours", onClick = "render" }),
	}))
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
	local rows = {
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
		ui.button({ glyph = "trash", onClick = function()
			renderDeleteConfirmation(data.name)
		end
		}),
		ui.button({ glyph = "close", onClick = "render" }),
	}
	panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
		ui.scroll({ gap = 12, align = "stretch", flexGrow = 1 }, rows),
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
				path = "config/" .. entryName,
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
			path = data.path,
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

-- section for render all installed config

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
					downloadConfig(data)  -- here
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
			ui.button({ text = "delete test", onClick = function()
				renderDeleteConfirmation("")
			end
			}),
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
	allConfig = {}
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
				author = nil,
				depedencie = nil,
				description = nil,
				origin = nil,
				preview = nil,
				wallpaperPath = nil,
			})
		end
		listConfig = allConfig
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