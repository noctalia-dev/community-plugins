--!nonstrict
local common = require("./common.luau")
local model = common.model
local opened, query, tab = false, "", "agenda"
local selectedCalendar = ""
local message = ""
local render

local function label(text, props)
	props = props or {}
	props.text = text
	return ui.label(props)
end

local function button(text, glyph, handler, extra)
	local props = extra or {}
	props.text, props.glyph, props.onClick = text, glyph, handler
	props.controlSize = "sm"
	return ui.button(props)
end

local function open(event)
	if common.openLink(event.url) then
		panel.close()
	end
end

local function card(event, now, bookmark)
	local name = model.clean(event.title)
	if name == "" then
		name = "Untitled event"
	end
	local service = model.service(event.url)
	local validLink = model.url(event.url) ~= nil
	local active = not bookmark and not event.allDay and event.startMs <= now and event.endMs > now
	local details = {}
	if not bookmark then
		details[#details + 1] = event.allDay and "All day"
			or common.time(event.startMs)
				.. "–"
				.. common.time(event.endMs)
				.. " · "
				.. model.relative(event, now)
		details[#details + 1] = model.clean(event.calendarName)
		if event.location and event.location ~= "" and not model.url(event.location) then
			details[#details + 1] = model.clean(event.location)
		end
	end
	if service then
		details[#details + 1] = service
	end
	local controls = {
		button(service and "Join" or "Open link", service and "video" or "external-link", function()
			open(event)
		end, { enabled = validLink, variant = active and "primary" or "outline" }),
		button("", "copy", function()
			common.copyLink(event)
			message = "Link copied"
			render()
		end, { enabled = validLink, tooltip = "Copy link", variant = "ghost" }),
		button("", common.bookmarked(event) and "star-filled" or "star", function()
			common.toggleBookmark(event)
		end, { enabled = validLink, tooltip = "Save or remove favorite", variant = "ghost" }),
	}
	return ui.column({
		key = bookmark and event.url or model.key(event),
		padding = 12,
		gap = 7,
		radius = 10,
		fill = "surface",
		borderWidth = 1,
		border = active and "primary" or "on_surface/0.2",
	}, {
		ui.row({ gap = 8, align = "center" }, {
			ui.box({
				width = 4,
				height = 24,
				radius = 2,
				fill = event.colorHex ~= "" and event.colorHex or "primary",
			}),
			label(name, { flexGrow = 1, maxLines = 2, fontWeight = "bold", fontSize = 15 }),
		}),
		label(table.concat(details, " · "), { maxLines = 3, color = "on_surface_variant", fontSize = 12 }),
		ui.row({ gap = 6 }, controls),
	})
end

render = function()
	if not opened then
		return
	end
	local now = noctalia.nowMs()
	local calendarEvents = common.events(now, nil, false)
	local names, known = { "All calendars" }, {}
	for _, event in ipairs(calendarEvents or {}) do
		local name = event.calendarName or ""
		if name ~= "" and not known[name] then
			names[#names + 1] = name
			known[name] = true
		end
	end
	table.sort(names, function(a, b)
		if a == b then
			return false
		end
		if a == "All calendars" then
			return true
		end
		if b == "All calendars" then
			return false
		end
		return a < b
	end)
	local selectedIndex = 0
	for i, name in ipairs(names) do
		if name == selectedCalendar then
			selectedIndex = i - 1
		end
	end
	if selectedIndex == 0 then
		selectedCalendar = ""
	end
	local events = common.events(now, selectedCalendar)
	local rows, day, count = {}, nil, 0
	local source = tab == "favorites" and common.bookmarks() or (events or {})
	for _, event in ipairs(source) do
		local text = model.clean(event.title)
			.. " "
			.. model.clean(event.calendarName)
			.. " "
			.. model.clean(event.location)
		if query == "" or text:lower():find(query:lower(), 1, true) then
			if tab ~= "favorites" then
				local eventDay = common.dayKey(math.max(event.startMs, now))
				if eventDay ~= day then
					day = eventDay
					rows[#rows + 1] = label(
						common.dayLabel(math.max(event.startMs, now), now),
						{ fontWeight = "bold", color = "primary", fontSize = 13 }
					)
				end
			end
			rows[#rows + 1] = card(event, now, tab == "favorites")
			count = count + 1
		end
	end
	if count == 0 then
		local empty = "No events match these filters."
		if tab == "favorites" then
			empty = "Save a meeting with the star button to keep its link here."
		elseif events == nil then
			empty = "Waiting for calendar sync. Connect an account in Noctalia Settings → Calendar."
		end
		rows[#rows + 1] = label(empty, { maxLines = 4, color = "on_surface_variant" })
	end
	panel.render(ui.column({ padding = 16, gap = 12, flexGrow = 1 }, {
		ui.row({ gap = 8, align = "center" }, {
			ui.glyph({ name = "calendar-event", size = 22, color = "primary" }),
			label("Meeting Bar", { fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
			button("", "settings", function()
				panel.close()
				noctalia.openSettings()
			end, { tooltip = "Meeting Bar settings", variant = "ghost" }),
			button("", "x", function()
				panel.close()
			end, { tooltip = "Close", variant = "ghost" }),
		}),
		ui.row({ gap = 6 }, {
			button("Agenda", "calendar", function()
				tab = "agenda"
				message = ""
				render()
			end, { selected = tab == "agenda", variant = "ghost" }),
			button("Favorites", "star", function()
				tab = "favorites"
				message = ""
				render()
			end, { selected = tab == "favorites", variant = "ghost" }),
			ui.spacer({}),
			button("New meeting", "plus", function()
				common.createMeeting()
			end, { variant = "ghost" }),
		}),
		ui.input({
			key = "search",
			value = query,
			placeholder = "Search events…",
			onChange = function(value)
				query = value
				render()
			end,
		}),
		ui.select({
			key = "calendar-filter",
			visible = tab == "agenda",
			options = names,
			selectedIndex = selectedIndex,
			onChange = function(value)
				local index = tonumber(value) or 0
				selectedCalendar = index > 0 and names[index + 1] or ""
				render()
			end,
		}),
		ui.scroll({ key = "agenda-list", flexGrow = 1, gap = 10 }, rows),
		ui.row({ gap = 8, align = "center" }, {
			label(
				message ~= "" and message
					or tostring(count)
						.. (
							tab == "favorites" and (count == 1 and " favorite" or " favorites")
							or (count == 1 and " event" or " events")
						),
				{ flexGrow = 1, fontSize = 12, color = "on_surface_variant" }
			),
			button("Calendar", "calendar", function()
				panel.close()
				common.calendar()
			end, { variant = "ghost" }),
			button("Join next", "video", function()
				common.joinNext()
			end, { enabled = common.nextEvent(now, true) ~= nil, variant = "primary" }),
		}),
	}))
end

function onOpen()
	opened, message = true, ""
	panel.setWantsSecondTicks(true)
	render()
end
function onClose()
	opened = false
end
local lastMinute
function update()
	local minute = math.floor(noctalia.nowMs() / 60000)
	if minute ~= lastMinute then
		lastMinute = minute
		render()
	end
end
noctalia.state.watch("snapshot", function()
	render()
end)
noctalia.state.watch("bookmarks", function()
	render()
end)
