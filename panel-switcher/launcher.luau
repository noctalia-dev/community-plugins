--!nonstrict

-- Launcher provider: lists every registeredpanel id, built-in or plugin,
-- and toggles whichever one is picked.
--
-- Discovery probes `noctalia msg panel-toggle <bogus-id>` via runAsync() (off
-- the IPC thread, so it can't deadlock the way a synchronous dmenu command
-- would) and parses the resulting "unknown panel" error for the real id list.
-- Ids are decorated with the owning plugin's name/icon, read from its
-- plugin.toml since raw ids ("author/plugin:entry") aren't user-friendly.
-- Activation toggles the panel in-process, except a control-center tab
-- (CONTROL_CENTER_TABS below), which has no in-process way to pass its
-- context and so shells out the same off-thread way discovery does.

local PROBE_ID = "__panel_switcher_probe__"
local MAX_RESULTS = 50

-- Built-in panels ship in Noctalia's core, not a plugin, so they have no
-- plugin.toml to read a name/icon from. This is the full, stable set from
-- the "unknown panel" error's id list; update it if Noctalia adds one.
local BUILTIN_PANELS = {
	clipboard = { name = "Clipboard", glyph = "clipboard" },
	["control-center"] = { name = "Control Center", glyph = "adjustments" },
	launcher = { name = "Launcher", glyph = "search" },
	polkit = { name = "Authentication Prompt", glyph = "shield-lock" },
	session = { name = "Session", glyph = "power" },
	["setup-wizard"] = { name = "Setup Wizard", glyph = "wand" },
	test = { name = "Test Panel", glyph = "bug" },
	["tray-drawer"] = { name = "Tray Drawer", glyph = "apps" },
	wallpaper = { name = "Wallpaper", glyph = "photo" },
}

local DEFAULT_GLYPH = "layout-bottombar"

-- Control-center's sub-tabs, keyed by the context string its IPC accepts
-- (`noctalia msg panel-toggle control-center <key>`), from
-- control_center_panel.h's kTabs table ("home" skipped: the plain Control
-- Center row already opens to it). Each tab's `setting` is its own show/hide
-- toggle, gated behind the master "show_cc_tabs" setting.
local CONTROL_CENTER_TABS = {
	{ key = "media", title = "Media", glyph = "disc-filled", setting = "show_tab_media" },
	{ key = "audio", title = "Audio", glyph = "volume", setting = "show_tab_audio" },
	{ key = "monitor", title = "Monitor", glyph = "device-desktop", setting = "show_tab_monitor" },
	{ key = "system", title = "System", glyph = "activity-heartbeat", setting = "show_tab_system" },
	{ key = "power", title = "Power", glyph = "battery-charging-2", setting = "show_tab_power" },
	{ key = "network", title = "Network", glyph = "wifi", setting = "show_tab_network" },
	{ key = "bluetooth", title = "Bluetooth", glyph = "bluetooth", setting = "show_tab_bluetooth" },
	{ key = "weather", title = "Weather", glyph = "weather-cloud-sun", setting = "show_tab_weather" },
	{ key = "calendar", title = "Calendar", glyph = "calendar-event", setting = "show_tab_calendar" },
	{ key = "notifications", title = "Notifications", glyph = "bell", setting = "show_tab_notifications" },
	{ key = "screen-time", title = "Screen Time", glyph = "hourglass", setting = "show_tab_screen_time" },
}

-- Synthetic ids for control-center tabs never collide with a real panel id:
-- every real plugin entry id has a "/" before its ":" ("author/plugin:entry"),
-- and no built-in id contains a colon at all.
local CC_TAB_PREFIX = "cc-tab:"

local cachedIds = nil
local fetchInFlight = false
local pluginSources = nil -- lazily loaded from noctalia.getSetting("plugins.source")
local pluginMetaCache = {} -- "author/plugin" -> { name, icon } | false (looked up, not found)

local function trim(s)
	return noctalia.string.trim(s or "")
end

local function statusRow(title, subtitle, glyph)
	return { id = "", title = title, subtitle = subtitle, glyph = glyph }
end

