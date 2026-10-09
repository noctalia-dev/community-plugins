local theme = require("../../utils/theme.luau")
local state = require("../state.luau")
local request = require("../actions.luau")
local rerender = require("../rerender.luau")
local auth_comp = require("./auth.luau")

local CACHES = {
	{
		id = "downloads",
		name = "Downloaded songs",
		desc = "Explicitly saved tracks and fully downloaded playlists.",
	},
	{ id = "cached_audio", name = "Cached audio", desc = "Songs auto-cached during playback." },
	{ id = "streams", name = "Stream URLs", desc = "Cached streaming URLs to speed up playback." },
	{ id = "thumbnails", name = "Thumbnails", desc = "Cached album and video thumbnail images." },
	{ id = "playlists", name = "Playlists", desc = "Cached library playlists and metadata." },
}

local function spacer(height)
	return ui.row({ key = "spacer-set-" .. tostring(height), height = height, borderWidth = 0, radius = theme.radius })
end

local function build_cache_tab()
	local is_refreshing = (state.data.refreshing_cache_stats == true)
	local rows = {
		ui.row({ key = "set-cache-head", align = "center", justify = "space_between", radius = theme.radius }, {
			ui.label({
				text = "ON DISK",
				fontSize = theme.fontHeading,
				fontWeight = "bold",
				color = "on_surface_variant",
			}),
			ui.button({
				key = "btn-refresh-cache-stats",
				glyph = is_refreshing and "loader" or "refresh",
				variant = "ghost",
				controlSize = "sm",
				tooltip = is_refreshing and "Refreshing cache stats..." or "Refresh cache stats",
				onClick = is_refreshing and nil or function()
					request("fetch_cache_stats")
				end,
			}),
		}),
	}
	for _, c in ipairs(CACHES) do
		local size = state.data.cache_stats and state.data.cache_stats[c.id] or "0"
		table.insert(
			rows,
			ui.row({
				key = "cache-" .. c.id,
				gap = 14,
				align = "center",
				justify = "space_between",
				padding = 8,
				borderWidth = 0,
				radius = theme.radius,
			}, {
				ui.column({ gap = 2, flexGrow = 1, radius = theme.radius }, {
					ui.label({ text = c.name, fontSize = theme.fontTitle, color = "on_surface" }),
					ui.label({ text = c.desc, fontSize = theme.fontTitle, color = "on_surface_variant" }),
				}),
				ui.row({ gap = 16, align = "center", radius = theme.radius }, {
					ui.label({ text = size, fontSize = theme.fontBody, color = "on_surface_variant" }),
					ui.button({
						text = "Clear",
						variant = "outline",
						controlSize = "sm",
						onClick = function()
							request("clear_cache", { target = c.id })
						end,
					}),
				}),
			})
		)
	end

	return ui.column({ key = "set-cache-list", gap = 8, radius = theme.radius }, rows)
end

local function build_tabs(tab)
	local tabs = {
		{ id = "cache", label = "Storage" },
		{ id = "login", label = "Login" },
		{ id = "health", label = "Health" },
	}

	local elems = {}
	for _, t in ipairs(tabs) do
		local active = (tab == t.id)
		table.insert(
			elems,
			ui.button({
				key = "set-tab-" .. t.id,
				text = t.label,
				variant = active and "primary" or "outline",
				controlSize = "sm",
				onClick = function()
					state.view.settings_tab = t.id
					rerender.call()
				end,
			})
		)
	end
	return ui.row({ key = "set-tabs-row", align = "center", gap = 8, radius = theme.radius }, elems)
end

local function build_settings()
	local items = {}
	local tab = state.view.settings_tab or "cache"

	table.insert(
		items,
		ui.row(
			{ key = "set-head", borderWidth = 0, align = "center", justify = "space_between", radius = theme.radius },
			{
				ui.label({ text = "SETTINGS", fontSize = theme.fontHero, fontWeight = "bold" }),
				ui.button({
					text = "Plugin settings",
					glyph = "settings",
					variant = "outline",
					controlSize = "sm",
					onClick = function()
						noctalia.openSettings("aabidk20/yt-music")
					end,
				}),
			}
		)
	)
	table.insert(items, spacer(8))
	table.insert(items, build_tabs(tab))
	table.insert(items, spacer(8))

	if tab == "cache" then
		table.insert(items, build_cache_tab())
	elseif tab == "login" then
		for _, item in ipairs(auth_comp.build_cookies_page()) do
			table.insert(items, item)
		end
	elseif tab == "health" then
		for _, item in ipairs(auth_comp.build_health_page()) do
			table.insert(items, item)
		end
	end

	return items
end

return { build = build_settings }
