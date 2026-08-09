--!nonstrict
-- Process Monitor — panel. Renders the process table + live system bars.
-- Sort/filter state lives here (a view concern); data comes from the service.

local sortKey = "cpu"
local sortDir = "desc"
local filter = ""
local filterRev = 0 -- bumped to reseed the filter input so it can grab focus
local focusFilterOnRender = false -- one-shot: focuses the filter on the next render

-- Per-column display unit: "pct" shows percent, "raw" shows the absolute
-- figure. Clicking the %CPU/%MEM header toggles it. MEM raw = RSS in MB; CPU
-- raw = cumulative CPU time (ps time=), a real number distinct from the %.
-- (ponytail: a per-interval CPU% needs two /proc/pid/stat samples and a diff,
-- too heavy for the update budget - the cumulative time is a free proxy.)
local cpuUnit = "pct"
local memUnit = "pct"

-- Cap how many rows we render so a single rebuild stays under the panel
-- update CPU budget. Rows are shown in sorted order, so the highest-sorting
-- processes are always visible. (200 rows * ~7 ui nodes blew the budget.)
local MAX_ROWS = 80

-- Keyboard navigation state (btop-style): selectedIdx is the cursor position
-- in the currently visible (filtered/sorted/trimmed) list; 0 means nothing is
-- selected. Ctrl+D kills the selected process directly.
local selectedIdx = 0

-- Cheap fingerprint of everything the table shows, so the 1s tick only rebuilds
-- the heavy UI tree when the data actually changed. Rebuilding 200 rows every
-- second exceeded the panel update CPU budget; sampling the first SIG_SAMPLE
-- rows (ps output is pid-ordered) catches CPU/mem/rss movement without the cost.
local SIG_SAMPLE = 40
local lastSig = nil

-- Throttle data-driven renders. The service can sample faster than the panel can
-- rebuild its table, and every state.set fires a watch: at 250ms that was ~16
-- full rebuilds/sec of 80 rows, which blew the panel update CPU budget and got
-- the panel disabled. 2000ms bounds rebuilds to 1/2s, well under the budget.
-- The service samples stats every 1s and the process table every 2s, so a 2s
-- rebuild floor keeps the panel in lockstep with the table without re-rendering
-- the whole 80-row tree on every stats tick.
-- User interactions (toggle/filter/sort) still render() immediately; only the
-- data watches and the tick go through maybeRender().
local lastRenderMs = 0
local MIN_RENDER_MS = 2000

-- Kill column is a fixed width at the end of every row; all other columns are
-- flexGrow shares so the header and data rows always align and never overflow.
local KILL_W = 30

local function cfg(key)
	return noctalia.getConfig(key)
end

local function st(key)
	return noctalia.state.get(key)
end

-- Draft value while the Refresh slider is being dragged; committed to state on
-- release (audio-switcher pattern). The service watches "refreshMs" and re-arms
-- its sampler timer, which is what actually changes the fetch speed. Declared
-- after cfg/st (Luau: forward refs to a later local compile as globals -> nil).
local refreshDraft = nil
local function refreshMs()
	return tonumber(st("refreshMs") or cfg("refresh_interval")) or 1000
end
local function commitRefresh()
	if refreshDraft then
		noctalia.state.set("refreshMs", refreshDraft)
		refreshDraft = nil
	end
end

local function signature()
	local stats = st("stats") or {}
	local cpuPct = stats.cpu and stats.cpu.usagePercent or 0
	local ramPct = stats.ram and stats.ram.usagePercent or 0
	local procs = st("procs") or {}
	local n = #procs
	local s = tostring(n) .. "|" .. filter .. "|" .. sortKey .. sortDir
		.. "|" .. tostring(cpuPct) .. "|" .. tostring(ramPct)
		.. "|" .. cpuUnit .. memUnit
	local upto = n < SIG_SAMPLE and n or SIG_SAMPLE
	for i = 1, upto do
		local p = procs[i]
		if p then
			s = s .. "|" .. tostring(p.pid) .. ":" .. tostring(math.floor((p.cpu or 0) * 10))
				.. ":" .. tostring(math.floor((p.mem or 0) * 10))
				.. ":" .. tostring(math.floor((p.rssMb or 0) / 16))
		end
	end
	return s
end

local function tr(key, subst)
	return noctalia.tr(key, subst)
