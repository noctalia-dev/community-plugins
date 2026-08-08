--!nonstrict
-- Process Monitor — bar widget. Full mode shows "CPU% RAM% · count" text; icon-only
-- mode shows just a CPU icon colored by load, with the details in the tooltip so the
-- bar stays tiny. Clicking opens the panel.

local function cfg(key)
	return noctalia.getConfig(key)
end

local function st(key)
	return noctalia.state.get(key)
end

local function tr(key, subst)
	return noctalia.tr(key, subst)
end

function update()
	local stats = st("stats")
	local cpu = stats and stats.cpu and stats.cpu.usagePercent
	local ram = stats and stats.ram and stats.ram.usagePercent
	local count = #(st("procs") or {})
	local cpuInt = math.floor(cpu or 0)
	local tooltip = tr("widget.tooltip", { cpu = cpuInt, ram = math.floor(ram or 0), n = count })

	barWidget.setGlyph(cfg("glyph") or "cpu")
	barWidget.setTooltip(tooltip)

	if cfg("icon_only") then
		barWidget.setText("")
		-- color the icon by CPU load so a glance reads the machine state
		if cpuInt >= 80 then
			barWidget.setGlyphColor("error")
		elseif cpuInt >= 50 then
			barWidget.setGlyphColor("warning")
		else
			barWidget.setGlyphColor("on_surface")
		end
		return
	end

	barWidget.setGlyphColor("on_surface")
	local text = string.format("CPU %d%%  RAM %d%%", cpuInt, math.floor(ram or 0))
	if cfg("show_count") then
		text = text .. "  ·  " .. count
	end
	barWidget.setText(text)
end

noctalia.state.watch("stats", update)
noctalia.state.watch("procs", update)
noctalia.setUpdateInterval(1000)

function onClick()
	noctalia.togglePanel("weinguyen/procmon:panel")
end