-- Pulls the comma-separated id list out of the probe's "available: a, b, c)"
-- error text; nil if the reply didn't match that shape.
local function parseAvailableIds(stdout)
	local list = stdout and stdout:match("available:%s*(.-)%s*%)")
	if not list then
		return nil
	end

	local ids = {}
	for id in list:gmatch("[^,]+") do
		id = trim(id)
		if id ~= "" then
			table.insert(ids, id)
		end
	end
	return ids
end

-- "~/.local/state" (or wherever NOCTALIA_STATE_HOME/XDG_STATE_HOME point), with
-- the noctalia subdirectory already appended.
local function noctaliaStateHome()
	local base = noctalia.getenv("NOCTALIA_STATE_HOME")
	if not base or base == "" then
		base = noctalia.getenv("XDG_STATE_HOME")
	end
	if base and base ~= "" then
		return noctalia.expandPath(base .. "/noctalia")
	end
	return noctalia.expandPath("~/.local/state/noctalia")
end

-- "~/.local/share/noctalia", same resolution as above but for hand-placed
-- local plugins (noctalia.getenv("NOCTALIA_DATA_HOME") / XDG_DATA_HOME).
local function noctaliaDataHome()
	local base = noctalia.getenv("NOCTALIA_DATA_HOME")
	if not base or base == "" then
		base = noctalia.getenv("XDG_DATA_HOME")
	end
	if base and base ~= "" then
		return noctalia.expandPath(base .. "/noctalia")
	end
	return noctalia.expandPath("~/.local/share/noctalia")
end

-- Only the root-level `name`/`icon` string fields, never one from inside a
-- `[[panel]]`/`[[setting]]` etc. block further down the file.
local function parseManifestNameIcon(path)
	local content = noctalia.readFile(path)
	if type(content) ~= "string" or content == "" then
		return nil
	end

	local name, icon
	for line in content:gmatch("[^\r\n]+") do
		if line:match("^%s*%[") then
			break
		end
		if not name then
			name = line:match('^%s*name%s*=%s*"(.-)"')
		end
		if not icon then
			icon = line:match('^%s*icon%s*=%s*"(.-)"')
		end
		if name and icon then
			break
		end
	end

	if not name then
		return nil
	end
	return { name = name, icon = icon }
end

-- Every location a plugin's files could live: a hand-placed local plugin, a
-- `path`-kind source, or a `git`-kind source's materialized export. The
-- subdir is the id's segment after "/", Noctalia's own convention.
local function manifestCandidates(pluginId)
	local subdir = pluginId:match("^[^/]+/(.+)$")
	if not subdir then
		return {}
	end

	local candidates = { noctaliaDataHome() .. "/plugins/" .. subdir .. "/plugin.toml" }

	if not pluginSources then
		local sources = noctalia.getSetting("plugins.source")
		pluginSources = type(sources) == "table" and sources or {}
	end

	for _, source in pluginSources do
		if source.kind == "path" and source.location and source.location ~= "" then
			table.insert(candidates, noctalia.expandPath(source.location) .. "/" .. subdir .. "/plugin.toml")
		elseif source.kind == "git" and source.name and source.name ~= "" then
			table.insert(
				candidates,
				noctaliaStateHome() .. "/plugins/materialized/" .. source.name .. "/" .. subdir .. "/plugin.toml"
			)
		end
	end

	return candidates
end

-- Looks up and caches a plugin's manifest name/icon; a cached `false` means
-- "already looked up, not found" so a miss isn't retried every query.
local function pluginMeta(pluginId)
	local cached = pluginMetaCache[pluginId]
	if cached ~= nil then
		return cached or nil
	end

	for _, path in manifestCandidates(pluginId) do
		if noctalia.fileExists(path) then
			local meta = parseManifestNameIcon(path)
			if meta then
				pluginMetaCache[pluginId] = meta
				return meta
			end
		end
	end

	pluginMetaCache[pluginId] = false
	return nil
end

