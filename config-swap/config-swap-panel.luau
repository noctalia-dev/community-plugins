--!nonstrict
-- Config Swap panel

-- Local variables

local configBox = "~/Config-Swap" 			

local listConfig = nil

local pickSlots = {}
local columns = 2
local previewWidth = 470
local previewHeight = 350
local previewImage = ""

local selectedView = 0			-- Controls which screen to render (0=welcome, 1=installed, 2=store)

local previewCache = {}			-- In-memory map: config name -> cached preview image path
local previewPending = {}

local configWidth = 800			-- Preview dialog size
local configHeight = 600

-- Data model

type infoConfig = {
	name: string,  				-- Configuration name
	author: string,				-- Configuration author
	origin: string,				-- Distribution/source (NixOS, Arch, CachyOS, etc.)
	preview: string,			-- Preview image path (preview.png)
	path: string,				-- Config path (example: config/{name})
	description: string,		-- Short description
	wallpaperPath: string,		-- Wallpaper path
	depedencie: boolean,		-- Whether extra dependencies are required
}

-- Resolve Noctalia state directory

local function resolveStateDir()
	return noctalia.getenv("NOCTALIA_STATE_HOME")
		or ((noctalia.getenv("XDG_STATE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.local/state")) .. "/noctalia")
end

-- Detecte dangerous charactère

function isDetect(target: string)
	local match_string = "[/.$();]"
	
	if string.match(target, match_string) then
		return true
	else
		return false
	end
end

-- Store listing cache

local allConfig: { infoConfig } = {}

local requestFetchList = {
	url = "https://api.github.com/repos/Tadomika-Ari/Config-Swap-Box/contents/config",
	method = "GET",
  	headers = { "Accept: application/json", "User-Agent: Config-Swap-Box-Plugin" },
  	follow_redirects = true
}

-- Translation helper

function tr(key, subst)
	if subst then
		return noctalia.tr("panel." .. key, subst)
	end
	return noctalia.tr("panel." .. key)
end

-- Build settings.toml path from the resolved state dir

function takePosSetting()
	local noctaliaStateDir = resolveStateDir()
	local settingsTomlPath = noctaliaStateDir .. "/settings.toml"
	return settingsTomlPath
end

-- Shell escaping to safely build external commands

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end


-- Welcome warning screen

local function welcomeWarning() 			-- Shown after startup; refusing closes the plugin
	panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.label({ text = tr("title"), textAlign = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
		}),
		ui.label({ text = tr("welcome_message_title"), textAlign = "center", fontSize = 16, fontWeight = "bold", color = "on_surface" }),
		ui.label({ text = tr("welcome_message1"), textAlign = "center", fontSize = 14, color = "on_surface_variant" }),
		ui.label({ text = tr("welcome_message2"), textAlign = "center", fontSize = 14, color = "on_surface_variant" }),
		ui.row({ gap = 8, justify = "center" }, {
			ui.button({ text = tr("not_agree"), variant = "ghost", onClick = "onCloseClicked" }),
			ui.button({ text = tr("agree"), onClick = function()
				selectedView = 1
				render()
			end
			}),
		}),
	}))
end

local function renderConfirmApply(data: infoConfig)			-- Confirmation dialog before applying a config
	panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.label({ text = tr("title"), textAlign = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
		}),
		ui.label({ text = tr("confirmation"), textAlign = "center", fontSize = 16, fontWeight = "bold", color = "on_surface" }),
		ui.label({ text = data.name, textAlign = "center", fontSize = 14, color = "on_surface_variant" }),
		ui.label({ text = tr("description_confirmation"), textAlign = "center", fontSize = 13, color = "on_surface_variant" }),
		ui.row({ gap = 8, justify = "center" }, {
			ui.button({ text = tr("cancel"), variant = "ghost", onClick = "render" }),
			ui.button({ text = tr("apply"), variant = "primary", onClick = function()
				applyConfig(data)
				render()
			end
			}),
		}),
	}))
end

-- Apply selected config and wallpaper

function applyConfig(data: infoConfig)
	noctalia.notify(tr("apply_notification_title"))

	if isDetect(data.name) == true then					-- detecte malicious name
		noctalia.notify(tr("apply_notification_title"), "Invalid name. Please check your info.json")
		return
	end

	local pathSettings = takePosSetting()
	if not pathSettings then
		noctalia.notify(tr("notification_title"), "Path not found, please check your setting toml")
		return
	end

	local src = shellQuote(noctalia.expandPath(configBox .. "/" .. data.name .. "/settings.toml"))
	local dest = shellQuote(noctalia.expandPath(pathSettings))
	local cmd = "cp " .. src .. " " .. dest

	noctalia.runAsync(cmd, function(result)
		if result and result.exitCode == 0 then
			noctalia.setWallpaper(configBox .. "/" .. data.name .. "/wallpaper.png")
		else
			noctalia.notify(tr("notification_title"), "swap failed")
		end
	end)
