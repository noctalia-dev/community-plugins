--!nonstrict
-- CPU Bars: one vertical bar per logical core, filling bottom-up, from
-- noctalia.systemStats().cpu.cores (plugin API 5).

-- Never request a tick shorter than this while converging on the second boundary.
local MIN_TICK_MS: number = 500
-- Aim a few ms past the boundary rather than exactly at it. Tick-to-tick scheduling jitter
-- is a handful of ms, so aiming at 0 lands half the updates just *before* the second and
-- reads the previous second's sample; this bias keeps every update on the correct side.
local TARGET_OFFSET_MS: number = 6

-- Whether a bar row has ever been drawn, so a later empty sample holds the last frame
-- rather than blanking the widget.
local hasRendered: boolean = false

-- Tick alignment state. See scheduleNextTick().
local lastOffset: number? = nil
local lastRequest: number? = nil
local lag: number = 0

local function cfg(key: string): any
	return noctalia.getConfig(key)
end

-- Aim update() at the top of each wall-clock second.
--
-- Two things push us off it, and neither is directly observable: the host adds a fixed
-- per-widget phase to every timer restart (so plugins don't all wake at once), and the
-- script runs a moment after the timer fires. So instead of guessing, measure the round
-- trip -- how far the last requested interval actually moved us -- and subtract it.
-- Converges within a few ticks and re-converges after a missed update.
local function scheduleNextTick()
	local offset = noctalia.nowMs() % 1000
	if lastOffset ~= nil and lastRequest ~= nil then
		lag = ((offset - lastOffset) - lastRequest) % 1000
	end

	local request = (TARGET_OFFSET_MS - offset - lag) % 1000
	if request < MIN_TICK_MS then
		request += 1000
	end

	lastOffset = offset
	lastRequest = request
	noctalia.setUpdateInterval(request)
end

local function buildTooltip(total: number, cores: { number }): { { key: string, value: string } }
	local rows = { { key = noctalia.tr("tooltip.total"), value = string.format("%.0f%%", total) } }
	for i, pct in ipairs(cores) do
		-- /proc/stat is 0-indexed, so core N is at Lua index N+1.
		table.insert(rows, { key = string.format("cpu%d", i - 1), value = string.format("%.0f%%", pct) })
	end
	return rows
end

function update()
	local stats = noctalia.systemStats()
	if stats == nil then
		barWidget.setVisible(false)
		scheduleNextTick()
		return
	end

	local cores: { number } = stats.cpu.cores or {}
	-- No sample yet: on the very first tick after enabling there is no previous reading to
	-- diff against. Hold whatever is already drawn instead of hiding, so a momentary gap
	-- never blanks the widget; only hide when nothing has ever been drawn.
	if #cores == 0 then
		if not hasRendered then
			barWidget.setVisible(false)
		end
		scheduleNextTick()
		return
	end
	hasRendered = true
	barWidget.setVisible(true)

	local vertical: boolean = barWidget.isVertical()
	local width: number = cfg("bar_width")
	local length: number = cfg("bar_height")
	local gap: number = cfg("bar_gap")
	local threshold: number = cfg("warn_threshold")
	local normalColor: string = cfg("normal_color")
	local warnColor: string = cfg("warn_color")
	local trackColor: string = cfg("track_color")

	local children = {}
	if cfg("show_glyph") then
		table.insert(children, ui.glyph({ name = "cpu", size = 14, color = "on_surface_variant" }))
	end

	for i, pct in ipairs(cores) do
		local hot: boolean = pct >= threshold
		-- Height is strictly proportional, with no minimum: an idle core shows an empty
		-- track, not a sliver. Anything under half a pixel rounds away.
		local filled: number = math.floor((length * pct / 100) + 0.5)
		local lit: boolean = filled > 0
		local fill: string = hot and warnColor or normalColor
		-- The fill colour is part of the key: the host reconciler is retained-mode, and
		-- keying by state guarantees the box is rebuilt when a core crosses the threshold.
		local key: string = `core{i}-{hot and "hot" or "ok"}`

		if vertical then
			-- On a vertical bar the widget grows downward, so each core is a horizontal
			-- bar filling from the left.
			table.insert(
				children,
				ui.row({
					key = key,
					width = length,
					height = width,
					radius = 1,
					fill = `{trackColor}/0.15`,
					justify = "start",
				}, {
					-- Kept in the tree (hidden) rather than dropped, so the retained-mode
					-- reconciler diffs a stable child list. Height never reaches 0.
					ui.box({
						width = math.max(1, filled),
						height = width,
						radius = 1,
						fill = fill,
						visible = lit,
					}),
				})
			)
		else
			table.insert(
				children,
				ui.column({
					key = key,
					width = width,
					height = length,
					radius = 1,
					fill = `{trackColor}/0.15`,
					justify = "end",
				}, {
					ui.box({
						width = width,
						height = math.max(1, filled),
						radius = 1,
						fill = fill,
						visible = lit,
					}),
				})
			)
		end
	end

	local container = vertical and ui.column or ui.row
	barWidget.render(container({ gap = gap, align = "center" }, children))
	barWidget.setTooltip(buildTooltip(stats.cpu.total, cores))

	scheduleNextTick()
end