end

local function fmtMem(mb)
	if mb == nil then
		return "—"
	end
	if mb >= 1024 then
		return string.format("%.1fG", mb / 1024)
	end
	return string.format("%.0fM", mb)
end

local function trunc(s, n)
	if #s <= n then
		return s
	end
	return s:sub(1, n - 1) .. "…"
end

local function killPid(pid)
	local cmd = cfg("kill_command")
	if cmd == "" then
		cmd = "kill -TERM"
	end
	noctalia.runAsync(cmd .. " " .. pid)
end

-- ── stats bars ──────────────────────────────────────────────────────────────

local function statBar(label, glyph, pct, sub)
	local pct0 = math.max(0, math.min(100, pct or 0))
	return ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
		ui.glyph({ name = glyph, size = 16 }),
		ui.label({ text = label, fontSize = 11, color = "on_surface_variant" }),
		ui.progress({ progress = pct0 / 100, flexGrow = 1, height = 8 }),
		ui.label({ text = sub, fontSize = 11, textAlign = "end" }),
	})
end

local function renderStats()
	local stats = st("stats") or {}
	local cpu = stats.cpu
	local ram = stats.ram
	local swap = stats.swap

	local swapPct = 0
	local swapSub = "—"
	if swap and swap.totalMb and swap.totalMb > 0 then
		swapPct = swap.usedMb / swap.totalMb * 100
		swapSub = string.format("%.0f/%.0fM", swap.usedMb, swap.totalMb)
	end

	local loadSub = "—"
	if stats.loadAvg then
		loadSub = string.format("%.2f %.2f %.2f", stats.loadAvg[1], stats.loadAvg[2], stats.loadAvg[3])
	end

	-- The render path must never throw: any stats field may be nil (seed
	-- stats, or a sample that skipped a field), so guard every format arg.
	local cpuSub = (cpu and cpu.usagePercent ~= nil) and string.format("%.0f%%", cpu.usagePercent) or "—"
	local ramSub = "—"
	if ram and ram.usedMb ~= nil and ram.totalMb ~= nil then
		ramSub = string.format("%.0f/%.0fM", ram.usedMb, ram.totalMb)
	end

	return ui.column({ gap = 4, fill = "surface_variant/0.35", radius = 10, paddingV = 8, paddingH = 10 }, {
		statBar("CPU", "cpu", cpu and cpu.usagePercent, cpuSub),
		statBar("RAM", "memory", ram and ram.usagePercent, ramSub),
		ui.row({ gap = 12, align = "center" }, {
			statBar("SWAP", "archive", swapPct, swapSub),
			ui.label({ text = tr("panel.load") .. ": " .. loadSub, fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
		}),
	})
end

-- ── process rows ────────────────────────────────────────────────────────────

-- Column layout, shared by header and data rows so they line up.
-- { flexGrow, textAlign } for each column; cmd is the wide flexible one.
local COLS = {
	{ 1.0, "end" }, -- PID
	{ 1.0, "end" }, -- CPU
	{ 1.0, "end" }, -- MEM
	{ 1.2, "end" }, -- RSS
	{ 0.7, "center" }, -- STAT
	{ 5.0, "start" }, -- COMMAND
}

-- ui.select drives sorting. Order must match the settings.sort_by options.
local SORT_KEYS = { "cpu", "mem", "pid", "cmd" }
local function sortIndex(key)
	for i, k in ipairs(SORT_KEYS) do
		if k == key then
			return i - 1
		end
	end
	return 0
end

local function toggleCpuUnit()
	cpuUnit = cpuUnit == "pct" and "raw" or "pct"
	render()
end

local function toggleMemUnit()
	memUnit = memUnit == "pct" and "raw" or "pct"
	render()
end

local function dataRow(p, idx)
	local stat = p.stat or "?"
	local statColor = stat:find("Z") and "error" or "on_surface"
	local memCell = memUnit == "raw" and fmtMem(p.rssMb) or string.format("%.1f", p.mem)
	local cpuCell = cpuUnit == "raw" and (p.cpuTime or "—") or string.format("%.1f", p.cpu)
	local cells = {
		{ tostring(p.pid) },
		{ cpuCell },
		{ memCell },
		{ fmtMem(p.rssMb) },
		{ stat, statColor },
	}

	-- Cursor highlight mirrors the signal picker: a translucent fill plus the
	-- text flipped to primary. Zombie rows keep their error tint so the warning
	-- survives selection. The row key bakes in the selection state so a moved
	-- cursor rebuilds exactly the rows whose selection flipped -- a stable pid
	-- key would leave the fill stuck on rows the cursor passed over.
	local selected = idx == selectedIdx
	local function cellColor(c)
		local color = c[2] or "on_surface"
		if selected and color ~= "error" then
			return "primary"
		end
		return color
	end

	local children = {}
	for i, c in ipairs(cells) do
		table.insert(children, ui.label({
			text = c[1],
			flexGrow = COLS[i][1],
			textAlign = COLS[i][2],
			fontSize = 11,
			maxLines = 1,
			color = cellColor(c),
		}))
	end

	-- COMMAND column (flexGrow wide)
	table.insert(children, ui.label({
		text = trunc(p.cmd or "?", 80),
		flexGrow = COLS[6][1],
		textAlign = "start",
		fontSize = 11,
		maxLines = 1,
		color = selected and "primary" or "on_surface",
	}))

	-- Kill button (fixed trailing width)
	table.insert(children, ui.button({
		glyph = "square-x",
		glyphSize = 14,
		variant = "ghost",
		controlSize = "sm",
		width = KILL_W,
		tooltip = tr("panel.kill_tip", { pid = p.pid }),
		onClick = function()
			killPid(p.pid)
		end,
	}))

	return ui.row({
		key = tostring(p.pid) .. (selected and "|sel" or ""),
		gap = 6,
		align = "center",
		fill = selected and "primary/0.25" or nil,
		radius = 6,
		paddingH = 8,
		paddingV = 2,
		onClick = function()
			selectedIdx = idx
			render()
		end,
	}, children)
end

-- Header: clickable cells use ui.row onClick (keeps layout, so the grid stays
-- aligned with the data rows). CPU/MEM headers toggle their column's display
-- unit (% vs actual). Built fresh on every render so titles track the mode.
local HEADER_LABELS = { "panel.col.pid", "panel.col.cpu", "panel.col.mem", "panel.col.rss", "panel.col.stat", "panel.col.cmd" }
local function buildHeader()
	local children = {}
	for i, col in ipairs(COLS) do
		local label = {
			text = tr(HEADER_LABELS[i]),
			fontSize = 11,
			maxLines = 1,
			color = "on_surface_variant",
		}
		if i == 2 then -- %CPU header toggles percent vs raw
			label.text = cpuUnit == "raw" and tr("panel.col.cpu_raw") or tr("panel.col.cpu")
			children[#children + 1] = ui.row({
				flexGrow = col[1],
				align = "center",
				justify = col[2],
				onClick = toggleCpuUnit,
			}, { ui.label(label) })
		elseif i == 3 then -- %MEM header toggles percent vs MB
			label.text = memUnit == "raw" and tr("panel.col.mem_raw") or tr("panel.col.mem")
			children[#children + 1] = ui.row({
				flexGrow = col[1],
				align = "center",
				justify = col[2],
				onClick = toggleMemUnit,
			}, { ui.label(label) })
		else
			label.flexGrow = col[1]
			label.textAlign = col[2]
			children[#children + 1] = ui.label(label)
		end
	end
	-- trailing spacer matching the kill column
	children[#children + 1] = ui.spacer({ width = KILL_W })
	return children
end

-- ── main render ─────────────────────────────────────────────────────────────

-- The currently visible rows: filtered by `filter`, sorted by the active
-- column, capped at MAX_ROWS. Shared by render() and the keyboard handlers so
-- onKey resolves the cursor position against the exact same list the panel
-- draws (never trust an index computed from a stale render).
local function visibleList()
	local procs = st("procs") or {}
	local f = filter:lower()
	local list = {}
	for _, p in ipairs(procs) do
		if f ~= "" then
			local cmd = (p.cmd or ""):lower()
			local user = (p.user or ""):lower()
			local pid = tostring(p.pid)
			if not (cmd:find(f, 1, true) or user:find(f, 1, true) or pid:find(f, 1, true)) then
				continue
			end
		end
		table.insert(list, p)
	end

	table.sort(list, function(a, b)
		local av, bv
		if sortKey == "pid" then
			av, bv = a.pid, b.pid
		elseif sortKey == "mem" then
			av, bv = a.mem, b.mem
		elseif sortKey == "rss" then
			av, bv = a.rssMb, b.rssMb
		elseif sortKey == "cmd" then
			av, bv = (a.cmd or ""), (b.cmd or "")
		else
			av, bv = a.cpu, b.cpu
		end
		if av == bv then
			return a.pid < b.pid
		end
		if sortDir == "asc" then
			return av < bv
		end
		return av > bv
	end)

	-- Bound the rendered rows so a 500-process box stays responsive.
	if #list > MAX_ROWS then
		local shown = {}
		for i = 1, MAX_ROWS do
			shown[i] = list[i]
		end
		return shown, #list
	end
	return list, #list
end

function render()
	local wantsFocus = focusFilterOnRender
	focusFilterOnRender = false

	local shown, totalCount = visibleList()
	-- Keep the cursor inside the visible list. A shrunk list (filter/sort/data
	-- change) clamps up; an empty list clears the cursor.
	if #shown == 0 then
		selectedIdx = 0
	elseif selectedIdx > #shown then
		selectedIdx = #shown
	elseif selectedIdx == 0 then
		selectedIdx = 1
	end

	local body
	if #shown == 0 then
		body = ui.row({ align = "center", justify = "center", flexGrow = 1 }, {
			ui.label({ text = tr("panel.no_processes"), color = "on_surface_variant" }),
		})
	else
		local itemRows = {}
		for i, p in ipairs(shown) do
			table.insert(itemRows, dataRow(p, i))
		end
		body = ui.scroll({ flexGrow = 1, gap = 2, align = "stretch" }, itemRows)
	end

	local refreshedAt = (st("refreshedAtMs") or 0) / 1000
	local refreshedStr = refreshedAt > 0 and os.date("%H:%M:%S", refreshedAt) or "—"
	local err = st("err")

	panel.render(ui.column({ padding = 12, gap = 8, flexGrow = 1, align = "stretch" }, {
		ui.row({ align = "center", justify = "space_between" }, {
			ui.label({ text = tr("panel.title"), fontSize = 15, fontWeight = "bold" }),
			ui.label({ text = tr("panel.refreshed_at", { time = refreshedStr }), fontSize = 11, color = "on_surface_variant" }),
		}),
		renderStats(),
		ui.row({ gap = 6, align = "center" }, {
			ui.input({
				key = "filter-" .. filterRev,
				value = filter,
				placeholder = tr("panel.search_placeholder"),
				controlSize = "sm",
				flexGrow = 1,
				focus = wantsFocus,
				onChange = function(v)
					filter = v
					render()
				end,
			}),
			ui.select({
				options = {
					tr("settings.sort_by.options.cpu"),
					tr("settings.sort_by.options.mem"),
					tr("settings.sort_by.options.pid"),
					tr("settings.sort_by.options.cmd"),
				},
				selectedIndex = sortIndex(sortKey),
				width = 110,
				controlSize = "sm",
				onChange = function(idx)
					sortKey = SORT_KEYS[idx + 1]
					render()
				end,
			}),
			ui.button({
				glyph = sortDir == "asc" and "arrow-up" or "arrow-down",
				tooltip = sortDir == "asc" and tr("panel.sort_asc") or tr("panel.sort_desc"),
				controlSize = "sm",
				variant = "ghost",
				onClick = function()
					sortDir = sortDir == "asc" and "desc" or "asc"
					render()
				end,
			}),
		}),
		ui.row({ gap = 6, align = "center" }, buildHeader()),
		body,
		ui.row({ gap = 10, align = "center" }, {
			ui.label({ text = tr("panel.count", { n = totalCount }), fontSize = 11, color = "on_surface_variant" }),
			ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
				ui.label({ text = tr("panel.refresh"), fontSize = 11, color = "on_surface_variant" }),
				ui.slider({
					min = 500, max = 5000, step = 500, value = math.max(500, math.min(5000, refreshMs())),
					flexGrow = 1, controlSize = "sm",
					onChange = function(v) refreshDraft = math.floor(tonumber(v) or 0) end,
					onDragEnd = commitRefresh,
				}),
				ui.label({ text = refreshMs() .. "ms", fontSize = 11, textAlign = "end", width = 48 }),
			}),
			ui.label({ text = err, fontSize = 11, color = "error" }),
		}),
		ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = tr("panel.keys_hint"), fontSize = 10, color = "on_surface_variant" }),
		}),
		}))
		lastSig = signature()
	end

