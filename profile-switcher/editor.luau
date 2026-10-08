--!nonstrict

local profiles = require("./profiles.luau")

------------------------------------------------------------
-- State
------------------------------------------------------------

local editProfile = nil
local editRevision = 0

local isNewProfile = false
local newProfileId = ""

local newMonitorConnector = ""

local communityPalettes = {}
local communityLoading = false
local communityLoaded = false
local communityError = nil

local customPalettes = {}

local wallpaperFiles = {}
local wallpaperScanError = nil
local wallpaperTarget = "default"

-- Only this many thumbnail images are instantiated at once.
-- 12 = 3 columns x 4 rows.
local wallpaperPage = 1
local wallpaperPageSize = 12

------------------------------------------------------------
-- Built-in/static theme data
------------------------------------------------------------

local builtinPalettes = {
	"Ayu",
	"Catppuccin",
	"Dracula",
	"Eldritch",
	"Gruvbox",
	"Kanagawa",
	"Noctalia",
	"Nord",
	"Rosé Pine",
	"Tokyo-Night",
}

local wallpaperSchemes = {
	"m3-tonal-spot",
	"m3-content",
	"m3-fruit-salad",
	"m3-rainbow",
	"m3-monochrome",
	"vibrant",
	"faithful",
	"soft",
	"dysfunctional",
	"muted",
}

------------------------------------------------------------
-- Generic helpers
------------------------------------------------------------

local function cloneArray(source)
	local result = {}

	for _, value in ipairs(source or {}) do
		table.insert(result, value)
	end

	return result
end

local function cloneMap(source)
	local result = {}

	for key, value in pairs(source or {}) do
		result[key] = value
	end

	return result
end

local function dirname(path)
	if not path or path == "" then
		return ""
	end

	return path:match("^(.*)/[^/]+$") or ""
end

local function basename(path)
	if not path or path == "" then
		return ""
	end

	return path:match("([^/]+)$") or path
end

local function joinPath(directory, filename)
	if not directory or directory == "" then
		return filename or ""
	end

	if directory:sub(-1) == "/" then
		return directory .. filename
	end

	return directory .. "/" .. filename
end

local function isImageFile(filename)
	local lower = string.lower(filename or "")

	return lower:match("%.png$")
		or lower:match("%.jpg$")
		or lower:match("%.jpeg$")
		or lower:match("%.webp$")
		or lower:match("%.bmp$")
		or lower:match("%.gif$")
end

local function cloneProfile(profile)
	local defaultPath = profile.wallpapers and profile.wallpapers.default or ""

	local monitorMap = profile.wallpapers and profile.wallpapers.monitors or {}

	local inferredDirectory = profile.wallpapers and profile.wallpapers.directory or nil

	if not inferredDirectory or inferredDirectory == "" then
		inferredDirectory = dirname(defaultPath)
	end

	if inferredDirectory == "" then
		for _, path in pairs(monitorMap) do
			inferredDirectory = dirname(path)

			if inferredDirectory ~= "" then
				break
			end
		end
	end

	return {
		id = profile.id,
		filename = profile.filename,

		name = profile.name or profile.id,

		icon = profile.icon or "palette",

		theme_mode = profile.theme_mode or "dark",

		palette = {
			source = profile.palette and profile.palette.source or "wallpaper",

			name = profile.palette and profile.palette.name or "m3-content",
		},

		wallpapers = {
			directory = inferredDirectory or "",

			default = defaultPath,

			monitors = cloneMap(monitorMap),
		},

		schedule = {
			enabled = profile.schedule and profile.schedule.enabled ~= false or false,

			from = profile.schedule and profile.schedule.from or "07:00",

			["until"] = profile.schedule and profile.schedule["until"] or "17:00",

			days = cloneArray(profile.schedule and profile.schedule.days or {}),
		},
	}
end

local function newProfileTemplate()
	return {
		id = nil,
		filename = nil,

		name = noctalia.tr("editor.new_profile"),
		icon = "palette",
		theme_mode = "dark",

		palette = {
			source = "wallpaper",
			name = "m3-content",
		},

		wallpapers = {
			directory = "",
			default = "",
			monitors = {},
		},

		schedule = {
			enabled = false,
			from = "08:00",
			["until"] = "17:00",
			days = { 1, 2, 3, 4, 5 },
		},
	}
end

local function validProfileId(value)
	if not value or value == "" then
		return false
	end

	return value:match("^[a-zA-Z0-9_-]+$") ~= nil
end

local function containsValue(values, wanted)
	for _, value in ipairs(values or {}) do
		if value == wanted then
			return true
		end
	end

	return false
end

-- ui.select uses zero-based indices.
local function selectedIndex(values, wanted)
	for i, value in ipairs(values or {}) do
		if value == wanted then
			return i - 1
		end
	end

	return -1
end

