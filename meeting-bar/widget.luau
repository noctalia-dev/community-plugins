--!nonstrict
local common = require("./common.luau")
local model = common.model
noctalia.setUpdateInterval(10000)

function update()
	local now = noctalia.nowMs()
	local events = common.events(now)
	local event = model.nextEvent(events or {}, now, noctalia.getConfig("prefer_current"), false)
	local horizon = noctalia.getConfig("preview_minutes")
	if event and horizon > 0 and event.startMs > now + horizon * 60000 then
		event = nil
	end
	barWidget.setVisible(not noctalia.getConfig("hide_empty") or event ~= nil or events == nil)
	barWidget.setGlyph(event and model.service(event.url) and "video" or "calendar-event")
	barWidget.setColor(event and event.startMs <= now and "primary" or "on_surface")
	if not event then
		barWidget.setText(events == nil and "Calendar…" or "")
		barWidget.setTooltip(
			events == nil and "Waiting for calendar sync · Click to open Meeting Bar"
				or "No upcoming event in the preview window · Click for your agenda"
		)
		return
	end
	local parts = {}
	if noctalia.getConfig("show_title") then
		parts[#parts + 1] =
			model.shorten(event.title ~= "" and event.title or "Untitled event", noctalia.getConfig("title_length"))
	end
	if noctalia.getConfig("show_time") then
		parts[#parts + 1] = common.time(event.startMs)
	end
	if noctalia.getConfig("show_countdown") then
		parts[#parts + 1] = model.relative(event, now)
	end
	barWidget.setText(table.concat(parts, " · "))
	barWidget.setTooltip(
		model.clean(event.title)
			.. "\n"
			.. common.dayLabel(event.startMs, now)
			.. " · "
			.. common.time(event.startMs)
			.. "–"
			.. common.time(event.endMs)
			.. "\n"
			.. model.clean(event.calendarName)
			.. "\nLeft: agenda · Right: join meeting · Middle: settings"
	)
end

function onClick()
	noctalia.togglePanel(common.id .. ":agenda")
end
function onRightClick()
	common.joinNext()
end
noctalia.state.watch("snapshot", function()
	update()
end)