-- Data-driven render: only rebuild when the visible data actually changed AND
-- enough time has passed since the last rebuild. Defined after render/signature
-- (Luau: forward refs to a later local compile as globals -> nil).
local function maybeRender()
	local now = noctalia.nowMs()
	if now - lastRenderMs < MIN_RENDER_MS then
		return
	end
	if signature() ~= lastSig then
		lastRenderMs = now
		render()
	end
end

noctalia.state.watch("procs", maybeRender)
noctalia.state.watch("stats", maybeRender)
noctalia.state.watch("refreshedAtMs", maybeRender)
noctalia.state.watch("err", maybeRender)
noctalia.state.watch("refreshMs", function()
	-- Track the fetch speed on the panel's own tick so the table stays live when
	-- the user drops the interval below the 1s second-tick floor.
	noctalia.setUpdateInterval(refreshMs())
	render()
end)

-- Periodic re-render on the panel tick (anilist/nix-monitor pattern). Belt and
-- suspenders on top of state.watch: even if a cross-entry watch is missed in
-- some shell versions, the list refreshes on its own. Track the service refresh
-- interval so the panel keeps up when the user drops it for more real-time
-- updates. setWantsSecondTicks is safe at this API level (9router/mawaqit use it
-- at plugin_api 3).
noctalia.setUpdateInterval(refreshMs())
panel.setWantsSecondTicks(true)