local function normalizeCatalog(data)
	local result = {}
	local seen = {}

	local function add(value)
		if type(value) ~= "string" or value == "" then
			return
		end

		if not seen[value] then
			seen[value] = true

			table.insert(result, value)
		end
	end

	if type(data) ~= "table" then
		return result
	end

	for _, item in ipairs(data) do
		if type(item) == "string" then
			add(item)
		elseif type(item) == "table" then
			add(item.name)
			add(item.id)
			add(item.slug)
			add(item.title)
		end
	end

	if #result == 0 then
		for key, item in pairs(data) do
			if type(item) == "string" then
				add(item)
			elseif type(item) == "table" then
				add(item.name)
				add(item.id)
				add(item.slug)
				add(item.title)

				if type(key) == "string" then
					add(key)
				end
			elseif type(key) == "string" then
				add(key)
			end
		end
	end

	table.sort(result)

	return result
end

------------------------------------------------------------
-- Dynamic palette loading
------------------------------------------------------------

local function loadCustomPalettes()
	local dir = noctalia.expandPath("~/.config/noctalia/palettes")

	local files = noctalia.listDir(dir)

	customPalettes = {}

	if not files then
		return
	end

	for _, filename in ipairs(files) do
		if filename:match("%.json$") then
			table.insert(customPalettes, filename:gsub("%.json$", ""))
		end
	end

	table.sort(customPalettes)
end

local function loadCommunityPalettes()
	if communityLoading then
		return
	end

	communityLoading = true
	communityError = nil

	local accepted = noctalia.http({
		url = "https://api.noctalia.dev/palettes",

		method = "GET",

		headers = {
			"Accept: application/json",
		},

		follow_redirects = true,
	}, function(response)
		communityLoading = false

		if not response or not response.ok or response.status < 200 or response.status >= 300 then
			communityLoaded = false

			communityError = "HTTP " .. tostring(response and response.status or 0)

			render()

			return
		end

		local data, err = noctalia.json.decode(response.body or "")

		if not data then
			communityLoaded = false

			communityError = "JSON: " .. tostring(err)

			render()

			return
		end

		local names = normalizeCatalog(data)

		if #names == 0 then
			communityLoaded = false

			communityError = "Palette catalog was empty"

			render()

			return
		end

		communityPalettes = names

		communityLoaded = true

		communityError = nil

		render()
	end)

	if not accepted then
		communityLoading = false
		communityLoaded = false

		communityError = "Request was not accepted"
	end
end

------------------------------------------------------------
-- Wallpaper browser
------------------------------------------------------------

local function scanWallpapers()
	wallpaperFiles = {}
	wallpaperScanError = nil
	wallpaperPage = 1

	if not editProfile or not editProfile.wallpapers then
		return
	end

	local directory = editProfile.wallpapers.directory or ""

	if directory == "" then
		wallpaperScanError = noctalia.tr("editor.no_wallpaper_directory")

		return
	end

	local expanded = noctalia.expandPath(directory)

	local files, err = noctalia.listDir(expanded)

	if not files then
		wallpaperScanError = noctalia.tr("editor.could_not_read_directory", { error = tostring(err) })

		return
	end

	for _, filename in ipairs(files) do
		if isImageFile(filename) then
			table.insert(wallpaperFiles, filename)
		end
	end

	table.sort(wallpaperFiles)

	if #wallpaperFiles == 0 then
		wallpaperScanError = noctalia.tr("editor.no_images_found")
	end
end

local function currentWallpaperPath()
	if not editProfile then
		return ""
	end

	if wallpaperTarget == "default" then
		return editProfile.wallpapers.default or ""
	end

	return editProfile.wallpapers.monitors[wallpaperTarget] or ""
end

local function setCurrentWallpaper(path)
	if not editProfile then
		return
	end

	if wallpaperTarget == "default" then
		editProfile.wallpapers.default = path
	else
		editProfile.wallpapers.monitors[wallpaperTarget] = path
	end

	editRevision = editRevision + 1

	render()
end

local function setCurrentWallpaperFile(filename)
	if not editProfile then
		return
	end

	local path = joinPath(editProfile.wallpapers.directory, filename)

	setCurrentWallpaper(path)
end

local function wallpaperPreview(path)
	if not path or path == "" then
		return ui.column({
			height = 180,

			align = "center",
			justify = "center",

			fill = "surface_variant/0.25",

			radius = 10,

			gap = 6,
		}, {
			ui.glyph({
				name = "photo",

				size = 28,

				color = "on_surface_variant",
			}),

			ui.label({
				text = noctalia.tr("editor.no_wallpaper_selected"),

				fontSize = 11,

				color = "on_surface_variant",
			}),
		})
	end

	local expanded = noctalia.expandPath(path)

	if not noctalia.fileExists(expanded) then
		return ui.column({
			height = 180,

			align = "center",
			justify = "center",

			fill = "surface_variant/0.25",

			radius = 10,

			gap = 6,
		}, {
			ui.glyph({
				name = "photo-off",

				size = 28,

				color = "error",
			}),

			ui.label({
				text = noctalia.tr("editor.wallpaper_not_found"),

				fontSize = 11,

				color = "error",
			}),

			ui.label({
				text = path,

				fontSize = 9,

				maxLines = 2,

				color = "on_surface_variant",
			}),
		})
	end

	return ui.image({
		path = expanded,

		height = 180,

		radius = 10,

		fit = "cover",

		border = "outline/0.25",

		borderWidth = 1,
	})
