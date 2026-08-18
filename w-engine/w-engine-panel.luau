--!nonstrict
-- W-Engine panel — browse Wallpaper Engine Workshop items and hand one, or a
-- rotation of several, to the service.
--
-- This entry owns no processes and no timers; every action is published on
-- noctalia.state for start.luau to carry out.

local REQUEST_KEY = "w_engine_request"
local STATUS_KEY = "w_engine_status"

local WORKSHOP_PATHS = {
	"~/.steam/steam/steamapps/workshop/content/431960/",
	"~/.local/share/Steam/steamapps/workshop/content/431960/",
	"~/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/workshop/content/431960/",
	"~/snap/steam/common/.local/share/Steam/steamapps/workshop/content/431960/",
	"~/snap/steam/common/.local/share/steam/steamapps/workshop/content/431960/",
}

local ORDER_VALUES = { "sequential", "random" }

-- Panel size is fixed by plugin.toml, so grid density is configurable instead.
-- Tiles are sized from the width left over once gaps, frames and the scrollbar
-- are accounted for, which keeps the grid inside the panel at any column count.
local TILE_GAP = 12
local TILE_FRAME = 3 -- padding on each side of a preview, drawn as the selection frame
local GRID_WIDTH = 732 -- panel width from plugin.toml, less its insets and the scrollbar
local PREVIEW_RATIO = 5 / 9

local columns = 4
local previewWidth = 168
local previewHeight = 93

local workshopRoot = nil
local catalog = nil -- cached: the grid re-renders far more often than the disk changes
local catalogStamp = nil -- mtime of the Workshop dir the cache was built from

local isOpen = false
local outputName = nil
local multiSelect = false
local selected = {} -- ids, in the order they were picked
local minutesText = "15"
local order = "sequential"
local status = {}

-- Per-wallpaper configuration view.
local view = "grid" -- "grid" | "config" | "defaults"
local configId = nil
local configName = ""
local configProps = {}
local engineDraft = {} -- working copy of options[id].engine
local propsDraft = {}  -- working copy of options[id].properties
local showUnlabeled = false

-- Global defaults view.
local defaultsDraft = {} -- working copy of defaults.engine
local clearOverrides = false

type Wallpaper = {
	nb: string,
	name: string,
	path: string,
}

local thumbsRequested = false

-- Forward declaration: callbacks defined above the rendering section redraw
-- through this.
local render

local function asTable(value)
	return type(value) == "table" and value or {}
end

local function tr(key, subst)
	if subst then
		return noctalia.tr(key, subst)
	end
	return noctalia.tr(key)
end

-- Get All output for all fonctionnality --


-- ── Workshop discovery ───────────────────────────────────────────────────────

local function candidateRoots()
	local roots = {}
	for _, path in ipairs(WORKSHOP_PATHS) do
		table.insert(roots, path)
	end
	-- Extra roots live in the service's data.json (see README).
	local dir = noctalia.pluginDataDir()
	if dir then
		local raw = noctalia.readFile(dir .. "/data.json")
		if raw then
			local decoded = noctalia.json.decode(raw)
			if type(decoded) == "table" and type(decoded.personnalPath) == "table" then
				for _, path in ipairs(decoded.personnalPath) do
					if type(path) == "string" and path ~= "" then
						if not path:match("/$") then
							path = path .. "/"
						end
						table.insert(roots, path)
					end
				end
			end
		end
	end
	return roots
end

-- Cached static stills, one per wallpaper, kept beside the plugin's data.
local function thumbDir()
	local dir = noctalia.pluginDataDir()
	return dir and (dir .. "/thumbs") or nil
end

-- Builds every missing still in one pass, then redraws. Runs at most once per
-- script load; new subscriptions are picked up on the next reload.
local function requestThumbnails(thumbs)
	if not thumbs or thumbsRequested or not workshopRoot or not noctalia.commandExists("ffmpeg") then
		return
	end
	thumbsRequested = true
	local cmd = "mkdir -p '"
		.. thumbs
		.. "'; for d in '"
		.. noctalia.expandPath(workshopRoot)
		.. "'*/; do id=$(basename \"$d\"); [ -f '"
		.. thumbs
		.. "'/\"$id\".jpg ] && continue; p=$(ls \"$d\"preview.* 2>/dev/null | head -1); "
		.. "[ -n \"$p\" ] && ffmpeg -y -loglevel error -i \"$p\" -frames:v 1 "
		.. "-vf 'scale=360:200:force_original_aspect_ratio=increase,crop=360:200' -q:v 4 '"
		.. thumbs
		.. "'/\"$id\".jpg >/dev/null 2>&1; done; true"
	noctalia.runAsync(cmd, function()
		catalog = nil
		render()
	end, 60000)
end