function update()
	maybeRender()
end

-- Keyboard control (btop-style). Chords must be listed in the panel's
-- `capture_keys` in plugin.toml, otherwise onKey never fires.
--
-- List mode: up/down move the cursor, Ctrl+D opens the signal picker for the
-- selected process, Ctrl+F focuses the filter box. Menu mode: up/down move the
-- signal highlight, Return sends it, Ctrl+D or Esc closes the menu. Ctrl-modifier
-- chords are used (not bare letters) so they never collide with the filter
-- input's text keys.
--
-- Keyboard chords. The runtime delivers chords as clean down/up pairs and
-- does not tag auto-repeat events, so holding a chord fires repeated presses.
-- The keyHeld guard (release-based, no time gate) blocks those repeats until
-- the release arrives; genuine taps clear on release, so they stay instant.
-- The short TTL only covers a rare missed release, never a tap.
local keyHeld = {}
local KEY_HELD_TTL_MS = 150
local function keyFresh(chord)
	local now = noctalia.nowMs()
	local heldAt = keyHeld[chord]
	if heldAt and now - heldAt < KEY_HELD_TTL_MS then
		return false
	end
	keyHeld[chord] = now
	return true
end

function onKey(chord, pressed)
	if not pressed then
		keyHeld[chord] = nil
		return
	end
	-- Arrow keys repeat freely (holding Down scrolls the table / menu); the
	-- guard only covers action chords where an auto-repeat would flip state.
	if chord ~= "up" and chord ~= "down" and not keyFresh(chord) then
		return
	end

	if chord == "up" or chord == "down" then
		local list = visibleList()
		if #list > 0 then
			selectedIdx = math.max(1, math.min(#list, selectedIdx + (chord == "down" and 1 or -1)))
			render()
		end
		return
	end

	if chord == "ctrl+d" then
		-- Kill the selected process directly (same configured kill_command the
		-- row's ✕ button runs). No confirmation, matching the ✕ button.
		local list = visibleList()
		local p = list[selectedIdx]
		if p then
			killPid(p.pid)
		end
		return
	end

	if chord == "ctrl+f" then
		filterRev += 1
		focusFilterOnRender = true
		render()
		return
	end

	if chord == "escape" then
		-- Swallow Escape so it never closes the whole panel.
		return
	end
end

function onOpen(_context)
	sortKey = cfg("sort_by") or "cpu"
	sortDir = "desc"
	filter = ""
	-- No auto-focus on the filter: the panel opens in list mode so the arrow
	-- keys and Ctrl+D work immediately (btop-style). Press Ctrl+F to start
	-- typing a filter; the box is focused then.
	selectedIdx = 0
	render()
end
