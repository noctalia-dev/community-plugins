--!nonstrict
-- Case Convert — launcher provider.
--
-- Usage in the launcher (prefix `/case` by default):
--   /case some text here   convert the typed text
--   /case                  convert the primary selection, else the clipboard
--   /case >kebab           same, but filter the conversion list by name
--
-- Enter copies the highlighted conversion. Plugin launcher providers cannot
-- auto-paste (the host reports supportsAutoPaste() == false for them), so
-- copying is as far as this can go.

local cases = require("./cases.luau")

-- Rows deliberately show no leading icon: it would repeat what the category
-- filter bar and the subtitle already say, and at icon size it crowds the
-- conversion itself. Leaving `glyph` unset is not enough — the host falls back
-- to `app-window` — and a badge renders at icon size, so a text badge is no
-- smaller. A blank badge is the one thing that suppresses both: `badge` wins
-- over glyph/icon, and a space renders as nothing while keeping rows aligned
-- with the rest of the launcher.
local BLANK_BADGE = " "

-- Rows do carry `category`, which must match a [[launcher_provider.category]]
-- label in plugin.toml for the filter bar to work.

-- key -> { name, value } for the rows currently on screen, so onActivate can
-- copy the payload without smuggling it through the row id (ids are matched with
-- patterns, and conversions of long or multi-line text make poor ids).
local shown = {}

local function boolConfig(key: string, fallback: boolean): boolean
	local value = noctalia.getConfig(key)
	return if type(value) == "boolean" then value else fallback
end

local function stringConfig(key: string, fallback: string): string
	local value = noctalia.getConfig(key)
	return if type(value) == "string" and value ~= "" then value else fallback
end

local function clipboardText(): string
	return cases.trim(noctalia.clipboardText() or "")
end

-- Resolve the text to convert when the user typed none. The primary selection
-- needs wl-paste (wl-clipboard); it is read asynchronously, hence the callback.
local function resolveExternalText(callback)
	local source = stringConfig("input_source", "auto")

	if source == "clipboard" then
		callback(clipboardText())
		return
	end

	if not noctalia.commandExists("wl-paste") then
		callback(if source == "selection" then "" else clipboardText())
		return
	end

	-- String form runs through /bin/sh -c; no dynamic arguments are involved, so
	-- it needs no quoting and keeps plugin_api at 3 (argv tables want >= 24).
	local started = noctalia.runAsync("wl-paste --primary --no-newline", function(result)
		-- wl-paste exits non-zero when the primary selection is empty.
		local text = if result.exitCode == 0 then cases.trim(result.stdout) else ""
		if text == "" and source ~= "selection" then
			text = clipboardText()
		end
		callback(text)
	end, 1000)

	if not started then
		callback(if source == "selection" then "" else clipboardText())
	end
end

local function hintRow(title: string, subtitle: string)
	return { id = "", title = title, subtitle = subtitle, badge = BLANK_BADGE }
end

-- `query` must be echoed back to setResults verbatim: the host uses it to drop
-- results that arrived after the input already moved on.
local function emit(query: string, text: string, filter: string)
	shown = {}

	if text == "" then
		launcher.setResults(query, {
			hintRow("Type text to convert", "Or select text first, then reopen with an empty query"),
		})
		return
	end

	local results = cases.convertAll(text, boolConfig("preserve_casing", true))
	local rows = {}

	for index, result in results do
		if filter == "" or result.name:lower():find(filter, 1, true) then
			shown[result.key] = { name = result.name, value = result.value }
			table.insert(rows, {
				id = "c:" .. result.key,
				title = result.value,
				subtitle = result.name,
				badge = BLANK_BADGE,
				category = result.category,
				-- Fixed declaration order; the host sorts on score, descending.
				score = 100 - index,
			})
		end
	end

	if #rows == 0 then
		table.insert(rows, hintRow("No matching conversion", "Filtering on: " .. filter))
	end

	launcher.setResults(query, rows)
end

function onQuery(query)
	local text = cases.trim(query)

	-- Typed text is the input, unless it starts with `>` — then it filters the
	-- conversion list and the input comes from the selection/clipboard instead.
	if text ~= "" and text:sub(1, 1) ~= ">" then
		emit(query, text, "")
		return
	end

	local filter = if text:sub(1, 1) == ">" then cases.trim(text:sub(2)):lower() else ""
	resolveExternalText(function(external)
		emit(query, external, filter)
	end)
end

function onActivate(id)
	local key = id:match("^c:(.+)$")
	if not key then
		return
	end

	local entry = shown[key]
	if not entry or entry.value == "" then
		return
	end

	noctalia.copyToClipboard(entry.value, "text/plain")
	if boolConfig("notify_on_copy", true) then
		noctalia.notify("Case Convert", entry.name .. " copied to clipboard")
	end
end