local function loadCatalog(): { Wallpaper }
	local items = {}
	workshopRoot = nil
	-- Several stock locations can exist at once, and last match wins, so a
	-- personnalPath entry takes precedence.
	for _, path in ipairs(candidateRoots()) do
		if noctalia.listDir(path) then
			workshopRoot = path
		end
	end
	if not workshopRoot then
		noctalia.notify(tr("panel.title"), tr("panel.list_failed"))
		return items
	end

	local entries, err = noctalia.listDir(workshopRoot)
	if not entries then
		warn(err or "could not list the Workshop directory")
		noctalia.notify(tr("panel.title"), tr("panel.list_failed"))
		return items
	end

	local thumbs = thumbDir()
	local missing = false
	for _, entryName in entries do
		if tonumber(entryName) then -- Workshop items are numeric ids
			local content = noctalia.readFile(workshopRoot .. entryName .. "/project.json")
			if content then
				local value = noctalia.json.decode(content)
				if type(value) == "table" then
					-- Prefer the cached still: Workshop previews are often animated
					-- GIFs, which the grid would decode and animate for as long as
					-- the panel is open.
					local path = workshopRoot .. entryName .. "/" .. (value.preview or "preview.jpg")
					local thumb = thumbs and (thumbs .. "/" .. entryName .. ".jpg") or nil
					if thumb and noctalia.fileExists(thumb) then
						path = thumb
					else
						missing = true
					end
					table.insert(items, {
						nb = entryName,
						name = value.title or entryName,
						path = path,
					})
				end
			else
				noctalia.notify(tr("panel.title"), tr("panel.missing_project_json", { name = entryName }))
			end
		end
	end

	if missing then
		requestThumbnails(thumbs)
	end
	return items
end

-- ── Talking to the service ───────────────────────────────────────────────────

local seq = 0

local function send(payload)
	seq += 1
	-- The service ignores a repeated nonce, so it must differ across script
	-- reloads that reset the counter.
	payload.nonce = tostring(seq) .. ":" .. tostring(os.clock and os.clock() or 0)
	payload.output = outputName
	noctalia.state.set(REQUEST_KEY, payload)
end

local function outputStatus()
	local outputs = type(status) == "table" and status.outputs or nil
	if type(outputs) ~= "table" or not outputName then
		return {}
	end
	local entry = outputs[outputName]
	return type(entry) == "table" and entry or {}
end


local function hasStopState()		-- check for render stop button
	if outputName ~= "All" then
		local state = outputStatus()
		return state.current ~= nil or state.restorable == true
	end

	local outputs = type(status) == "table" and status.outputs or nil
	if type(outputs) ~= "table" then
		return false
	end

	for _, entry in pairs(outputs) do
		if type(entry) == "table" and (entry.current ~= nil or entry.restorable == true) then
			return true
		end
	end
	return false
end

local function storedDefaults()
	return asTable(asTable(status.defaults).engine)
end

-- ── Selection ────────────────────────────────────────────────────────────────

local function selectionIndex(id)
	for index, value in ipairs(selected) do
		if value == id then
			return index
		end
	end
	return nil
end

local function toggleSelection(id)
	local index = selectionIndex(id)
	if index then
		table.remove(selected, index)
	else
		table.insert(selected, id)
	end
	send({ action = "select", ids = selected })
end

-- ── Wallpaper properties ─────────────────────────────────────────────────────
--
-- Every Workshop item declares its own settings in project.json under
-- general.properties: a name -> { type, text, value, ... } map. `type` selects
-- the control and `condition` gates its visibility, so the form differs per
-- wallpaper.

-- Types whose value is a path into the wallpaper's own asset tree. These are
-- left at their defaults.
local PROPERTY_SKIP = { file = true, directory = true, scenetexture = true }

local HTML_ENTITIES = {
	["&nbsp;"] = " ",
	["&amp;"] = "&",
	["&lt;"] = "<",
	["&gt;"] = ">",
	["&quot;"] = '"',
	["&apos;"] = "'",
	["&#39;"] = "'",
}

