--!nonstrict
-- niri-active-workspace — a bar widget that shows only the focused niri
-- workspace, instead of a pill containing every workspace.
--
-- The plugin API exposes no compositor state, so workspace data comes from
-- niri's own IPC:
--   * one `niri msg --json workspaces` snapshot at load, and again on the slow
--     update tick as a self-heal in case the stream dies
--   * `niri msg --json event-stream` for live updates
--
-- Multi-monitor: niri marks one workspace `is_active` per output and exactly
-- one `is_focused` globally. Noctalia renders a bar per output, so each widget
-- instance reports its own connector via barWidget.outputName() and tracks the
-- active workspace on that output. With a single output the two are the same
-- workspace, so behaviour there is unchanged.
--
-- Left click  → toggle the niri overview
-- Scroll      → focus the workspace below / above

local LABEL_MODE: string = noctalia.getConfig("label_mode") or "name_or_index"
local SHOW_POSITION: boolean = noctalia.getConfig("show_position") == true
local GLYPH: string = noctalia.getConfig("glyph") or ""

-- Resync cadence. The event stream does the real work; this only covers the
-- case where it dies silently.
local RESYNC_MS: number = 60000

local allWorkspaces: { any } = {}

-- ── Output scoping ───────────────────────────────────────────────────────────

-- nil when the host cannot say (older API, or before the bar is placed), in
-- which case fall back to the globally focused workspace.
local function outputName(): string?
	if barWidget.outputName == nil then
		return nil
	end
	local ok, name = pcall(barWidget.outputName)
	if ok and name ~= nil and name ~= "" then
		return name
	end
	return nil
end

local function visibleWorkspaces(): { any }
	local connector = outputName()
	if connector == nil then
		return allWorkspaces
	end
	local scoped = {}
	for _, ws in ipairs(allWorkspaces) do
		if ws.output == connector then
			table.insert(scoped, ws)
		end
	end
	-- An output we have no workspaces for should not blank the widget.
	if #scoped == 0 then
		return allWorkspaces
	end
	return scoped
end

local function selectFocused(scoped: { any }): any
	local connector = outputName()
	for _, ws in ipairs(scoped) do
		-- Per-output active workspace when we know which output we are on,
		-- otherwise the single globally focused one.
		if connector ~= nil and ws.is_active then
			return ws
		elseif connector == nil and ws.is_focused then
			return ws
		end
	end
	-- Fall back to global focus if the output had no active workspace.
	for _, ws in ipairs(scoped) do
		if ws.is_focused then
			return ws
		end
	end
	return nil
end

-- ── Rendering ────────────────────────────────────────────────────────────────

local function labelFor(ws: any): string
	if ws == nil then
		return "—"
	end
	local idx: string = tostring(ws.idx or "?")
	local name: string? = ws.name

	if LABEL_MODE == "index" then
		return idx
	elseif LABEL_MODE == "name" then
		return name or idx
	elseif LABEL_MODE == "both" then
		if name ~= nil and name ~= "" then
			return `{idx}:{name}`
		end
		return idx
	end
	-- "name_or_index" (default)
	if name ~= nil and name ~= "" then
		return name
	end
	return idx
end

local function render()
	if GLYPH ~= "" then
		barWidget.setGlyph(GLYPH)
	end

	local scoped = visibleWorkspaces()
	local focused = selectFocused(scoped)

	local text: string = labelFor(focused)
	if SHOW_POSITION and focused ~= nil and #scoped > 0 then
		text = `{text} {focused.idx}/{#scoped}`
	end
	barWidget.setText(text)

	-- Tooltip keeps the full list for this output reachable, since the bar no
	-- longer shows it.
	local rows = {}
	for _, ws in ipairs(scoped) do
		local marker: string = (focused ~= nil and ws.id == focused.id) and "●" or "○"
		table.insert(rows, {
			key = `{marker} {tostring(ws.idx)}`,
			value = (ws.name ~= nil and ws.name ~= "") and ws.name or "(unnamed)",
		})
	end
	if #rows > 0 then
		barWidget.setTooltip(rows)
	else
		barWidget.setTooltip("No niri workspaces")
	end
end

-- ── State ────────────────────────────────────────────────────────────────────

local function applyWorkspaces(list: { any })
	allWorkspaces = {}
	for _, ws in ipairs(list) do
		table.insert(allWorkspaces, ws)
	end
	table.sort(allWorkspaces, function(a, b)
		return (a.idx or 0) < (b.idx or 0)
	end)
	render()
end

-- WorkspaceActivated carries only { id, focused }, so patch the cached list
-- rather than re-querying niri on every switch. Activation is per-output: it
-- clears is_active on the activated workspace's own output only, while
-- is_focused is global.
local function applyActivated(id: any, isFocused: boolean)
	local activated: any = nil
	for _, ws in ipairs(allWorkspaces) do
		if ws.id == id then
			activated = ws
			break
		end
	end
	if activated == nil then
		return
	end

	for _, ws in ipairs(allWorkspaces) do
		if ws.output == activated.output then
			ws.is_active = ws.id == id
		end
		if isFocused then
			ws.is_focused = ws.id == id
		end
	end
	render()
end

local function snapshot()
	noctalia.runAsync("niri msg --json workspaces", function(res)
		if res.exitCode ~= 0 then
			return
		end
		local data = noctalia.json.decode(res.stdout)
		if type(data) == "table" then
			applyWorkspaces(data)
		end
	end, 3000)
end

-- ── Wiring ───────────────────────────────────────────────────────────────────

snapshot()

noctalia.runStream("niri msg --json event-stream", function(line: string)
	local ev = noctalia.json.decode(line)
	if type(ev) ~= "table" then
		return
	end
	if ev.WorkspacesChanged ~= nil then
		applyWorkspaces(ev.WorkspacesChanged.workspaces or {})
	elseif ev.WorkspaceActivated ~= nil then
		local a = ev.WorkspaceActivated
		applyActivated(a.id, a.focused == true)
	end
end)

function update()
	noctalia.setUpdateInterval(RESYNC_MS)
	snapshot()
end

function onClick()
	noctalia.runAsync("niri msg action toggle-overview")
end

function onScroll(axis: string, steps: number, startsGesture: boolean)
	local action: string = (steps > 0) and "focus-workspace-down" or "focus-workspace-up"
	noctalia.runAsync(`niri msg action {action}`)
end