end

local function wallpaperTargetButton(target, label)
	return ui.button({
		text = label,

		controlSize = "sm",

		variant = wallpaperTarget == target and "primary" or "default",

		onClick = function()
			wallpaperTarget = target

			wallpaperPage = 1

			render()
		end,
	})
end

local function wallpaperThumbnail(filename, width)
	local directory = editProfile.wallpapers.directory

	local path = joinPath(directory, filename)

	local selected = currentWallpaperPath() == path

	return ui.column({
		key = "wall-thumb-" .. wallpaperTarget .. "-" .. filename,

		width = width,

		gap = 4,

		onClick = function()
			setCurrentWallpaperFile(filename)
		end,
	}, {
		ui.image({
			path = noctalia.expandPath(path),

			width = width,
			height = 88,

			radius = 8,

			fit = "cover",

			border = selected and "primary" or "outline/0.20",

			borderWidth = selected and 2 or 1,

			onClick = function()
				setCurrentWallpaperFile(filename)
			end,
		}),

		ui.label({
			text = filename,

			fontSize = 9,

			maxWidth = width,

			maxLines = 1,

			textAlign = "center",

			color = selected and "primary" or "on_surface_variant",
		}),
	})
end

local function wallpaperPageCount()
	if #wallpaperFiles == 0 then
		return 1
	end

	return math.ceil(#wallpaperFiles / wallpaperPageSize)
end

local function clampWallpaperPage()
	local pages = wallpaperPageCount()

	if wallpaperPage < 1 then
		wallpaperPage = 1
	elseif wallpaperPage > pages then
		wallpaperPage = pages
	end
end

local function currentWallpaperPageFiles()
	clampWallpaperPage()

	local result = {}

	local startIndex = (wallpaperPage - 1) * wallpaperPageSize + 1

	local endIndex = math.min(startIndex + wallpaperPageSize - 1, #wallpaperFiles)

	for i = startIndex, endIndex do
		table.insert(result, wallpaperFiles[i])
	end

	return result
end

local function wallpaperGallery()
	local children = {}

	if wallpaperScanError then
		table.insert(
			children,

			ui.label({
				text = wallpaperScanError,

				fontSize = 11,

				color = "on_surface_variant",
			})
		)

		return ui.column({
			gap = 8,
		}, children)
	end

	local pageFiles = currentWallpaperPageFiles()

	local thumbWidth = 164
	local perRow = 3

	local rowChildren = {}

	for i, filename in ipairs(pageFiles) do
		table.insert(rowChildren, wallpaperThumbnail(filename, thumbWidth))

		if #rowChildren == perRow or i == #pageFiles then
			table.insert(
				children,

				ui.row({
					gap = 8,
				}, rowChildren)
			)

			rowChildren = {}
		end
	end

	return ui.column({
		gap = 8,
	}, children)
end

local function wallpaperPager()
	clampWallpaperPage()

	local pages = wallpaperPageCount()

	local total = #wallpaperFiles

	local startIndex = 0
	local endIndex = 0

	if total > 0 then
		startIndex = (wallpaperPage - 1) * wallpaperPageSize + 1

		endIndex = math.min(wallpaperPage * wallpaperPageSize, total)
	end

	return ui.row({
		justify = "space_between",

		align = "center",

		gap = 8,
	}, {
		ui.button({
			text = noctalia.tr("common.previous"),

			glyph = "chevron-left",

			variant = "ghost",

			controlSize = "sm",

			enabled = wallpaperPage > 1,

			onClick = function()
				if wallpaperPage > 1 then
					wallpaperPage = wallpaperPage - 1

					render()
				end
			end,
		}),

		ui.column({
			gap = 1,
			align = "center",
		}, {
			ui.label({
				text = noctalia.tr("editor.page", {
					page = tostring(wallpaperPage),
					pages = tostring(pages),
				}),

				fontSize = 10,

				color = "on_surface_variant",
			}),

			ui.label({
				text = total > 0 and noctalia.tr("editor.range", {
					start = tostring(startIndex),
					["end"] = tostring(endIndex),
					total = tostring(total),
				}) or noctalia.tr("editor.zero_wallpapers"),

				fontSize = 9,

				color = "on_surface_variant",
			}),
		}),

		ui.button({
			text = noctalia.tr("common.next"),

			glyph = "chevron-right",

			variant = "ghost",

			controlSize = "sm",

			enabled = wallpaperPage < pages,

			onClick = function()
				if wallpaperPage < pages then
					wallpaperPage = wallpaperPage + 1

					render()
				end
			end,
		}),
	})
end

------------------------------------------------------------
-- Service interaction
------------------------------------------------------------

local function requestActivation(profile)
	noctalia.runAsync({
		"noctalia",
		"msg",
		"plugin",
		"m4sc/profile-switcher:service",
		"all",
		"activate",
		profile.id,
	})
end

------------------------------------------------------------
-- Navigation
------------------------------------------------------------

local function backToSelector()
	panel.close()

	noctalia.togglePanel("m4sc/profile-switcher:panel")
end

------------------------------------------------------------
-- Save
------------------------------------------------------------

local function saveEdit(applyAfter)
	if not editProfile then
		return
	end

	if isNewProfile then
		if not validProfileId(newProfileId) then
			noctalia.notifyError(noctalia.tr("common.plugin_name"), noctalia.tr("error.profile_id_invalid"))
			return
		end

		if profiles.exists(newProfileId) then
			noctalia.notifyError(
				noctalia.tr("common.plugin_name"),
				noctalia.tr("error.profile_exists", { id = newProfileId })
			)
			return
		end

		editProfile.id = newProfileId

		editProfile.filename = newProfileId .. ".toml"
	end

	local ok, err = profiles.save(editProfile)

	if not ok then
		noctalia.notifyError(
			noctalia.tr("common.plugin_name"),
			noctalia.tr("error.save_profile", { error = tostring(err) })
		)
		return
	end

	noctalia.notify(
		noctalia.tr("common.plugin_name"),
		noctalia.tr(isNewProfile and "message.created" or "message.saved", { name = tostring(editProfile.name) })
	)

	if applyAfter then
		requestActivation(editProfile)
	end

	backToSelector()
end

------------------------------------------------------------
-- Schedule helpers
------------------------------------------------------------

local function containsDay(days, day)
	for _, value in ipairs(days or {}) do
		if value == day then
			return true
		end
	end

	return false
end

local function toggleDay(day)
	if not editProfile then
		return
	end

	local result = {}
	local removed = false

	for _, value in ipairs(editProfile.schedule.days) do
		if value == day then
			removed = true
		else
			table.insert(result, value)
		end
	end

	if not removed then
		table.insert(result, day)
		table.sort(result)
	end

	editProfile.schedule.days = result

	render()
end

------------------------------------------------------------
-- Monitor helpers
------------------------------------------------------------

local function sortedMonitorKeys()
	local result = {}

	if not editProfile or not editProfile.wallpapers or not editProfile.wallpapers.monitors then
		return result
	end

	for connector, _ in pairs(editProfile.wallpapers.monitors) do
		table.insert(result, connector)
	end

	table.sort(result)

	return result
end

local function addMonitor()
	if not editProfile then
		return
	end

	if newMonitorConnector == "" then
		noctalia.notifyError(noctalia.tr("common.plugin_name"), noctalia.tr("error.connector_empty"))

		return
	end

	if not editProfile.wallpapers.monitors[newMonitorConnector] then
		editProfile.wallpapers.monitors[newMonitorConnector] = ""
	end

	wallpaperTarget = newMonitorConnector

	newMonitorConnector = ""

	editRevision = editRevision + 1

	render()
end

local function removeMonitor(connector)
	if not editProfile then
		return
	end

	editProfile.wallpapers.monitors[connector] = nil

	if wallpaperTarget == connector then
		wallpaperTarget = "default"
	end

	render()
end

------------------------------------------------------------
-- UI helpers
------------------------------------------------------------

local function sectionTitle(text)
	return ui.label({
		text = text,

		fontSize = 12,
		fontWeight = "bold",

		color = "on_surface_variant",
	})
end

local function field(label, control)
	return ui.column({
		gap = 5,
	}, {
		ui.label({
			text = label,

			fontSize = 11,

			color = "on_surface_variant",
		}),

		control,
	})
end

local function paletteSourceButton(p, source, label)
	return ui.button({
		text = label,

		flexGrow = 1,

		controlSize = "sm",

		variant = p.palette.source == source and "primary" or "default",

		onClick = function()
			p.palette.source = source

			if source == "builtin" then
				if not containsValue(builtinPalettes, p.palette.name) then
					p.palette.name = "Noctalia"
				end
			elseif source == "wallpaper" then
				if not containsValue(wallpaperSchemes, p.palette.name) then
					p.palette.name = "m3-content"
				end
			elseif source == "community" then
				loadCommunityPalettes()
			elseif source == "custom" then
				loadCustomPalettes()
			end

			editRevision = editRevision + 1

			render()
		end,
	})
end

------------------------------------------------------------
-- Missing profile
------------------------------------------------------------

local function renderMissing()
	panel.render(ui.column({
		height = 684,

		padding = 18,
		gap = 12,
	}, {
		ui.label({
			text = noctalia.tr("editor.no_profile_selected"),

			fontSize = 18,

			fontWeight = "bold",
		}),

		ui.label({
			text = noctalia.tr("editor.open_from_selector"),

			color = "on_surface_variant",
		}),

		ui.button({
			text = noctalia.tr("editor.back_to_profiles"),

			onClick = function()
				backToSelector()
			end,
		}),
	}))
end

------------------------------------------------------------
-- Main editor
------------------------------------------------------------

function render()
	if not editProfile then
		renderMissing()

		return
	end

	local p = editProfile

	local rev = tostring(editRevision)

	local body = {}

	--------------------------------------------------------
	-- GENERAL
	--------------------------------------------------------

	table.insert(body, sectionTitle(noctalia.tr("editor.general")))

	if isNewProfile then
		table.insert(
			body,

			field(
				noctalia.tr("editor.profile_id"),

				ui.input({
					key = "profile-id-" .. rev,

					value = newProfileId,

					placeholder = noctalia.tr("editor.profile_id_placeholder"),

					onChange = function(value)
						newProfileId = value
					end,
				})
			)
		)

		table.insert(
			body,

			ui.label({
				text = noctalia.tr("editor.filename", {
					id = newProfileId ~= "" and newProfileId or "<id>",
				}),

				fontSize = 9,
				color = "on_surface_variant",
			})
		)
	end

	table.insert(
		body,

		field(
			noctalia.tr("editor.name"),

			ui.input({
				key = "name-" .. rev,

				value = p.name,

				placeholder = noctalia.tr("editor.profile_name_placeholder"),

				onChange = function(value)
					p.name = value
				end,
			})
		)
	)

	--------------------------------------------------------
	-- THEME MODE
	--------------------------------------------------------

	table.insert(body, sectionTitle(noctalia.tr("editor.theme_mode")))

	table.insert(
		body,

		ui.row({
			gap = 8,
		}, {
			ui.button({
				text = noctalia.tr("editor.dark"),

				flexGrow = 1,

				variant = p.theme_mode == "dark" and "primary" or "default",

				onClick = function()
					p.theme_mode = "dark"

					render()
				end,
			}),

			ui.button({
				text = noctalia.tr("editor.light"),

				flexGrow = 1,

				variant = p.theme_mode == "light" and "primary" or "default",

				onClick = function()
					p.theme_mode = "light"

					render()
				end,
			}),

			ui.button({
				text = noctalia.tr("editor.auto"),

				flexGrow = 1,

				variant = p.theme_mode == "auto" and "primary" or "default",

				onClick = function()
					p.theme_mode = "auto"

					render()
				end,
			}),
		})
	)

	--------------------------------------------------------
	-- PALETTE
	--------------------------------------------------------

	table.insert(body, sectionTitle(noctalia.tr("editor.palette")))

	table.insert(
		body,

		ui.row({
			gap = 6,
		}, {
			paletteSourceButton(p, "builtin", noctalia.tr("editor.builtin")),

			paletteSourceButton(p, "wallpaper", noctalia.tr("editor.wallpaper")),

			paletteSourceButton(p, "community", noctalia.tr("editor.community")),

			paletteSourceButton(p, "custom", noctalia.tr("editor.custom")),
		})
	)

	if p.palette.source == "builtin" then
		table.insert(
			body,

			field(
				noctalia.tr("editor.builtin_palette"),

				ui.select({
					key = "builtin-palette-" .. rev,

					options = builtinPalettes,

					selectedIndex = selectedIndex(builtinPalettes, p.palette.name),

					placeholder = noctalia.tr("editor.select_palette"),

					onChange = function(index)
						local i = tonumber(index) + 1

						if builtinPalettes[i] then
							p.palette.name = builtinPalettes[i]

							editRevision = editRevision + 1

							render()
						end
					end,
				})
			)
		)
	elseif p.palette.source == "wallpaper" then
		table.insert(
			body,

			field(
				noctalia.tr("editor.wallpaper_scheme"),

				ui.select({
					key = "wallpaper-scheme-" .. rev,

					options = wallpaperSchemes,

					selectedIndex = selectedIndex(wallpaperSchemes, p.palette.name),

					placeholder = noctalia.tr("editor.select_scheme"),

					onChange = function(index)
						local i = tonumber(index) + 1

						if wallpaperSchemes[i] then
							p.palette.name = wallpaperSchemes[i]

							editRevision = editRevision + 1

							render()
						end
					end,
				})
			)
		)
	elseif p.palette.source == "community" then
		if communityLoaded and #communityPalettes > 0 then
			table.insert(
				body,

				field(
					noctalia.tr("editor.community_palette"),

					ui.select({
						key = "community-palette-" .. rev,

						options = communityPalettes,

						selectedIndex = selectedIndex(communityPalettes, p.palette.name),

						placeholder = noctalia.tr("editor.select_community_palette"),

						onChange = function(index)
							local i = tonumber(index) + 1

							if communityPalettes[i] then
								p.palette.name = communityPalettes[i]

								editRevision = editRevision + 1

								render()
							end
						end,
					})
				)
			)

			table.insert(
				body,

				ui.row({
					justify = "space_between",

					align = "center",

					gap = 8,
				}, {
					ui.label({
						text = noctalia.tr("editor.palettes_loaded", {
							count = tostring(#communityPalettes),
						}),

						fontSize = 10,

						color = "on_surface_variant",
					}),

					ui.button({
						text = noctalia.tr("common.refresh"),

						glyph = "refresh",

						variant = "ghost",

						controlSize = "sm",

						onClick = function()
							communityLoaded = false

							loadCommunityPalettes()

							render()
						end,
					}),
				})
			)
		else
			table.insert(
				body,

				ui.row({
					align = "center",

					gap = 8,
				}, {
					ui.label({
						text = communityLoading and noctalia.tr("editor.loading_community_palettes")
							or (
								communityError
									and (noctalia.tr("editor.could_not_load_palettes", {
										error = communityError,
									}))
								or noctalia.tr("editor.community_palettes_not_loaded")
							),

						flexGrow = 1,

						fontSize = 11,

						color = communityError and "error" or "on_surface_variant",
					}),

					ui.button({
						text = communityLoading and noctalia.tr("common.loading") or noctalia.tr("common.load"),

						glyph = "refresh",

						variant = "secondary",

						controlSize = "sm",

						enabled = not communityLoading,

						onClick = function()
							loadCommunityPalettes()
							render()
						end,
					}),
				})
			)

			if p.palette.name and p.palette.name ~= "" then
				table.insert(
					body,

					field(
						noctalia.tr("editor.current_community_palette"),

						ui.input({
							key = "community-current-" .. rev,

							value = p.palette.name,

							placeholder = noctalia.tr("editor.community_palette_id"),

							onChange = function(value)
								p.palette.name = value
							end,
						})
					)
				)
			end
		end
	elseif p.palette.source == "custom" then
		if #customPalettes > 0 then
			table.insert(
				body,

				field(
					noctalia.tr("editor.custom_palette"),

					ui.select({
						key = "custom-palette-" .. rev,

						options = customPalettes,

						selectedIndex = selectedIndex(customPalettes, p.palette.name),

						placeholder = noctalia.tr("editor.select_custom_palette"),

						onChange = function(index)
							local i = tonumber(index) + 1

							if customPalettes[i] then
								p.palette.name = customPalettes[i]

								editRevision = editRevision + 1

								render()
							end
						end,
					})
				)
			)

			table.insert(
				body,

				ui.row({
					justify = "space_between",

					align = "center",

					gap = 8,
				}, {
					ui.label({
						text = "~/.config/noctalia/palettes",

						fontSize = 10,

						color = "on_surface_variant",
					}),

					ui.button({
						text = noctalia.tr("common.refresh"),

						glyph = "refresh",

						variant = "ghost",

						controlSize = "sm",

						onClick = function()
							loadCustomPalettes()
							render()
						end,
					}),
				})
			)
		else
			table.insert(
				body,

				ui.label({
					text = noctalia.tr("editor.no_custom_palettes"),

					fontSize = 11,

					color = "on_surface_variant",
				})
			)
		end
	end

	--------------------------------------------------------
	-- WALLPAPER BROWSER
	--------------------------------------------------------

	table.insert(body, sectionTitle(noctalia.tr("editor.wallpaper_section")))

	table.insert(
		body,

		ui.column({
			gap = 6,
		}, {
			ui.label({
				text = noctalia.tr("editor.wallpaper_directory"),

				fontSize = 11,

				color = "on_surface_variant",
			}),

			ui.row({
				gap = 8,
			}, {
				ui.input({
					key = "wallpaper-directory-" .. rev,

					value = p.wallpapers.directory,

					placeholder = noctalia.tr("editor.wallpaper_directory_placeholder"),

					flexGrow = 1,

					onChange = function(value)
						p.wallpapers.directory = value
					end,

					onSubmit = function(value)
						p.wallpapers.directory = value

						scanWallpapers()

						editRevision = editRevision + 1

						render()
					end,
				}),

				ui.button({
					text = noctalia.tr("editor.scan"),

					glyph = "refresh",

					variant = "secondary",

					controlSize = "md",

					onClick = function()
						scanWallpapers()
						render()
					end,
				}),
			}),
		})
	)

	--------------------------------------------------------
	-- Wallpaper target
	--------------------------------------------------------

	local targetButtons = {
		wallpaperTargetButton("default", noctalia.tr("editor.default")),
	}

	for _, connector in ipairs(sortedMonitorKeys()) do
		table.insert(targetButtons, wallpaperTargetButton(connector, connector))
	end

	table.insert(
		body,

		ui.row({
			gap = 6,
		}, targetButtons)
	)

	--------------------------------------------------------
	-- Selected wallpaper preview
	--------------------------------------------------------

	local selectedPath = currentWallpaperPath()

	table.insert(
		body,

		ui.column({
			gap = 7,
		}, {
			ui.row({
				justify = "space_between",

				align = "center",

				gap = 8,
			}, {
				ui.label({
					text = wallpaperTarget == "default" and noctalia.tr("editor.default_wallpaper")
						or (noctalia.tr("editor.wallpaper_for_monitor", {
							monitor = wallpaperTarget,
						})),

					fontSize = 11,

					fontWeight = "semibold",
				}),

				ui.label({
					text = basename(selectedPath),

					fontSize = 10,

					maxWidth = 300,

					maxLines = 1,

					color = "on_surface_variant",
				}),
			}),

			wallpaperPreview(selectedPath),
		})
	)

	--------------------------------------------------------
	-- Gallery
	--------------------------------------------------------

	table.insert(
		body,

		ui.row({
			justify = "space_between",

			align = "center",

			gap = 8,
		}, {
			ui.label({
				text = noctalia.tr("editor.wallpaper_count", {
					count = tostring(#wallpaperFiles),
				}),

				fontSize = 10,

				color = "on_surface_variant",
			}),

			ui.button({
				text = noctalia.tr("common.refresh"),

				glyph = "refresh",

				variant = "ghost",

				controlSize = "sm",

				onClick = function()
					scanWallpapers()
					render()
				end,
			}),
		})
	)

	table.insert(body, wallpaperGallery())

	table.insert(body, wallpaperPager())

	--------------------------------------------------------
	-- Add/remove monitor override
	--------------------------------------------------------

	table.insert(
		body,

		ui.column({
			gap = 7,

			padding = 10,

			fill = "surface_variant/0.20",

			radius = 10,
		}, {
			ui.label({
				text = noctalia.tr("editor.add_monitor_override"),

				fontSize = 11,

				color = "on_surface_variant",
			}),

			ui.row({
				gap = 8,
			}, {
				ui.input({
					key = "new-monitor-connector-" .. rev,

					value = newMonitorConnector,

					placeholder = noctalia.tr("editor.connector_placeholder"),

					flexGrow = 1,

					onChange = function(value)
						newMonitorConnector = value
					end,
				}),

				ui.button({
					text = noctalia.tr("common.add"),

					glyph = "plus",

					variant = "secondary",

					onClick = function()
						addMonitor()
					end,
				}),
			}),
		})
	)

	local monitorKeys = sortedMonitorKeys()

	if #monitorKeys > 0 then
		local removeButtons = {}

		for _, connector in ipairs(monitorKeys) do
			local connectorCopy = connector

			table.insert(
				removeButtons,

				ui.button({
					text = noctalia.tr("editor.remove_monitor", { monitor = connectorCopy }),

					glyph = "trash",

					variant = "ghost",

					controlSize = "sm",

					onClick = function()
						removeMonitor(connectorCopy)
					end,
				})
			)
		end

		table.insert(
			body,

			ui.row({
				gap = 6,
			}, removeButtons)
		)
	end

	--------------------------------------------------------
	-- SCHEDULE
	--------------------------------------------------------

	table.insert(body, sectionTitle(noctalia.tr("editor.schedule")))

	--------------------------------------------------------
	-- Schedule mode
	--------------------------------------------------------

	table.insert(
		body,

		ui.row({
			gap = 8,
		}, {
			ui.button({
				text = noctalia.tr("editor.automatic"),

				flexGrow = 1,

				glyph = "clock",

				variant = p.schedule.enabled and "primary" or "default",

				onClick = function()
					p.schedule.enabled = true

					editRevision = editRevision + 1

					render()
				end,
			}),

			ui.button({
				text = noctalia.tr("editor.manual"),

				flexGrow = 1,

				glyph = "hand-stop",

				variant = not p.schedule.enabled and "primary" or "default",

				onClick = function()
					p.schedule.enabled = false

					editRevision = editRevision + 1

					render()
				end,
			}),
		})
	)

	if not p.schedule.enabled then
		table.insert(
			body,

			ui.column({
				gap = 6,

				padding = 12,

				fill = "surface_variant/0.20",

				radius = 10,
			}, {
				ui.row({
					gap = 8,
					align = "center",
				}, {
					ui.glyph({
						name = "hand-stop",

						size = 18,

						color = "on_surface_variant",
					}),

					ui.column({
						gap = 2,
						flexGrow = 1,
					}, {
						ui.label({
							text = noctalia.tr("editor.manual_profile"),

							fontSize = 12,

							fontWeight = "semibold",
						}),

						ui.label({
							text = noctalia.tr("editor.manual_description"),

							fontSize = 10,

							color = "on_surface_variant",
						}),
					}),
				}),
			})
		)
	else
		--------------------------------------------------------
		-- Automatic schedule times
		--------------------------------------------------------

		table.insert(
			body,

			ui.row({
				gap = 10,
				align = "end",
			}, {
				field(
					noctalia.tr("editor.from"),

					ui.input({
						key = "schedule-from-" .. rev,

						value = p.schedule.from,

						placeholder = "08:30",

						width = 140,

						onChange = function(value)
							p.schedule.from = value
						end,
					})
				),

				field(
					noctalia.tr("editor.until"),

					ui.input({
						key = "schedule-until-" .. rev,

						value = p.schedule["until"],

						placeholder = "16:30",

						width = 140,

						onChange = function(value)
							p.schedule["until"] = value
						end,
					})
				),
			})
		)

		--------------------------------------------------------
		-- Automatic schedule weekdays
		--------------------------------------------------------

		local dayNames = {
			noctalia.tr("editor.monday"),
			noctalia.tr("editor.tuesday"),
			noctalia.tr("editor.wednesday"),
			noctalia.tr("editor.thursday"),
			noctalia.tr("editor.friday"),
			noctalia.tr("editor.saturday"),
			noctalia.tr("editor.sunday"),
		}

		local dayButtons = {}

		for day = 1, 7 do
			local dayCopy = day

			table.insert(
				dayButtons,

				ui.button({
					key = "day-" .. tostring(dayCopy),

					text = dayNames[dayCopy],

					flexGrow = 1,

					controlSize = "sm",

					variant = containsDay(p.schedule.days, dayCopy) and "primary" or "default",

					onClick = function()
						toggleDay(dayCopy)
					end,
				})
			)
		end

		table.insert(
			body,

			ui.row({
				gap = 5,
			}, dayButtons)
		)
	end

	--------------------------------------------------------
	-- Panel
	--------------------------------------------------------

	panel.render(ui.column({
		height = 684,

		padding = 18,
		gap = 10,
	}, {
		ui.row({
			align = "center",
			gap = 10,
		}, {
			ui.button({
				glyph = "arrow-left",

				variant = "ghost",

				controlSize = "sm",

				onClick = function()
					backToSelector()
				end,
			}),

			ui.column({
				gap = 1,
				flexGrow = 1,
			}, {
				ui.label({
					text = isNewProfile and noctalia.tr("editor.new_profile")
						or noctalia.tr("editor.edit_profile", { name = p.name }),

					fontSize = 18,

					fontWeight = "bold",
				}),

				ui.label({
					text = isNewProfile and (noctalia.tr("editor.filename", {
						id = newProfileId ~= "" and newProfileId or "<id>",
					})) or ("~/.config/noctalia/profiles/" .. p.id .. ".toml"),

					fontSize = 10,

					color = "on_surface_variant",
				}),
			}),

			ui.button({
				glyph = "x",

				variant = "ghost",

				controlSize = "sm",

				onClick = function()
					panel.close()
				end,
			}),
		}),

		ui.separator({
			spacing = 2,

			color = "outline/0.22",
		}),

		ui.scroll({
			flexGrow = 1,

			gap = 14,

			paddingV = 4,
		}, body),

		ui.separator({
			spacing = 0,

			color = "outline/0.22",
		}),

		ui.row({
			justify = "end",

			align = "center",

			gap = 8,

			paddingV = 2,
		}, {
			ui.button({
				text = noctalia.tr("common.cancel"),

				variant = "ghost",

				controlSize = "sm",

				onClick = function()
					backToSelector()
				end,
			}),

			ui.button({
				text = isNewProfile and noctalia.tr("common.create") or noctalia.tr("common.save"),

				variant = "secondary",

				controlSize = "sm",

				onClick = function()
					saveEdit(false)
				end,
			}),

			ui.button({
				text = isNewProfile and noctalia.tr("editor.create_apply") or noctalia.tr("editor.save_apply"),

				glyph = "check",

				variant = "primary",

				controlSize = "sm",

				onClick = function()
					saveEdit(true)
				end,
			}),
		}),
	}))
end

------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------

function onOpen(_context)
	local id = noctalia.state.get("editProfileId")

	editProfile = nil
	isNewProfile = false
	newProfileId = ""

	if id == "__new__" then
		editProfile = newProfileTemplate()

		isNewProfile = true

		editRevision = editRevision + 1
	elseif id then
		local profile = profiles.find(id)

		if profile then
			editProfile = cloneProfile(profile)

			editRevision = editRevision + 1
		end
	end

	newMonitorConnector = ""

	wallpaperFiles = {}
	wallpaperScanError = nil
	wallpaperTarget = "default"
	wallpaperPage = 1

	loadCustomPalettes()

	if editProfile then
		if not isNewProfile then
			scanWallpapers()
		end

		if editProfile.palette.source == "community" then
			loadCommunityPalettes()
		end
	end

	render()
end