-- { title, subtitle, glyph } for a raw panel id, resolved from BUILTIN_PANELS
-- or the owning plugin's manifest, falling back to the raw id untouched.
local function describe(id)
	local builtin = BUILTIN_PANELS[id]
	if builtin then
		return { title = builtin.name, subtitle = nil, glyph = builtin.glyph }
	end

	local pluginId, entryId = id:match("^(.-):(.+)$")
	if not pluginId then
		return { title = id, subtitle = nil, glyph = DEFAULT_GLYPH }
	end

	local meta = pluginMeta(pluginId)
	if meta then
		return { title = meta.name, subtitle = entryId, glyph = meta.icon or DEFAULT_GLYPH }
	end
	return { title = pluginId, subtitle = entryId, glyph = DEFAULT_GLYPH }
end

-- Expands panel ids into row-able entries: each id, plus a synthetic entry
-- per enabled control-center tab inserted right after "control-center"
-- itself.
local function buildEntries(ids)
	local entries = {}
	for _, id in ids do
		table.insert(entries, { id = id })
		if id == "control-center" and noctalia.getConfig("show_cc_tabs") then
			for _, tab in CONTROL_CENTER_TABS do
				if noctalia.getConfig(tab.setting) then
					table.insert(entries, {
						id = CC_TAB_PREFIX .. tab.key,
						title = tab.title,
						subtitle = "Control Center",
						glyph = tab.glyph,
					})
				end
			end
		end
	end
	return entries
end

local function describeEntry(entry)
	if entry.title then
		-- Already fully described (a control-center tab synthesized above).
		return entry
	end
	return describe(entry.id)
end

-- Builds display rows for ids, fuzzy-filtering by `filter` when non-empty;
-- an empty filter instead sorts alphabetically and caps at MAX_RESULTS.
local function makeRows(ids, filter)
	local rows = {}

	for _, entry in buildEntries(ids) do
		local info = describeEntry(entry)
		local haystack = info.title .. " " .. entry.id
		local score = filter == "" and nil or noctalia.fuzzyScore(filter, haystack)
		if filter == "" or score ~= nil then
			table.insert(rows, {
				id = entry.id,
				title = info.title,
				subtitle = info.subtitle,
				glyph = info.glyph,
				score = score,
			})
		end
	end

	if filter == "" then
		table.sort(rows, function(a, b)
			return a.title:lower() < b.title:lower()
		end)
		while #rows > MAX_RESULTS do
			table.remove(rows)
		end
	end

	return rows
end

-- Renders makeRows()'s output, or a "no panels found" status row if
-- filtering left nothing.
local function showResults(query, ids, filter)
	local rows = makeRows(ids, filter)
	if #rows == 0 then
		launcher.setResults(query, {
			statusRow(
				noctalia.tr("no-panels-found"),
				filter ~= "" and noctalia.tr("filter-empty", { filter = filter }) or nil,
				"layout-bottombar"
			),
		})
	else
		launcher.setResults(query, rows)
	end
end

-- Runs the discovery probe once and caches the resulting id list; onDone
-- fires after cachedIds is populated (possibly empty, on failure).
local function fetchIds(onDone)
	fetchInFlight = true
	noctalia.runAsync("noctalia msg panel-toggle " .. PROBE_ID, function(result)
		fetchInFlight = false
		cachedIds = parseAvailableIds(result.stdout) or {}
		onDone()
	end)
end

-- Serves cached results immediately; otherwise shows a loading row and kicks
-- off fetchIds, guarded by fetchInFlight so concurrent keystrokes don't start
-- a second probe.
function onQuery(query)
	local filter = trim(query)

	if cachedIds then
		showResults(query, cachedIds, filter)
		return
	end

	launcher.setResults(query, {
		statusRow(noctalia.tr("loading"), noctalia.tr("loading-subtitle"), "loader"),
	})

	if not fetchInFlight then
		fetchIds(function()
			if not cachedIds or #cachedIds == 0 then
				launcher.setResults(query, {
					statusRow(noctalia.tr("err-fetch-failed"), noctalia.tr("err-fetch-failed-subtitle"), "triangle-alert"),
				})
				return
			end
			showResults(query, cachedIds, filter)
		end)
	end
end

-- Routes a control-center tab id through the IPC shell-out; everything else
-- toggles in-process.
function onActivate(id)
	if id == "" then
		return
	end

	local tab = id:match("^cc%-tab:(.+)$")
	if tab then
		noctalia.runAsync("noctalia msg panel-toggle control-center " .. tab)
		return
	end

	noctalia.togglePanel(id)
end
