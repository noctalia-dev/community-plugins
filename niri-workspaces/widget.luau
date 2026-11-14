--!nonstrict
-- niri-workspaces — the focus-hint look, with a list of workspace names that
-- are left out of the bar.
--
-- Why this exists: a scratchpad parks windows on a workspace it never shows
-- you (ns-cratchpad and friends do exactly that), and Noctalia's own
-- workspaces widget has no way to skip one — `config-set
-- widget.workspaces.hidden_workspaces` is refused as an unknown setting — so
-- the shelf costs a pill, or a dot, that means nothing to the operator.
--
-- The look is the built-in Focus Hint one: every workspace you are not on is a
-- dot, the one you are on is a pill with its name. Colours come from the
-- palette by role, so they follow the theme.
--
-- Workspace data comes from niri's own IPC, the plugin API exposing no
-- compositor state: one `niri msg --json workspaces` snapshot at load and on
-- the slow tick (a self-heal), then `niri msg --json event-stream` for live
-- updates.
--
-- Left click a dot  → focus that workspace
-- Scroll            → the next / previous workspace

local RESYNC_MS: number = 60000
local PILL_HEIGHT: number = 16
local PILL_RADIUS: number = 8
local PILL_PADDING: number = 6

local hidden: { [string]: boolean } = {}
local hideEmpty: boolean = true
local dotSize: number = 7
local dotColor: string = "tertiary"
local focusedColor: string = "primary"
local focusedTextColor: string = "on_primary"
local fontSize: number = 0
local maxChars: number = 0
local gap: number = 6

local allWorkspaces: { any } = {}
local everyWorkspace: { any } = {}
local renderedVertical: boolean? = nil

-- ── Settings ────────────────────────────────────────────────────────────────

local function readConfig()
	hidden = {}
	local list = noctalia.getConfig("hidden") or ""
	for name in string.gmatch(list, "[^,%s]+") do
		hidden[string.lower(name)] = true
	end

	hideEmpty = noctalia.getConfig("hide_empty") ~= false
	dotSize = math.max(3, math.min(20, tonumber(noctalia.getConfig("dot_size")) or 7))
	dotColor = noctalia.getConfig("dot_color") or "tertiary"
	focusedColor = noctalia.getConfig("focused_color") or "primary"
	focusedTextColor = noctalia.getConfig("focused_text_color") or "on_primary"
	fontSize = tonumber(noctalia.getConfig("font_size")) or 0
	maxChars = tonumber(noctalia.getConfig("max_label_chars")) or 0
	gap = math.max(0, tonumber(noctalia.getConfig("gap")) or 6)
end

-- ── Output scoping ──────────────────────────────────────────────────────────

-- nil when the host cannot say, in which case the globally focused workspace
-- decides.
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
		return everyWorkspace
	end
	local scoped = {}
	for _, ws in ipairs(everyWorkspace) do
		if ws.output == connector then
			table.insert(scoped, ws)
		end
	end
	if #scoped == 0 then
		return everyWorkspace
	end
	return scoped
end

local function isFocused(ws: any): boolean
	local connector = outputName()
	if connector ~= nil then
		return ws.is_active == true
	end
	return ws.is_focused == true
end

-- A workspace is left out when its name is in the list, or when it holds no
-- window — except the one we are on, which is always drawn: an operator on an
-- invisible workspace with no way back is worse than a dot.
local function keep(ws: any): boolean
	local name: string = ws.name or ""
	if hidden[string.lower(name)] and not isFocused(ws) then
		return false
	end
	if hideEmpty and ws.active_window_id == nil and not isFocused(ws) then
		return false
	end
	return true
end

-- ── Rendering ───────────────────────────────────────────────────────────────

local function labelFor(ws: any): string
	local name: string = ws.name or ""
	if name == "" then
		return tostring(ws.idx or "?")
	end
	if maxChars <= 0 then
		return name
	end
	local nextOffset = utf8.offset(name, maxChars + 1)
	if nextOffset then
		return string.sub(name, 1, nextOffset - 1)
	end
	return name
end

local function focusWorkspace(ws: any)
	local target = ws.idx
	if target == nil then
		return
	end
	noctalia.runAsync("niri msg action focus-workspace " .. tostring(target))
end

local function render()
	local vertical = barWidget.isVertical()
	renderedVertical = vertical
	local container = vertical and ui.column or ui.row
	local chips = {}

	for _, ws in ipairs(allWorkspaces) do
		if keep(ws) then
			local key = tostring(ws.id)
			local tooltip = (ws.name ~= nil and ws.name ~= "") and ws.name or tostring(ws.idx)
			if isFocused(ws) then
				local labelProps = {
					text = labelFor(ws),
					color = focusedTextColor,
				}
				if fontSize > 0 then
					labelProps.fontSize = fontSize
				end
				local pillProps = {
					key = key,
					align = "center",
					justify = "center",
					fill = focusedColor,
					radius = PILL_RADIUS,
					onClick = function() focusWorkspace(ws) end,
					tooltip = tooltip,
				}
				if vertical then
					pillProps.width = PILL_HEIGHT
					pillProps.paddingV = PILL_PADDING
				else
					pillProps.height = PILL_HEIGHT
					pillProps.paddingH = PILL_PADDING
				end
				table.insert(chips, container(pillProps, { ui.label(labelProps) }))
			else
				table.insert(
					chips,
					ui.box({
						key = key,
						width = dotSize,
						height = dotSize,
						radius = dotSize / 2,
						fill = dotColor,
						onClick = function() focusWorkspace(ws) end,
						tooltip = tooltip,
					})
				)
			end
		end
	end

	barWidget.setVisible(#chips > 0)
	if #chips == 0 then
		return
	end
	barWidget.render(container({ gap = gap, align = "center", justify = "center" }, chips))
end

-- ── State ───────────────────────────────────────────────────────────────────

local function applyWorkspaces(list: { any })
	everyWorkspace = {}
	allWorkspaces = {}
	for _, ws in ipairs(list) do
		table.insert(everyWorkspace, ws)
	end
	local scopedList = visibleWorkspaces()
	for _, ws in ipairs(scopedList) do
		table.insert(allWorkspaces, ws)
	end
	table.sort(allWorkspaces, function(a, b)
		return (a.idx or 0) < (b.idx or 0)
	end)
	render()
end

-- WorkspaceActivated carries only { id, focused }, so the cached list is
-- patched rather than re-queried. Activation is per-output for is_active and
-- global for is_focused.
local function applyActivated(id: any, focused: boolean)
	local activated: any = nil
	for _, ws in ipairs(everyWorkspace) do
		if ws.id == id then
			activated = ws
			break
		end
	end
	if activated == nil then
		return
	end
	for _, ws in ipairs(everyWorkspace) do
		if ws.output == activated.output then
			ws.is_active = ws.id == id
		end
		if focused then
			ws.is_focused = ws.id == id
		end
	end
	applyWorkspaces(everyWorkspace)
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

-- ── Wiring ──────────────────────────────────────────────────────────────────

readConfig()
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

function onConfigChanged()
	readConfig()
	render()
end

function onScroll(axis: string, steps: number, startsGesture: boolean)
	local action: string = (steps > 0) and "focus-workspace-down" or "focus-workspace-up"
	noctalia.runAsync("niri msg action " .. action)
end
