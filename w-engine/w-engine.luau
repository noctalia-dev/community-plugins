--!nonstrict
-- W-Engine bar widget — opens the panel, and reflects what the service is doing.

local STATUS_KEY = "w_engine_status"

local function refresh(status)
	local outputs = type(status) == "table" and status.outputs or nil
	local cycling = false
	local playing = 0
	if type(outputs) == "table" then
		for _, state in pairs(outputs) do
			if type(state) == "table" then
				if state.cycle_enabled then
					cycling = true
				end
				if state.current then
					playing += 1
				end
			end
		end
	end

	barWidget.setGlyph("movie")
	if playing == 0 then
		barWidget.setTooltip(noctalia.tr("widget.idle"))
	elseif cycling then
		barWidget.setTooltip(noctalia.tr("widget.cycling"))
	else
		barWidget.setTooltip(noctalia.tr("widget.playing"))
	end
end

function onClick()
	noctalia.togglePanel("tadomika_ari/w-engine:w-engine-panel")
end

noctalia.state.watch(STATUS_KEY, refresh)
refresh(noctalia.state.get(STATUS_KEY))