end

-- Download the full config bundle: settings, info json, preview, wallpaper

function downloadConfig(data: infoConfig)
	noctalia.notify(tr("install_notification_title"))

	if isDetect(data.name) == true then
		noctalia.notify("Download", "Invalide name detected, please check target config")
		return
	end

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

-- GitHub store preview cache

local function previewCachePath(name)
	-- Keep cached previews under plugin data to avoid repeated downloads.
	local dir = noctalia.pluginDataDir() .. "/preview-cache"
	noctalia.mkdirAll(dir)
	return dir .. "/" .. name .. ".png"
end

local function queuePreviewDownload(name)
	-- Prevent duplicate requests for the same preview while one is in flight.
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

-- Delete an installed config

local function delete(name)

	if not name or name == "" then
		noctalia.notify("Delete", "invalid name")
		return
	end

	if isDetect(name) == true then								-- detecte malicious name
		noctalia.notify("Delete", "Invalide Name. Please check info.json")
		return
	end

	local target = noctalia.expandPath(configBox .. "/" .. name)
	local cmd = "rm -rf " .. shellQuote(target)  				-- shellQuote protects the rm target path
	noctalia.runAsync(cmd, function(result)
		if result and result.exitCode == 0 then
			noctalia.notify("Delete Ok")
		else
			noctalia.notify("Delete failed")
		end
	end)
	render()
end

local function renderDeleteConfirmation(name)  					-- Confirmation panel before deleting a config
	panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
		ui.label({ text = tr("confirmation_delete") .. name .. "?", align = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
		ui.button({ text = tr("delete"), onClick = function()
			delete(name)
		end
		}),
		ui.button({ glyph = "close", onClick = "render" }),
	}))
end

-- Save/backup settings section

local noctaliaStateDir = resolveStateDir()
local settingsTomlPath = noctaliaStateDir .. "/settings.toml"	-- Active settings file path

local saveNameInput = "save"

local function saveConfig()
	local name = saveNameInput ~= "" and saveNameInput or "save"

	if isDetect(name) then										-- detecte special charactere
		noctalia.notify("Save", "Invalid Name")
		return
	end

	local savePath = configBox .. "/" .. name
	noctalia.mkdirAll(savePath)

	local settingFile: infoConfig = {
		name = name,
		description = "save for reset",
		path = "config/" .. name,
		origin = "not give",
		wallpaperPath = nil,
		depedencie = false,
		preview = nil,
		author = noctalia.getenv("USER"),
	}
	local jsonData = noctalia.json.encode(settingFile)
	noctalia.writeFile(savePath .. "/info.json", jsonData)

	local content = noctalia.readFile(settingsTomlPath)
	if content then
		noctalia.writeFile(savePath .. "/settings.toml", content)
		noctalia.notify("Save", "Save ok : " .. name)
		render()
	else
		noctalia.notify("Save", "settings.toml not found")
	end
end

function onSaveNameChange(value)
	saveNameInput = value
end

local function renderSetting()
	local rowsSettings = {
		ui.column({ gap = 8 }, {
			ui.label({
				text = tr("description_setting1"),
				fontSize = 12,
				color = "on_surface_variant",
			}),
			ui.row({ flexGrow = 1, gap = 16, align = "center" }, {
				ui.input({
					key = "save-name-input",
					value = saveNameInput,
					placeholder = "Save name",
					onChange = "onSaveNameChange",
					flexGrow = 1,
				}),
				ui.button({ text = tr("save"), onClick = function()
					saveConfig()
				end
				}),
			}),
		}),
	}
	panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
		ui.label({ text = "Setting section", textAlign = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
		ui.button({ text = "X", onClick = "render"}),
		ui.scroll({ gap = 12, align = "stretch", flexGrow = 1 }, rowsSettings),
	}))
end

-- Store information panel