-- Property labels are authored as HTML: <br> separates a translated label from
-- its English counterpart, and some carry <img>, <a> or <center> blocks for
-- decoration. Reduce all of it to plain text.
local function cleanLabel(text)
	local label = tostring(text or "")
	label = label:gsub("<%s*[Bb][Rr]%s*/?%s*>", " ")
	label = label:gsub("<[^>]*>", "")
	for entity, character in pairs(HTML_ENTITIES) do
		label = label:gsub(entity, character)
	end
	label = label:gsub("\\[nrt]", " ") -- literal escape sequences, not whitespace
	label = label:gsub("%s+", " ")
	label = label:gsub("^%-+", "") -- authors prefix dashes to fake indentation
	return (label:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function loadProperties(id)
	local raw = noctalia.readFile(workshopRoot .. id .. "/project.json")
	if not raw then
		return {}
	end
	local decoded = noctalia.json.decode(raw)
	if type(decoded) ~= "table" then
		return {}
	end
	local props = asTable(asTable(decoded.general).properties)

	local list = {}
	for name, def in pairs(props) do
		if type(def) == "table" and type(def.type) == "string" and def.type ~= "" then
			table.insert(list, {
				name = name,
				kind = def.type,
				label = cleanLabel(def.text),
				default = def.value,
				min = tonumber(def.min),
				max = tonumber(def.max),
				step = tonumber(def.step),
				fraction = def.fraction == true,
				options = def.options,
				condition = def.condition,
				order = tonumber(def.order) or 0,
			})
		end
	end
	table.sort(list, function(a, b)
		if a.order ~= b.order then
			return a.order < b.order
		end
		return a.name < b.name
	end)
	return list
end

-- Conditions look like "audiobar.value == true" or
-- "a.value && (b.value == 2 || c.value > 3)". Some wallpapers instead use
-- JavaScript ternaries that rewrite label text rather than gate visibility, so
-- anything that fails to tokenize or parse is treated as visible.
local function tokenize(expr)
	local tokens, i, n = {}, 1, #expr
	while i <= n do
		local two = expr:sub(i, i + 1)
		local c = expr:sub(i, i)
		if c:match("%s") then
			i += 1
		elseif two == "&&" or two == "||" or two == "==" or two == "!=" or two == ">=" or two == "<=" then
			table.insert(tokens, { kind = "op", value = two })
			i += 2
		elseif c == "(" or c == ")" then
			table.insert(tokens, { kind = c })
			i += 1
		elseif c == "!" or c == ">" or c == "<" then
			table.insert(tokens, { kind = "op", value = c })
			i += 1
		elseif c == "'" or c == '"' then
			local close = expr:find(c, i + 1, true)
			if not close then
				return nil
			end
			table.insert(tokens, { kind = "lit", value = expr:sub(i + 1, close - 1) })
			i = close + 1
		elseif c:match("%d") then
			local s, e = expr:find("^%d+%.?%d*", i)
			table.insert(tokens, { kind = "lit", value = tonumber(expr:sub(s, e)) })
			i = e + 1
		elseif c:match("[%a_]") then
			local s, e = expr:find("^[%w_%.]+", i)
			local word = expr:sub(s, e)
			if word == "true" then
				table.insert(tokens, { kind = "lit", value = true })
			elseif word == "false" then
				table.insert(tokens, { kind = "lit", value = false })
			else
				table.insert(tokens, { kind = "ref", value = word })
			end
			i = e + 1
		else
			return nil -- ternary, assignment, or anything else we do not model
		end
	end
	return tokens
end

local function truthy(value)
	if value == nil or value == false or value == 0 or value == "" then
		return false
	end
	return true
end

local function compareValues(a, b, op)
	-- JavaScript-ish coercion: these expressions freely compare a boolean
	-- property against 1 or 0.
	if type(a) == "boolean" and type(b) == "number" then
		a = a and 1 or 0
	end
	if type(b) == "boolean" and type(a) == "number" then
		b = b and 1 or 0
	end
	if op == "==" then
		return a == b
	elseif op == "!=" then
		return a ~= b
	end
	local x, y = tonumber(a), tonumber(b)
	if x == nil or y == nil then
		return false
	end
	if op == ">" then
		return x > y
	elseif op == "<" then
		return x < y
	elseif op == ">=" then
		return x >= y
	end
	return x <= y
end

local function evaluate(tokens, valueOf)
	local pos = 1
	local parseOr

	local function peek()
		return tokens[pos]
	end
	local function take()
		local token = tokens[pos]
		pos += 1
		return token
	end

	local function parsePrimary()
		local token = take()
		if not token then
			return nil, false
		end
		if token.kind == "(" then
			local value, ok = parseOr()
			if not ok then
				return nil, false
			end
			local closing = take()
			if not closing or closing.kind ~= ")" then
				return nil, false
			end
			return value, true
		elseif token.kind == "op" and token.value == "!" then
			local value, ok = parsePrimary()
			if not ok then
				return nil, false
			end
			return not truthy(value), true
		elseif token.kind == "lit" then
			return token.value, true
		elseif token.kind == "ref" then
			return valueOf(token.value), true
		end
		return nil, false
	end

	local function parseComparison()
		local left, ok = parsePrimary()
		if not ok then
			return nil, false
		end
		local token = peek()
		while token and token.kind == "op" and token.value ~= "&&" and token.value ~= "||" and token.value ~= "!" do
			take()
			local right, rightOk = parsePrimary()
			if not rightOk then
				return nil, false
			end
			left = compareValues(left, right, token.value)
			token = peek()
		end
		return left, true
	end

	local function parseAnd()
		local left, ok = parseComparison()
		if not ok then
			return nil, false
		end
		local token = peek()
		while token and token.kind == "op" and token.value == "&&" do
			take()
			local right, rightOk = parseComparison()
			if not rightOk then
				return nil, false
			end
			left = truthy(left) and truthy(right)
			token = peek()
		end
		return left, true
	end

	parseOr = function()
		local left, ok = parseAnd()
		if not ok then
			return nil, false
		end
		local token = peek()
		while token and token.kind == "op" and token.value == "||" do
			take()
			local right, rightOk = parseAnd()
			if not rightOk then
				return nil, false
			end
			left = truthy(left) or truthy(right)
			token = peek()
		end
		return left, true
	end

	local value, ok = parseOr()
	if not ok or pos <= #tokens then
		return nil
	end
	return truthy(value)
end

-- project.json stores colors as space-separated floats ("0 0.92 1"); the shell's
-- color picker speaks #RRGGBB.
local function colorToHex(value)
	local parts = {}
	for chunk in tostring(value or ""):gmatch("[^%s,]+") do
		table.insert(parts, tonumber(chunk) or 0)
	end
	local function channel(index)
		local scaled = math.floor((parts[index] or 0) * 255 + 0.5)
		return math.max(0, math.min(255, scaled))
	end
	return string.format("#%02x%02x%02x", channel(1), channel(2), channel(3))
end

local function hexToColor(hex)
	local clean = tostring(hex or ""):gsub("^#", "")
	if #clean < 6 then
		return "0 0 0"
	end
	local r = tonumber(clean:sub(1, 2), 16) or 0
	local g = tonumber(clean:sub(3, 4), 16) or 0
	local b = tonumber(clean:sub(5, 6), 16) or 0
	return string.format("%.6f %.6f %.6f", r / 255, g / 255, b / 255)
end

-- ── Engine options ───────────────────────────────────────────────────────────

-- "" is the unset entry: no flag is emitted and linux-wallpaperengine's own
-- default applies. A nil element would truncate the array, so the sentinel is a
-- string.
local SCALING_VALUES = { "", "default", "stretch", "fit", "fill" }
local CLAMP_VALUES = { "", "clamp", "border", "repeat" }
-- "top" and "overlay" are also accepted, but render the wallpaper above every
-- window.
local LAYER_VALUES = { "", "background", "bottom" }

local ENGINE_TOGGLES = {
	{ key = "silent", label = "silent" },
	{ key = "noautomute", label = "noautomute" },
	{ key = "no_audio_processing", label = "no_audio_processing" },
	{ key = "disable_particles", label = "disable_particles" },
	{ key = "disable_mouse", label = "disable_mouse" },
	{ key = "disable_parallax", label = "disable_parallax" },
	{ key = "no_fullscreen_pause", label = "no_fullscreen_pause" },
	{ key = "fullscreen_pause_only_active", label = "fullscreen_pause_only_active" },
}

-- ── Rendering ────────────────────────────────────────────────────────────────

local function header()
	local children = {
		ui.label({
			text = tr("panel.title"),
			align = "center",
			fontSize = 16,
			fontWeight = "bold",
			color = "on_surface",
			flexGrow = 1,
		}),
		ui.button({
			text = tr("panel.select_multiple"),
			variant = "ghost",
			selected = multiSelect,
			tooltip = tr("panel.select_multiple_tooltip"),
			onClick = function()
				multiSelect = not multiSelect
				render()
			end,
		}),
	}

	if hasStopState() then
		table.insert(
			children,
			ui.button({
				text = tr("panel.stop"),
				variant = "ghost",
				tooltip = tr("panel.stop_tooltip"),
				onClick = function()
					send({ action = "stop" })
				end,
			})
		)
	end

	local outputs = {}
	local selectedIndex = 0
	for index, output in ipairs(noctalia.outputs()) do
		table.insert(outputs, output.name)
		if output.name == outputName then
			selectedIndex = index - 1
		end
	end
	table.insert(outputs, "All")
	if outputName == "All" then
		selectedIndex = #outputs - 1
	end
	table.insert(children, ui.select({ options = outputs, selectedIndex = selectedIndex, onChange = "outputSelected" }))
	table.insert(
		children,
		ui.button({
			glyph = "tool",
			variant = "ghost",
			tooltip = tr("panel.defaults_tooltip"),
			onClick = function()
				defaultsDraft = {}
				for key, value in pairs(storedDefaults()) do
					defaultsDraft[key] = value
				end
				view = "defaults"
				render()
			end,
		})
	)
	table.insert(children, ui.button({ glyph = "close", onClick = "onCloseClicked" }))

	return ui.row({ align = "center", justify = "space_between", gap = 8 }, children)
end

-- The cycle controls only exist in multi-select mode: an interval means nothing
-- until there is a list to rotate through.
local function cycleBar()
	local state = outputStatus()
	local running = state.cycle_enabled == true

	local summary
	if running then
		summary = tr("panel.cycle_running", {
			count = #selected,
			minutes = tonumber(state.cycle_minutes) or tonumber(minutesText) or 15,
		})
	else
		summary = tr("panel.selected_count", { count = #selected })
	end

	return ui.row({
		align = "center",
		gap = 8,
		padding = 8,
		radius = 9,
		fill = "surface_variant/0.45",
		border = running and "primary/0.55" or "outline/0.35",
		borderWidth = 1,
	}, {
		ui.label({ text = summary, fontSize = 12, color = "on_surface", flexGrow = 1 }),
		ui.label({ text = tr("panel.every"), fontSize = 12, color = "on_surface_variant" }),
		ui.input({
			key = "cycle-minutes",
			value = minutesText,
			maxWidth = 56,
			controlSize = "sm",
			textAlign = "center",
			onChange = "onMinutesChange",
		}),
		ui.label({ text = tr("panel.minutes"), fontSize = 12, color = "on_surface_variant" }),
		ui.select({
			options = { tr("panel.order_sequential"), tr("panel.order_random") },
			selectedIndex = order == "random" and 1 or 0,
			controlSize = "sm",
			onChange = "onOrderChange",
		}),
		ui.button({
			text = running and tr("panel.cycle_stop") or tr("panel.cycle_start"),
			variant = running and "ghost" or "primary",
			enabled = running or #selected > 0,
			onClick = function()
				if running then
					send({ action = "cycle", enabled = false })
				else
					send({
						action = "cycle",
						enabled = true,
						minutes = tonumber(minutesText) or 15,
						order = order,
					})
				end
			end,
		}),
		ui.button({
			text = tr("panel.clear"),
			variant = "ghost",
			enabled = #selected > 0,
			onClick = function()
				selected = {}
				send({ action = "select", ids = selected })
				render()
			end,
		}),
	})
end

-- A labelled row wrapping one control, so the form reads as a single column.
local function settingRow(label, control)
	return ui.row({ align = "center", gap = 10 }, {
		ui.label({ text = label, fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 2 }),
		control,
	})
end

local function selectRow(label, values, current, unsetLabel, onPick)
	local options, selectedIndex = {}, 0
	for index, value in ipairs(values) do
		table.insert(options, value == "" and unsetLabel or value)
		if value == (current or "") then
			selectedIndex = index - 1
		end
	end
	return settingRow(
		label,
		ui.select({
			options = options,
			selectedIndex = selectedIndex,
			controlSize = "sm",
			onChange = function(index)
				local picked = values[(math.floor(tonumber(index) or 0)) + 1]
				onPick(picked ~= "" and picked or nil)
			end,
		})
	)
end

local function sliderRow(label, value, min, max, step, display, onSlide, onCommit)
	return ui.row({ align = "center", gap = 10 }, {
		ui.label({ text = label, fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 2 }),
		ui.slider({
			min = min,
			max = max,
			step = step,
			value = value,
			flexGrow = 1,
			onChange = onSlide,
			onDragEnd = onCommit,
		}),
		ui.label({ text = display, fontSize = 11, color = "on_surface_variant", maxWidth = 52 }),
	})
end

-- One control for one wallpaper property, chosen by its declared type.
-- One builder per declared property type. Each takes the property and its
-- current value and returns a control, or nil when there is nothing to draw.
-- Adding support for a new type means adding an entry here and nothing else.
local PROPERTY_CONTROLS = {}

PROPERTY_CONTROLS.bool = function(prop, label, value)
	return settingRow(
		label,
		ui.toggle({
			checked = value == true,
			onChange = function()
				propsDraft[prop.name] = not (value == true)
				render()
			end,
		})
	)
end

PROPERTY_CONTROLS.slider = function(prop, label, value)
	local min = prop.min or 0
	local max = prop.max or 1
	local step = prop.step or (prop.fraction and (max - min) / 100 or 1)
	local number = tonumber(value) or min
	local display = prop.fraction and string.format("%.2f", number) or tostring(math.floor(number))
	return sliderRow(label, number, min, max, step, display, function(dragged)
		propsDraft[prop.name] = tonumber(dragged) or number
	end, function()
		render() -- re-render once on release: other controls may be conditional on this
	end)
end

PROPERTY_CONTROLS.color = function(prop, label, value)
	local hex = colorToHex(value)
	return settingRow(
		label,
		ui.row({ gap = 6, align = "center" }, {
			ui.label({ text = hex, fontSize = 11, color = "on_surface_variant" }),
			ui.box({
				width = 30,
				height = 20,
				radius = 6,
				fill = hex,
				border = "outline",
				borderWidth = 1,
				onClick = function()
					noctalia.openColorPicker(hex, function(picked)
						if picked then
							propsDraft[prop.name] = hexToColor(picked)
							render()
						end
					end)
				end,
			}),
		})
	)
end

PROPERTY_CONTROLS.combo = function(prop, label, value)
	local options, values, selectedIndex = {}, {}, 0
	for index, option in ipairs(asTable(prop.options)) do
		if type(option) == "table" then
			table.insert(options, cleanLabel(option.label))
			table.insert(values, option.value)
			if option.value == value then
				selectedIndex = index - 1
			end
		end
	end
	if #options == 0 then
		return nil
	end
	return settingRow(
		label,
		ui.select({
			options = options,
			selectedIndex = selectedIndex,
			controlSize = "sm",
			onChange = function(index)
				local picked = values[(math.floor(tonumber(index) or 0)) + 1]
				if picked ~= nil then
					propsDraft[prop.name] = picked
					render()
				end
			end,
		})
	)
end

PROPERTY_CONTROLS.textinput = function(prop, label, value)
	return settingRow(
		label,
		ui.input({
			key = "prop-" .. prop.name,
			value = tostring(value or ""),
			controlSize = "sm",
			onChange = function(typed)
				propsDraft[prop.name] = tostring(typed or "")
			end,
		})
	)
end

-- Not inputs: wallpaper authors use these purely as section headings.
PROPERTY_CONTROLS.text = function(_prop, label)
	return ui.label({ text = label, fontSize = 12, fontWeight = "bold", color = "primary" })
end
PROPERTY_CONTROLS.group = PROPERTY_CONTROLS.text

local function propertyRow(prop, currentValue)
	local build = PROPERTY_CONTROLS[prop.kind]
	if not build then
		return nil
	end
	-- A heading whose text was entirely markup is decoration, such as a banner
	-- image or a donation link, rather than a setting. Its generated name is not
	-- worth showing in its place.
	if prop.label == "" and (prop.kind == "text" or prop.kind == "group") then
		return nil
	end
	return build(prop, prop.label ~= "" and prop.label or prop.name, currentValue)
end

-- Draws the engine switches for either the global defaults or one wallpaper.
-- `fallback` holds the values a control falls back to when the draft has no entry
-- of its own, so a wallpaper's controls show what it currently inherits. Editing
-- a control writes into the draft, which is what makes it an override.
local function engineSection(draft, fallback, unsetLabel)
	local function effective(key, default)
		local value = draft[key]
		if value == nil then
			value = fallback[key]
		end
		if value == nil then
			return default
		end
		return value
	end

	local fps = math.floor(tonumber(effective("fps", 30)) or 30)
	local volume = math.floor(tonumber(effective("volume", 15)) or 15)

	local children = {
		ui.label({ text = tr("panel.playback"), fontSize = 13, fontWeight = "bold", color = "on_surface" }),
		selectRow(tr("panel.engine.scaling"), SCALING_VALUES, effective("scaling"), unsetLabel, function(value)
			draft.scaling = value
			render()
		end),
		selectRow(tr("panel.engine.clamp"), CLAMP_VALUES, effective("clamp"), unsetLabel, function(value)
			draft.clamp = value
			render()
		end),
		selectRow(tr("panel.engine.layer"), LAYER_VALUES, effective("layer"), unsetLabel, function(value)
			draft.layer = value
			render()
		end),
		-- Only record a value that differs from what the control already shows.
		-- Writing on every change would turn an untouched slider into an explicit
		-- override the moment the form is submitted.
		sliderRow(tr("panel.engine.fps"), fps, 5, 144, 1, tostring(fps), function(value)
			local picked = math.floor(tonumber(value) or fps)
			if picked ~= fps then
				draft.fps = picked
			end
		end, function()
			render()
		end),
		sliderRow(tr("panel.engine.volume"), volume, 0, 100, 1, tostring(volume), function(value)
			local picked = math.floor(tonumber(value) or volume)
			if picked ~= volume then
				draft.volume = picked
			end
		end, function()
			render()
		end),
	}
	for _, toggle in ipairs(ENGINE_TOGGLES) do
		local key = toggle.key
		local checked = effective(key) == true
		table.insert(
			children,
			settingRow(
				tr("panel.engine." .. toggle.label),
				ui.toggle({
					checked = checked,
					onChange = function()
						draft[key] = not checked
						render()
					end,
				})
			)
		)
	end
	return children
end

-- The value a property currently holds: the user's edit if there is one, else
-- the default the wallpaper ships with.
local function currentOf(prop)
	local value = propsDraft[prop.name]
	if value ~= nil then
		return value
	end
	return prop.default
end

-- Resolves "somename.value" for the condition evaluator.
local function propertyResolver()
	local byName = {}
	for _, prop in ipairs(configProps) do
		byName[prop.name] = prop
	end
	return function(reference)
		local prop = byName[(reference:gsub("%.value$", ""))]
		return prop and currentOf(prop) or nil
	end
end

local function propertyVisible(prop, valueOf)
	local condition = prop.condition
	if type(condition) ~= "string" or condition:gsub("%s", "") == "" then
		return true
	end
	local tokens = tokenize(condition)
	if not tokens then
		return true
	end
	local result = evaluate(tokens, valueOf)
	if result == nil then
		return true
	end
	return result
end

-- Wallpaper Engine names new properties "newpropertyN" and authors do not always
-- relabel them. Unlabelled properties go behind a disclosure.
local function propertySection()
	local valueOf = propertyResolver()
	local rows, unlabeled = {}, {}

	for _, prop in ipairs(configProps) do
		if not PROPERTY_SKIP[prop.kind] and propertyVisible(prop, valueOf) then
			local control = propertyRow(prop, currentOf(prop))
			if control then
				table.insert(prop.label == "" and unlabeled or rows, control)
			end
		end
	end

	if #rows == 0 and #unlabeled == 0 then
		table.insert(rows, ui.label({ text = tr("panel.no_properties"), fontSize = 12, color = "on_surface_variant" }))
		return rows
	end

	if #unlabeled > 0 then
		table.insert(
			rows,
			ui.row({ align = "center", gap = 10 }, {
				ui.label({
					text = tr("panel.unlabeled", { count = #unlabeled }),
					fontSize = 12,
					color = "on_surface_variant",
					flexGrow = 1,
					maxLines = 2,
				}),
				ui.toggle({
					checked = showUnlabeled,
					onChange = function()
						showUnlabeled = not showUnlabeled
						render()
					end,
				}),
			})
		)
		if showUnlabeled then
			for _, control in ipairs(unlabeled) do
				table.insert(rows, control)
			end
		end
	end
	return rows
end

local function configHeader()
	return ui.row({ align = "center", gap = 8 }, {
		ui.button({ glyph = "close", variant = "ghost", tooltip = tr("panel.back"), onClick = function()
			view = "grid"
			render()
		end }),
		ui.label({
			text = configName,
			fontSize = 15,
			fontWeight = "bold",
			color = "on_surface",
			flexGrow = 1,
			maxLines = 1,
		}),
		ui.button({ glyph = "restore", variant = "ghost", tooltip = tr("panel.reset"), onClick = function()
			engineDraft = {}
			propsDraft = {}
			send({ action = "options", id = configId, engine = {}, properties = {} })
			render()
		end }),
		ui.button({ glyph = "check", text = tr("panel.apply_options"), variant = "primary", onClick = function()
			send({ action = "options", id = configId, engine = engineDraft, properties = propsDraft })
		end }),
	})
end

-- Global defaults. Every wallpaper resolves these unless it overrides the key
-- itself, so this is the place to mute everything at once.
local function defaultsView()
	local rows = engineSection(defaultsDraft, {}, tr("panel.engine.unset"))

	table.insert(rows, ui.separator({}))
	table.insert(
		rows,
		ui.row({ align = "center", gap = 10 }, {
			ui.label({
				text = tr("panel.clear_overrides"),
				fontSize = 12,
				color = "on_surface",
				flexGrow = 1,
				maxLines = 3,
			}),
			ui.toggle({
				checked = clearOverrides,
				onChange = function()
					clearOverrides = not clearOverrides
					render()
				end,
			}),
		})
	)

	return ui.column({ flexGrow = 1, gap = 12 }, {
		ui.row({ align = "center", gap = 8 }, {
			ui.button({ glyph = "close", variant = "ghost", tooltip = tr("panel.back"), onClick = function()
				view = "grid"
				render()
			end }),
			ui.label({
				text = tr("panel.defaults"),
				fontSize = 15,
				fontWeight = "bold",
				color = "on_surface",
				flexGrow = 1,
				maxLines = 1,
			}),
			ui.button({ glyph = "restore", variant = "ghost", tooltip = tr("panel.reset"), onClick = function()
				defaultsDraft = {}
				send({ action = "defaults", engine = {}, clear_overrides = clearOverrides })
				render()
			end }),
			ui.button({ glyph = "check", text = tr("panel.apply_options"), variant = "primary", onClick = function()
				send({ action = "defaults", engine = defaultsDraft, clear_overrides = clearOverrides })
			end }),
		}),
		ui.scroll({ key = "defaults-scroll", gap = 10, paddingRight = 8, align = "stretch", flexGrow = 1 }, rows),
	})
end

local function configView()
	local rows = engineSection(engineDraft, storedDefaults(), tr("panel.engine.inherit"))
	table.insert(rows, ui.separator({}))
	table.insert(
		rows,
		ui.label({ text = tr("panel.properties"), fontSize = 13, fontWeight = "bold", color = "on_surface" })
	)
	for _, row in ipairs(propertySection()) do
		table.insert(rows, row)
	end

	return ui.column({ flexGrow = 1, gap = 12 }, {
		configHeader(),
		-- A distinct key from the grid's scroll, so the form opens at the top.
		ui.scroll({ key = "config-scroll", gap = 10, paddingRight = 8, align = "stretch", flexGrow = 1 }, rows),
	})
end

-- Seeds the form from the settings the service holds for this wallpaper.
local function openConfig(id, name)
	configId = id
	configName = name
	configProps = loadProperties(id)
	engineDraft = {}
	propsDraft = {}
	local stored = asTable(status.options)[id]
	if type(stored) == "table" then
		for key, value in pairs(asTable(stored.engine)) do
			engineDraft[key] = value
		end
		for key, value in pairs(asTable(stored.properties)) do
			propsDraft[key] = value
		end
	end
	view = "config"
	render()
end

local function tilePreview(item, isSelected, isCurrent)
	local frame = "outline/0"
	if isSelected then
		frame = "primary"
	elseif isCurrent then
		frame = "secondary"
	end

	return ui.column({
		padding = 3,
		radius = 11,
		border = frame,
		borderWidth = (isSelected or isCurrent) and 2 or 1,
	}, {
		ui.image({
			path = item.path,
			width = previewWidth,
			height = previewHeight,
			fit = "cover",
			radius = 8,
			onClick = function()
				if multiSelect then
					toggleSelection(item.nb)
					render()
				else
					send({ action = "apply", id = item.nb })
					noctalia.notify(tr("panel.title"), tr("panel.apply", { name = item.name }))
				end
			end,
		}),
	})
end

-- Favorite list

local FavoriteList = {}

local function getDataPath()
	return noctalia.pluginDataDir() .. "/data.json"
end

local function loadData()
	local raw = noctalia.readFile(getDataPath())
	if not raw then
		return {}
	end
	local ok, decoded = pcall(function()
		return noctalia.json.decode(raw)
	end)
	if not ok or type(decoded) ~= "table" then
		return {}
	end
	return decoded
end

local function saveData(data)
	return noctalia.writeFile(getDataPath(), noctalia.json.encode(data))
end

local function loadFavoriteList()
	local data = loadData()
	FavoriteList = data.favorites or {}
end

local function persistFavoriteList()
	local data = loadData() -- récupère les autres clés existantes (ex: settingsPath)
	data.favorites = FavoriteList
	saveData(data)
end

local function addFavoriteList(item)
	noctalia.notify("Add Favorite")
	table.insert(FavoriteList, item)
	persistFavoriteList()
end

local function removeFavoriteList(item, nb)
	noctalia.notify("Remove Favorite")
	table.remove(FavoriteList, nb)
	persistFavoriteList()
end

local function checkInFavoriteList(item)
	local nb = 1
	for _, entryName in ipairs(FavoriteList) do
		if entryName.name == item.name then
			removeFavoriteList(item, nb)
			return
		end
		nb = nb + 1
	end
	addFavoriteList(item)
end

local function tileCaption(item, index, isSelected)
	-- Numbered to show rotation order.
	local caption = isSelected and (tostring(index) .. ". " .. item.name) or item.name

	-- A fixed label width keeps every tile the same size; long titles truncate.
	return ui.row({ gap = 2, align = "center" }, {
		ui.button({
			glyph = "star",
			variant = "ghost",
			controlSize = "sm",
			tooltip = "Add at your favorite wallpaper",
			onClick = function()
				checkInFavoriteList(item)
				render()
			end
		}),
		ui.label({
			text = caption,
			fontSize = 11,
			maxLines = 1,
			maxWidth = previewWidth - 34,
			textAlign = "center",
			color = isSelected and "primary" or "on_surface",
		}),
		ui.button({
			glyph = "settings",
			variant = "ghost",
			controlSize = "sm",
			tooltip = tr("panel.configure"),
			onClick = function()
				openConfig(item.nb, item.name)
			end,
		}),
	})
end

local function tile(item: Wallpaper, state)
	local index = selectionIndex(item.nb)
	local isSelected = multiSelect and index ~= nil
	local isCurrent = state.current == item.nb

	return ui.column({ gap = 4, key = item.nb, align = "center" }, {
		tilePreview(item, isSelected, isCurrent),
		tileCaption(item, index, isSelected),
	})
end

render = function()
	if not isOpen then
		return
	end
	catalog = catalog or loadCatalog()
	if view == "defaults" then
		panel.render(defaultsView())
		return
	end
	if view == "config" and configId then
		panel.render(configView())
		return
	end
	local state = outputStatus()

	local rows = {}
	local row = {}
	for index, item in ipairs(catalog) do
		table.insert(row, tile(item, state))
		if #row == columns or index == #catalog then
			table.insert(rows, ui.row({ gap = 12, align = "start" }, row))
			row = {}
		end
	end

	local body = { header() }
	if multiSelect then
		table.insert(body, cycleBar())
	end
	if #catalog == 0 then
		table.insert(body, ui.label({ text = tr("panel.no_wallpapers"), fontSize = 12, color = "on_surface_variant" }))
	end

	local favoriteRows = {}
	local favoriteRow = {}
	for index, item in ipairs(FavoriteList) do
		table.insert(favoriteRow, tile(item, state))
		if #favoriteRow == columns or index == #FavoriteList then
			table.insert(favoriteRows, ui.row({ gap = 12, align = "start" }, favoriteRow))
			favoriteRow = {}
		end
	end

	-- Single scroll for all list (Wallpaper and Favorite Wallpaper)
	local scrollContent = {}
	table.insert(scrollContent, ui.label({ text = "Favorites", fontSize = 13, fontWeight = "bold", color = "on_surface" }))
	if #FavoriteList == 0 then
		table.insert(scrollContent, ui.label({ text = "No favorite", fontSize = 12, color = "on_surface_variant" }))
	else
		for _, r in ipairs(favoriteRows) do
			table.insert(scrollContent, r)
		end
	end

	table.insert(scrollContent,
		ui.separator({ spacing = 12 }
	))

	table.insert(scrollContent,
		ui.label({ text = "All wallpapers", fontSize = 13, fontWeight = "bold", color = "on_surface" }
	))

	for _, r in ipairs(rows) do
		table.insert(scrollContent, r)
	end

	table.insert(body,
		ui.scroll({ key = "grid-scroll", gap = 12, paddingRight = 8, align = "stretch", flexGrow = 1 }, scrollContent))

	panel.render(ui.column({ flexGrow = 1, gap = 12 }, body))
end
-- ── Handlers ─────────────────────────────────────────────────────────────────

-- Adopts the service's view of this output. Selection, interval and order are
-- persisted, so the panel reflects the rotation that is running.
local function adoptStatus()
	local state = outputStatus()
	selected = {}
	if type(state.selection) == "table" then
		for _, id in ipairs(state.selection) do
			table.insert(selected, id)
		end
	end
	if tonumber(state.cycle_minutes) then
		minutesText = tostring(math.floor(tonumber(state.cycle_minutes)))
	end
	order = state.cycle_order == "random" and "random" or "sequential"
	if state.cycle_enabled or #selected > 0 then
		multiSelect = true
	end
end

function outputSelected(_index, label)
	if type(label) == "string" and label ~= "" then
		outputName = label
		adoptStatus()
		render()
	end
end

function onMinutesChange(value)
	minutesText = tostring(value or "")
end

function onOrderChange(index, _label)
	order = ORDER_VALUES[(math.floor(tonumber(index) or 0)) + 1] or "sequential"
end

function onCloseClicked()
	panel.close()
end

function onOpen(_context)
	isOpen = true
	loadFavoriteList()
	outputName = noctalia.focusedOutputName() or outputName
	if not outputName then
		local outputs = noctalia.outputs()
		outputName = outputs[1] and outputs[1].name or nil
	end
	view = "grid"
	columns = math.max(2, math.min(8, math.floor(tonumber(noctalia.getConfig("grid_columns")) or 4)))
	local spacing = (columns - 1) * TILE_GAP + columns * TILE_FRAME * 2
	previewWidth = math.max(60, math.floor((GRID_WIDTH - spacing) / columns))
	previewHeight = math.floor(previewWidth * PREVIEW_RATIO)

	-- Rebuild the catalog only when the Workshop directory has changed.
	local stamp = nil
	if workshopRoot then
		local info = noctalia.fileInfo(workshopRoot)
		stamp = info and info.mtime or nil
	end
	if catalog == nil or stamp == nil or stamp ~= catalogStamp then
		catalog = nil
		catalogStamp = stamp
	end

	status = noctalia.state.get(STATUS_KEY) or {}
	adoptStatus()
	-- The service publishes status on load and on every change, so no request is
	-- needed here.
	render()
end

function onClose()
	isOpen = false
end

-- The entry stays resident after the surface closes, so this keeps firing; the
-- isOpen guard in render() suppresses work while hidden.
noctalia.state.watch(STATUS_KEY, function(value)
	status = type(value) == "table" and value or {}
	render()
end)
