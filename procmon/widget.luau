--!nonstrict
-- Process Monitor — bar widget. Horizontal bars show "CPU% RAM%" text (truncated
-- to fit); vertical bars are too narrow for text, so they show only a CPU icon
-- colored by load. Clicking opens the panel.

-- Read the bar orientation once at load (pomodoro pattern) so the widget renders
-- consistently instead of flickering between icon and text when isVertical() is
-- polled on every update.
local isVertical = barWidget.isVertical()

local function cfg(key)
	return noctalia.getConfig(key)
end

local function st(key)
	return noctalia.state.get(key)
end

local function tr(key, subst)
	return noctalia.tr(key, subst)
end

-- Cap the text so it fits the bar instead of spilling out the right edge.
local function trunc(s, n)
	if #s <= n then
		return s
	end
	return s:sub(1, n - 1) .. "…"
end

function update()
	local stats = st("stats")
	local cpu = stats and stats.cpu and stats.cpu.usagePercent
	local ram = stats and stats.ram and stats.ram.usagePercent
	local count = #(st("procs") or {})
	local cpuInt = math.floor(cpu or 0)
	local tooltip = tr("widget.tooltip", { cpu = cpuInt, ram = math.floor(ram or 0), n = count })

	-- Color the icon by CPU load so a glance reads the machine state.
	-- Only real theme tokens (error/secondary/on_surface) — the runtime rejects
	-- unknown names like "warning" and logs a warning per glyph per frame.
	local color = "on_surface"
	if cpuInt >= 80 then
		color = "error"
	elseif cpuInt >= 50 then
		color = "secondary"
	end

	local children = { ui.glyph({ name = cfg("glyph") or "cpu", size = 14, color = color }) }

	-- Vertical bars are too narrow for text; show only the icon so it fits.
	if not isVertical and not cfg("icon_only") then
		local text = string.format("CPU %d%% RAM %d%%", cpuInt, math.floor(ram or 0))
		if cfg("show_count") then
			text = text .. " · " .. count
		end
		table.insert(children, ui.label({ text = text, fontSize = 11 }))
	end

	local container = isVertical and ui.column or ui.row
	barWidget.render(container({ gap = 6, align = "center" }, children))
	barWidget.setTooltip(tooltip)
end

noctalia.state.watch("stats", update)
noctalia.state.watch("procs", update)
noctalia.setUpdateInterval(1000)

function onClick()
	noctalia.togglePanel("weinguyen/procmon:panel")
end