local function renderInfoStore()
	panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.label({ text = tr("info_store_title"), textAlign = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.button({ text = tr("info_store_github_button"), onClick = function()
				noctalia.copyToClipboard("https://github.com/Tadomika-Ari/Config-Swap-Box", "text/plain")
				noctalia.notify(tr("notification_title"), tr("info_store_copy_link_success"))
			end 
			}),
			ui.button({ glyph = "close", onClick = "render" }),
		}),
		ui.scroll({ gap = 16, align = "stretch", flexGrow = 1 }, {
			ui.column({ gap = 4 }, {
				ui.label({ text = tr("info_store_what_is_title"), fontSize = 13, fontWeight = "bold", color = "on_surface" }),
				ui.label({ text = tr("info_store_what_is_body"), fontSize = 12, color = "on_surface_variant" }),
			}),
			ui.column({ gap = 4 }, {
				ui.label({ text = tr("info_store_installing_title"), fontSize = 13, fontWeight = "bold", color = "on_surface" }),
				ui.label({ text = tr("info_store_installing_body"), fontSize = 12, color = "on_surface_variant" }),
			}),
			ui.column({ gap = 4 }, {
				ui.label({ text = tr("info_store_applying_title"), fontSize = 13, fontWeight = "bold", color = "on_surface" }),
				ui.label({ text = tr("info_store_applying_body"), fontSize = 12, color = "on_surface_variant" }),
			}),
			ui.column({ gap = 4 }, {
				ui.label({ text = tr("info_store_community_title"), fontSize = 13, fontWeight = "bold", color = "on_surface" }),
				ui.label({ text = tr("info_store_community_body"), fontSize = 12, color = "on_surface_variant" }),
			}),
			ui.column({ gap = 4 }, {
				ui.label({ text = tr("info_how_to_submite_config_title"), fontSize = 13, fontWeight = "bold", color = "on_surface" }),
				ui.label({ text = tr("info_how_to_submite_config_body"), fontSize = 12, color = "on_surface_variant" }),
			}),
			ui.column({ gap = 4 }, {
				ui.label({ text = tr("info_store_rate_limits_title"), fontSize = 13, fontWeight = "bold", color = "on_surface" }),
				ui.label({ text = tr("info_store_rate_limits_body"), fontSize = 12, color = "on_surface_variant" }),
			}),
		}),
	}))
end

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

		table.insert(tiles, ui.column({ gap = 8, key = data.path, align = "stretch", width = previewWidth }, {
			ui.image({
				path = imagePath,
				width = previewWidth,
				height = previewHeight,
				fit = "cover",
				radius = 8,
			}),
			ui.label({
				text = data.name,
				fontSize = 14,
				fontWeight = "medium",
				color = "on_surface",
				textAlign = "center",
				maxLines = 1,
			}),
			ui.button({
				text = tr("install"),
				variant = "primary",
				width = previewWidth,
				onClick = function()
					downloadConfig(data)
				end
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
			ui.label({ text = tr("title"), textAlign = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.label({ text = tr("store_title"), textAlign = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.button({ text = tr("show_list"), onClick = function()
				selectedView = 1
				render()
			end
			}),
			ui.button({ text = "Info", onClick = function()
				renderInfoStore()
			end
			}),
			ui.button({ text = tr("refresh"), onClick = "getFetchList"}),
			ui.button({ glyph = "close", onClick = "onCloseClicked" }),
		}),
		ui.scroll({ gap = 12, align = "stretch", flexGrow = 1 }, rows),
	}))
end

-- Installed config details panel

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
 
-- List installed configs from ~/Config-Swap

function getListInstall()
	local localPath = configBox
	local list = noctalia.listDir(localPath)
	local listShow: { infoConfig } = {}

	for i, entryName in ipairs(list) do
    	local infoPath = configBox .. "/" .. entryName .. "/info.json"
    	local content = noctalia.readFile(infoPath)
    	local data = content and noctalia.json.decode(content) or nil

    	if not data then
			-- Fallback entry when info.json is missing or invalid.
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

local function renderInstall()
	pickSlots = {}
	local tiles = {}
	local list = getListInstall() or {}
	for count = 1, #list, 1 do
		local data = list[count]
		local slotIndex = count - 1
		pickSlots[slotIndex] = data.path

		table.insert(tiles, ui.column({ gap = 8, key = data.path, align = "stretch", width = previewWidth }, {
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
			ui.label({
				text = data.name,
				fontSize = 14,
				fontWeight = "medium",
				color = "on_surface",
				textAlign = "center",
				maxLines = 1,
			}),
			ui.row({ gap = 8, justify = "space_between", align = "center" }, {
				ui.button({ text = "delete", variant = "outline", onClick = function()
					renderDeleteConfirmation(data.name)
				end
				}),
				ui.button({ text = "apply", variant = "primary", onClick = function()
					renderConfirmApply(data)
				end
				}),
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
			ui.label({ text = tr("title"), textAlign = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.label({ text = tr("installed_title"), textAlign = "center", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.button({ text = tr("show_store"), onClick = function()
				selectedView = 2
				render()
			end
			}),
			ui.button({ text = "Setting", onClick = function()
				renderSetting()
			end
			}),
			ui.button({ text = tr("refresh"), onClick = "getFetchList"}),
			ui.button({ glyph = "close", onClick = "onCloseClicked" }),
		}),
		ui.scroll({ gap = 12, align = "stretch", flexGrow = 1 }, rows),
	}))
end

-- Root view router

function render()
	if selectedView == 0 then
		welcomeWarning()
	end
	if selectedView == 1 then 
		renderInstall()
	end
	if selectedView == 2 then
		renderList()
	end
end

-- Fetch available configs from GitHub

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

-- Plugin entry points

function onOpen(_context)
	render()
end

function onCloseClicked()
	panel.close()
end