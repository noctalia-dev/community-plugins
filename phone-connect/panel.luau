--!nonstrict
-- Panel controller and tab views. The service owns phone data; this module
-- owns selection, search, layout and drafts in shared session memory.
-- Each tab builder returns a native UI tree. render is the only paint entry.
local Model = require("./messaging-model.luau")
local preview = nil -- Read-only synthetic data, only set by the preview IPC event.
-- state.get decodes a fresh copy. Keep the snapshots delivered by state.watch
-- so typing and navigation never decode the entire message/contact history.
local shared = {}
-- Native tree construction also counts against the 25 ms callback budget.
-- A wide panel renders both lists; keep each visible page small. The backend
-- still fetches history in batches of 50, independent of these display pages.
local messagePageSize, threadPageSize = 25, 25
local translations = {}
local function t(key)
	return translations[key] or key
end

local function send(cmd)
	if preview then
		return
	end
	local sequence = math.max(noctalia.nowMs() * 1000, (noctalia.state.get("pc.sequence") or 0) + 1)
	noctalia.state.set("pc.sequence", sequence)
	cmd.seq = sequence
	cmd.requestId = tostring(sequence)
	noctalia.state.set("pc.cmd", cmd)
end

local mediaView = require("./media-view.luau").new({ ui = ui, api = noctalia, t = t, send = send })
local opened = false
local preferences = noctalia.state.get("pc.view")
	or { tab = "messages", compact = false, devices = {} }
local previewPreferences = nil
local confirmUnpair = nil
local editingName = nil
local nameValue = ""

-- View state survives panel closure. Preview uses a separate preference table
-- and restores the original one on close, without altering backend state.
local function saveView()
	noctalia.state.set("pc.view", preferences)
end

local function viewFor(id)
	if not preferences.devices[id] then
		preferences.devices[id] = { search = "", contactSearch = "" }
	end
	return preferences.devices[id]
end

-- Targets include device and conversation/notification identity. rev changes
-- after an accepted send so the native input is recreated with cleared text.
local function draftFor(target)
	local drafts = noctalia.state.get("pc.drafts") or {}
	if not drafts[target] then
		drafts[target] = { text = "", rev = 0 }
		noctalia.state.set("pc.drafts", drafts)
	end
	return drafts[target]
end

local function setDraft(target, value)
	local drafts = noctalia.state.get("pc.drafts") or {}
	local draft = drafts[target] or { rev = 0 }
	draft.text = value
	drafts[target] = draft
	noctalia.state.set("pc.drafts", drafts)
end

local function label(text, props)
	props = props or {}
	props.text = text
	props.color = props.color or "on_surface"
	return ui.label(props)
end

local function button(key, glyph, action, props)
	props = props or {}
	props.text = t(key)
	props.glyph = glyph
	props.onClick = action
	props.controlSize = props.controlSize or "sm"
	props.variant = props.variant or "outline"
	return ui.button(props)
end

local function icon(glyph, tooltip, action)
	return ui.button({
		glyph = glyph,
		tooltip = t(tooltip),
		onClick = action,
		variant = "ghost",
		controlSize = "sm",
		width = 34,
	})
end

local function note(text, error)
	return label(
		text,
		{ fontSize = 12, maxLines = 8, color = error and "error" or "on_surface_variant" }
	)
end

local function timeText(date)
	return noctalia.formatTime("%b %d · %H:%M", math.floor((date or 0) / 1000))
end

local function empty(glyph, title, body)
	return ui.column(
		{ gap = 12, padding = 24, flexGrow = 1, justify = "center", align = "center" },
		{
			ui.glyph({ name = glyph, size = 32, color = "primary" }),
			label(
				t(title),
				{ fontSize = 16, fontWeight = "medium", textAlign = "center", maxLines = 3 }
			),
			note(t(body)),
		}
	)
end

local function stateNote(deviceMessages, feature)
	if not deviceMessages.connected then
		return note(t("chat.offline"))
	end
	local status = deviceMessages.status[feature]
	if status == "unsupported" then
		return note(t("chat.unsupported"))
	end
	if status == "loading" then
		return note(t("chat.loading"))
	end
	if status == "failed" then
		return note(t("chat.failed"), true)
	end
	return nil
end

local function sync(id)
	send({ op = "sync", device = id })
end

local function selectThread(id, thread)
	local view = viewFor(id)
	view.thread = thread
	view.recipient = nil
	view.composing = false
	view.showThread = true
	view.messageOffset = 0
	preferences.tab = "messages"
	saveView()
	send({ op = "history", device = id, thread = thread, start = 0 })
	render()
end

local function compose(id, number, name)
	local view = viewFor(id)
	view.thread = nil
	view.recipient = number
	view.recipientName = name
	view.composing = true
	view.showThread = true
	preferences.tab = "messages"
	saveView()
	render()
end

-- Return inclusive bounds plus optional controls. Filtering happens before
-- pagination, so searches cover the complete cached list, not just this page.
local function pageRange(view, field, count, size)
	local page = math.min(view[field] or 1, math.max(1, math.ceil(count / size)))
	local controls
	if count > size then
		controls = ui.row({ gap = 8, align = "center" }, {
			button("chat.previous", "chevron-left", function()
				view[field] = page - 1
				saveView()
				render()
			end, { enabled = page > 1, variant = "ghost" }),
			label(
				page .. " / " .. math.ceil(count / size),
				{ flexGrow = 1, textAlign = "center", fontSize = 12 }
			),
			button("chat.next", "chevron-right", function()
				view[field] = page + 1
				saveView()
				render()
			end, { enabled = page * size < count, variant = "ghost" }),
		})
	end
	return (page - 1) * size + 1, math.min(page * size, count), controls, page
end

local function header(devices, order, device)
	local aliases = shared["pc.aliasMap"] or {}
	local names, selected = {}, 1
	for index, id in ipairs(order) do
		local candidate = devices[id]
		table.insert(names, aliases[id] or (candidate and candidate.name) or id)
		if device and id == device.id then
			selected = index
		end
	end
	local children = { ui.glyph({ name = "device-mobile", size = 22, color = "primary" }) }
	if #names > 1 then
		table.insert(
			children,
			ui.select({
				options = names,
				selectedIndex = selected - 1,
				flexGrow = 1,
				onChange = function(index)
					local id = order[tonumber(index) + 1]
					if id then
						send({ op = "select", device = id })
						sync(id)
					end
				end,
			})
		)
	else
		table.insert(
			children,
			label(
				names[1] or t("panel.title"),
				{ fontSize = 17, fontWeight = "bold", flexGrow = 1, maxLines = 1 }
			)
		)
	end
	if device then
		local status = device.isPaired and device.isReachable and "status.connected"
			or "status.offline"
		local info = t(status)
		if type(device.batteryCharge) == "number" and device.batteryCharge >= 0 then
			info = info .. " · " .. device.batteryCharge .. "%"
		end
		if device.networkType and device.networkType ~= "" and not preferences.compact then
			info = info .. " · " .. device.networkType
		end
		table.insert(
			children,
			label(info, { fontSize = 11, color = "on_surface_variant", maxLines = 1 })
		)
	end
	table.insert(
		children,
		icon(
			preferences.compact and "layout-columns" or "layout-list",
			"chat.toggle_compact",
			function()
				preferences.compact = not preferences.compact
				saveView()
				render()
			end
		)
	)
	table.insert(
		children,
		icon("refresh", "action.refresh", function()
			send({ op = "refresh" })
			if device then
				sync(device.id)
			end
		end)
	)
	table.insert(
		children,
		icon("x", "panel.close", function()
			panel.close()
		end)
	)
	return ui.row({ gap = 10, align = "center" }, children)
end

-- Draft edits stay local. Only the service clears accepted text; pending
-- requests disable the input and Send to prevent duplicate submissions.
local function composer(id, target, state, command, allowed)
	local draft = draftFor(target)
	local pending, result = state.pending[target] ~= nil, state.results[target]
	local lines = 0
	for line in (draft.text .. "\n"):gmatch("(.-)\n") do
		lines = lines
			+ math.max(1, math.ceil((utf8.len(line) or #line) / (preferences.compact and 80 or 40)))
	end
	local height = math.min(106, 40 + math.max(0, lines - 1) * 18)
	local controls = {
		ui.input({
			key = target .. ":input:" .. tostring(draft.rev),
			value = draft.text,
			placeholder = t("chat.write"),
			multiline = true,
			submitOnEnter = false,
			height = height,
			flexGrow = 1,
			enabled = not pending,
			onChange = function(value)
				setDraft(target, value)
				render()
			end,
		}),
	}
	table.insert(
		controls,
		button("panel.sms_send", "send", function()
			local current = draftFor(target)
			if state.pending[target] or not allowed or current.text:match("^%s*$") then
				return
			end
			command.device = id
			command.text = current.text
			command.target = target
			send(command)
		end, {
			enabled = allowed and not pending and draft.text:match("%S") ~= nil,
			variant = "primary",
			width = 90,
			height = 40,
		})
	)
	local children = { ui.row({ gap = 8, align = "end" }, controls) }
	if pending then
		table.insert(children, note(t("chat.sending")))
	elseif result then
		table.insert(
			children,
			note(result.ok and t("chat.accepted") or result.message, not result.ok)
		)
	end
	return ui.column({
		key = "composer-row:" .. target,
		gap = 6,
		padding = 0,
		align = "stretch",
		height = height + ((pending or result) and 54 or 0),
		fill = "surface/0",
	}, children)
end

-- Shared by Contacts and New message. Expansion reveals every number, while
-- only one page of contact rows is constructed at a time.
local function contactPicker(id, deviceMessages, pick)
	local view, rows = viewFor(id), {}
	local query = (view.contactSearch or ""):lower()
	local matches = {}
	for _, contact in ipairs(deviceMessages.contacts) do
		if query == "" or (contact.search or contact.name:lower()):find(query, 1, true) then
			table.insert(matches, contact)
		end
	end
	-- Keep native tree creation bounded even for large address books. Search
	-- still covers every contact; page changes replace rows instead of accumulating.
	local first, last, pager, page = pageRange(view, "contactPage", #matches, 25)
	for i = first, last do
		local contact = matches[i]
		local expanded = view.expandedContact == contact.id
		local toggle = function()
			view.expandedContact = not expanded and contact.id or nil
			saveView()
			render()
		end
		local avatar
		if contact.photo then
			avatar = ui.image({
				path = contact.photo,
				width = 32,
				height = 32,
				radius = 16,
				fit = "cover",
			})
		else
			local initials = {}
			for word in (contact.name or ""):gmatch("%S+") do
				local endByte = utf8.offset(word, 2) or (#word + 1)
				table.insert(initials, word:sub(1, endByte - 1):upper())
				if #initials == 2 then
					break
				end
			end
			avatar = ui.column({
				width = 32,
				height = 32,
				radius = 16,
				fill = "primary/0.13",
				align = "center",
				justify = "center",
			}, {
				label(table.concat(initials), { fontSize = 11, color = "primary" }),
			})
		end
		local count = #contact.numbers
		local summary = count == 1 and contact.numbers[1]
			or t("chat.numbers_count"):gsub("{count}", tostring(count))
		local children = {
			ui.row({
				key = "contact-toggle:" .. id .. ":" .. contact.id,
				gap = 10,
				align = "center",
				onClick = toggle,
			}, {
				avatar,
				ui.column({ gap = 2, flexGrow = 1, minWidth = 0 }, {
					label(
						contact.name,
						{ fontSize = 13, fontWeight = "medium", maxLines = expanded and 0 or 1 }
					),
					label(summary, { fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
				}),
				ui.glyph({
					name = expanded and "chevron-up" or "chevron-down",
					size = 16,
					color = "on_surface_variant",
				}),
			}),
		}
		if expanded then
			for _, number in ipairs(contact.numbers) do
				local actions = {
					label(number, { flexGrow = 1, fontSize = 12, maxLines = 2 }),
					button(pick and "chat.choose" or "chat.message", "message", function()
						compose(id, number, contact.name)
					end),
				}
				if not pick then
					table.insert(
						actions,
						icon("copy", "chat.copy_number", function()
							noctalia.copyToClipboard(number, "text/plain")
						end)
					)
				end
				table.insert(children, ui.row({ gap = 8, align = "center" }, actions))
			end
		end
		table.insert(
			rows,
			ui.column({
				key = "contact:" .. id .. ":" .. contact.id,
				gap = 8,
				padding = 8,
				fill = "surface/0.65",
				radius = 8,
			}, children)
		)
	end
	if #rows == 0 then
		table.insert(
			rows,
			note(t(#deviceMessages.contacts == 0 and "chat.no_contacts" or "chat.no_results"))
		)
	end
	local children = {
		ui.row({ gap = 8 }, {
			ui.input({
				key = "contacts-search:" .. id,
				value = view.contactSearch or "",
				placeholder = t("chat.search_contacts"),
				width = 280,
				flexGrow = 1,
				onChange = function(value)
					view.contactSearch = value
					view.contactPage = 1
					saveView()
					render()
				end,
			}),
			icon("refresh", "chat.refresh_contacts", function()
				send({ op = "contacts_sync", device = id })
			end),
		}),
	}
	local status = stateNote(deviceMessages, "contacts")
	if status then
		table.insert(children, status)
	end
	if pick then
		table.insert(
			children,
			ui.row({ gap = 8 }, {
				ui.input({
					key = "manual-number:" .. id,
					value = view.manual or "",
					placeholder = t("panel.sms_dest"),
					flexGrow = 1,
					onChange = function(value)
						view.manual = value
						saveView()
						render()
					end,
				}),
				button("chat.choose", "arrow-right", function()
					if view.manual and view.manual:match("%S") then
						compose(id, view.manual, view.manual)
					end
				end, { enabled = (view.manual or ""):match("%S") ~= nil }),
			})
		)
	end
	table.insert(
		children,
		ui.scroll(
			{ key = "contacts:" .. id .. ":" .. page .. ":" .. query, flexGrow = 1, gap = 8 },
			rows
		)
	)
	if pager then
		table.insert(children, pager)
	end
	return ui.column({ flexGrow = 1, gap = 10, minWidth = 0 }, children)
end

-- Keep the heading and composer fixed around a scrolling history page.
-- Cached pages are traversed before requesting another 50-message batch.
local function threadView(id, deviceMessages, state)
	local view = viewFor(id)
	local message = view.thread and deviceMessages.threads[view.thread]
	local children = {}
	if preferences.compact then
		table.insert(
			children,
			button("chat.back", "arrow-left", function()
				view.showThread = false
				saveView()
				render()
			end, { variant = "ghost" })
		)
	end
	if view.composing and not view.recipient then
		table.insert(
			children,
			label(t("chat.new_message"), { fontSize = 17, fontWeight = "medium" })
		)
		table.insert(children, contactPicker(id, deviceMessages, true))
	elseif message or (view.composing and view.recipient) then
		local title = message and Model.title(deviceMessages, message) or view.recipientName
		local addresses = message and table.concat(message.addresses or {}, ", ") or view.recipient
		table.insert(
			children,
			label(title or addresses, { fontSize = 17, fontWeight = "medium", maxLines = 2 })
		)
		table.insert(
			children,
			ui.row({ gap = 8, align = "center" }, {
				label(
					addresses,
					{ fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 2 }
				),
				icon("copy", "chat.copy_number", function()
					noctalia.copyToClipboard(addresses, "text/plain")
				end),
				icon("external-link", "chat.open_sms", function()
					send({ op = "launch_sms_app", device = id })
				end),
			})
		)
		local bubbles, history = {}, view.thread and deviceMessages.history[view.thread]
		if message then
			local messages = Model.sorted(deviceMessages.messages[view.thread])
			if #messages == 0 then
				messages = { message }
			end
			local offset = math.min(
				view.messageOffset or 0,
				math.floor((#messages - 1) / messagePageSize) * messagePageSize
			)
			table.insert(
				bubbles,
				button(
					history and history.loading and "chat.loading" or "chat.load_older",
					"history",
					function()
						view.messageOffset = offset + messagePageSize
						saveView()
						if #messages <= offset + messagePageSize then
							send({
								op = "history",
								device = id,
								thread = view.thread,
								start = #Model.sorted(deviceMessages.messages[view.thread]),
							})
						end
						render()
					end,
					{
						enabled = deviceMessages.connected and not (history and history.loading),
						variant = "ghost",
					}
				)
			)
			if history and (history.error or history.incomplete) then
				table.insert(bubbles, note(t("chat.history_hint"), history.error))
			end
			for i = math.min(offset + messagePageSize, #messages), offset + 1, -1 do
				local item = messages[i]
				local content = {
					label(item.body or "", { fontSize = 13, maxLines = 0 }),
					label(
						timeText(item.date)
							.. " · "
							.. t(item.outgoing and "chat.outgoing" or "chat.incoming"),
						{ fontSize = 10, color = "on_surface_variant" }
					),
				}
				if (item.attachments or 0) > 0 then
					table.insert(
						content,
						button("chat.attachment", "paperclip", function()
							send({ op = "launch_sms_app", device = id })
						end, { variant = "ghost" })
					)
				end
				table.insert(
					bubbles,
					ui.column({
						key = "message:" .. id .. ":" .. item.thread .. ":" .. item.id,
						gap = 6,
						padding = 12,
						radius = 10,
						fill = item.outgoing and "primary/0.12" or "surface/0.65",
					}, content)
				)
			end
			if offset > 0 then
				table.insert(
					bubbles,
					button("chat.newer_messages", "arrow-down", function()
						view.messageOffset = math.max(0, offset - messagePageSize)
						saveView()
						render()
					end, { variant = "ghost" })
				)
			end
		end
		table.insert(
			children,
			ui.scroll({
				key = "history:" .. id .. ":" .. tostring(view.thread or view.recipient),
				flexGrow = 1,
				gap = 10,
				stickToBottom = true,
			}, bubbles)
		)
		local target = id .. ":sms:" .. (view.thread or ("new:" .. view.recipient))
		table.insert(
			children,
			composer(
				id,
				target,
				state,
				{ op = "sms_send", thread = view.thread, destination = view.recipient },
				deviceMessages.connected and deviceMessages.capabilities.messages == true
			)
		)
	else
		table.insert(children, empty("messages", "chat.select_thread", "chat.select_hint"))
	end
	return ui.column({ gap = 8, flexGrow = 1, minWidth = 0 }, children)
end

-- Compact mode builds only the visible list or thread. Wide mode builds both.
local function messagesView(id, deviceMessages, state)
	local view, rows = viewFor(id), {}
	if preferences.compact and view.showThread then
		return threadView(id, deviceMessages, state)
	end
	local matches = {}
	for _, thread in ipairs(Model.sorted(deviceMessages.threads)) do
		if Model.matches(deviceMessages, thread, view.search) then
			table.insert(matches, thread)
		end
	end
	local first, last, pager, page = pageRange(view, "threadPage", #matches, threadPageSize)
	for i = first, last do
		local thread = matches[i]
		table.insert(
			rows,
			ui.column({
				key = "thread:" .. id .. ":" .. thread.thread,
				gap = 5,
				padding = 12,
				radius = 9,
				fill = view.thread == thread.thread and "primary/0.13" or "surface/0.5",
				onClick = function()
					selectThread(id, thread.thread)
				end,
			}, {
				label(
					Model.title(deviceMessages, thread),
					{ fontSize = 14, fontWeight = "medium", maxLines = 1 }
				),
				label(
					thread.body or "",
					{ fontSize = 12, maxLines = 2, color = "on_surface_variant" }
				),
				label(timeText(thread.date), { fontSize = 10, color = "on_surface_variant" }),
			})
		)
	end
	if #rows == 0 then
		table.insert(
			rows,
			note(t(next(deviceMessages.threads) and "chat.no_results" or "chat.no_threads"))
		)
	end
	local list = {
		ui.input({
			key = "thread-search:" .. id,
			value = view.search or "",
			placeholder = t("chat.search_threads"),
			onChange = function(value)
				view.search = value
				view.threadPage = 1
				saveView()
				render()
			end,
		}),
		note(t("chat.search_scope")),
		button("chat.new_message", "plus", function()
			view.thread = nil
			view.recipient = nil
			view.composing = true
			view.showThread = true
			saveView()
			render()
		end, {
			variant = "primary",
			enabled = deviceMessages.connected and deviceMessages.capabilities.messages == true,
		}),
	}
	local status = stateNote(deviceMessages, "messages")
	if status then
		table.insert(list, status)
	end
	table.insert(
		list,
		ui.scroll({
			key = "threads:" .. id .. ":" .. page .. ":" .. (view.search or ""),
			flexGrow = 1,
			gap = 8,
		}, rows)
	)
	if pager then
		table.insert(list, pager)
	end
	if preferences.compact then
		return ui.column({ flexGrow = 1, gap = 10 }, list)
	end
	return ui.row({ flexGrow = 1, gap = 16, align = "stretch" }, {
		ui.column({ width = 260, gap = 10 }, list),
		ui.separator({ orientation = "vertical" }),
		threadView(id, deviceMessages, state),
	})
end

-- Reply and Dismiss are shown only when advertised by the mirrored notification.
local function notificationsView(id, deviceMessages, state)
	local rows = {}
	local status = stateNote(deviceMessages, "notifications")
	if status then
		table.insert(rows, status)
	end
	for _, call in ipairs(deviceMessages.calls) do
		table.insert(
			rows,
			ui.column({ gap = 5, padding = 12, radius = 8, fill = "primary/0.08" }, {
				label(
					t(call.event == "missedCall" and "chat.missed_call" or "chat.call_event"),
					{ fontWeight = "medium" }
				),
				label(
					(
						call.name ~= "" and call.name
						or Model.name(deviceMessages.contacts, call.number)
					)
						.. " · "
						.. call.number,
					{ maxLines = 2 }
				),
				note(timeText(call.date * 1000)),
			})
		)
	end
	local notifications = {}
	for _, item in pairs(deviceMessages.notifications) do
		table.insert(notifications, item)
	end
	table.sort(notifications, function(a, b)
		return tostring(a.id) > tostring(b.id)
	end)
	local first, last, pager, page = pageRange(viewFor(id), "notificationPage", #notifications, 25)
	for i = first, last do
		local item = notifications[i]
		local target = id .. ":notification:" .. item.id
		local children = {
			ui.row({ gap = 8, align = "center" }, {
				label(item.app, { fontSize = 11, color = "primary", flexGrow = 1 }),
				button("chat.dismiss", "x", function()
					send({
						op = "notification_dismiss",
						device = id,
						notification = item.id,
						target = target .. ":dismiss",
					})
				end, {
					variant = "ghost",
					enabled = deviceMessages.connected
						and item.dismissable
						and not state.pending[target .. ":dismiss"],
				}),
			}),
			label(item.title, { fontSize = 15, fontWeight = "medium", maxLines = 4 }),
			label(item.text, { fontSize = 13, maxLines = 0 }),
		}
		local result = state.results[target .. ":dismiss"]
		if result and not result.ok then
			table.insert(children, note(result.message, true))
		end
		if item.replyId and item.replyId ~= "" then
			table.insert(
				children,
				composer(
					id,
					target .. ":" .. item.replyId,
					state,
					{ op = "notification_reply", notification = item.id, replyId = item.replyId },
					deviceMessages.connected
				)
			)
		end
		table.insert(
			rows,
			ui.column({
				key = "notification:" .. id .. ":" .. item.id,
				gap = 8,
				padding = 14,
				radius = 10,
				fill = "surface/0.6",
			}, children)
		)
	end
	if #notifications == 0 then
		table.insert(rows, empty("bell", "chat.no_notifications", "chat.notifications_hint"))
	end
	table.insert(rows, note(t("chat.calls_hint")))
	local children =
		{ ui.scroll({ key = "notifications:" .. id .. ":" .. page, flexGrow = 1, gap = 12 }, rows) }
	if pager then
		table.insert(children, pager)
	end
	return ui.column({ flexGrow = 1, gap = 8 }, children)
end

local function deviceView(device)
	local id, reachable = device.id, device.isPaired and device.isReachable
	local name = (shared["pc.aliasMap"] or {})[id] or device.name
	local image = (shared["pc.imageMap"] or {})[id]
	local identity, caption = {}, {}
	local editAction
	if image and image ~= "" then
		table.insert(
			identity,
			ui.image({
				path = image,
				width = 48,
				height = 48,
				radius = 24,
				fit = "cover",
				onClick = function()
					send({ op = "pick_image", device = id })
				end,
			})
		)
	end
	if editingName == id then
		table.insert(
			caption,
			ui.input({
				key = "alias:" .. id,
				value = name,
				flexGrow = 1,
				onChange = function(value)
					nameValue = value
				end,
				onSubmit = function(value)
					send({ op = "set_alias", device = id, alias = value })
					editingName = nil
					render()
				end,
			})
		)
		editAction = icon("check", "chat.save", function()
			send({ op = "set_alias", device = id, alias = nameValue })
			editingName = nil
			render()
		end)
	else
		table.insert(
			caption,
			label(name, {
				fontSize = 18,
				fontWeight = "medium",
				maxWidth = 240,
				maxLines = 1,
			})
		)
		editAction = icon("pencil", "chat.rename", function()
			editingName = id
			nameValue = name
			render()
		end)
	end
	local address = device.ipv4
	if type(address) ~= "string" or not address:match("%S") then
		address = device.ipv6
	end
	if type(address) == "string" and address:match("%S") then
		address = address:match("^%s*(.-)%s*$")
		table.insert(
			caption,
			label(address, {
				key = "connection-address:" .. id,
				fontSize = 10,
				color = "on_surface_variant",
				maxLines = 1,
			})
		)
	end
	table.insert(
		identity,
		ui.row({
			key = "identity-caption:" .. id,
			flexGrow = 1,
			minWidth = 0,
			gap = 12,
			align = "center",
		}, caption)
	)
	table.insert(identity, editAction)
	if device.isPaired then
		table.insert(
			identity,
			icon("link-off", "action.unpair", function()
				confirmUnpair = id
				render()
			end)
		)
	end
	table.insert(
		identity,
		button("chat.photo", "photo", function()
			send({ op = "pick_image", device = id })
		end)
	)
	local rows =
		{ ui.row({ key = "device-identity:" .. id, gap = 10, align = "center" }, identity) }
	if device.isPaired and confirmUnpair == id then
		table.insert(rows, note(t("chat.confirm_unpair")))
		table.insert(
			rows,
			ui.row({ gap = 10 }, {
				button("chat.cancel", "x", function()
					confirmUnpair = nil
					render()
				end, { flexGrow = 1 }),
				button("action.unpair", "link-off", function()
					send({ op = "unpair", device = id })
					confirmUnpair = nil
					render()
				end, { flexGrow = 1, variant = "destructive" }),
			})
		)
	end
	if not device.isPaired then
		table.insert(
			rows,
			button("action.pair", "link", function()
				send({ op = "pair", device = id })
			end, { variant = "primary" })
		)
	else
		local actions = {
			{ "chat.find_phone", "bell-ringing", "ring" },
			{ "action.ping", "message", "ping" },
			{ "chat.browse_files", "folder", "browse" },
			{ "action.share", "share", "pick_share" },
		}
		if noctalia.getConfig("enable_clipboard_action") then
			table.insert(actions, { "chat.send_clipboard", "clipboard", "clipboard" })
		end
		for i = 1, #actions, 2 do
			local pair = {}
			for j = i, math.min(i + 1, #actions) do
				local action = actions[j]
				table.insert(
					pair,
					button(action[1], action[2], function()
						send({ op = action[3], device = id })
					end, { flexGrow = 1, enabled = reachable, controlSize = "md" })
				)
			end
			table.insert(rows, ui.row({ gap = 10 }, pair))
		end
		table.insert(rows, mediaView(device))
	end
	return ui.scroll({ flexGrow = 1, gap = 16 }, rows)
end

-- A missing Python/Gio runtime must not resemble an empty cache or offline
-- phone. Keep the error inside the scroll area and offer the independent tab.
local function bridgeUnavailable(state)
	return ui.scroll({ key = "bridge-unavailable", flexGrow = 1, gap = 14 }, {
		label(t("chat.helper_unavailable"), { fontSize = 17, fontWeight = "bold", maxLines = 3 }),
		note(t("chat.helper_required")),
		note(state.error, true),
		note(t("chat.helper_recovery")),
		button("chat.open_device", "device-mobile", function()
			preferences.tab = "device"
			saveView()
			render()
		end, { variant = "primary" }),
	})
end

-- Rendering must stay within the host callback budget. Reuse watch-delivered
-- snapshots; never reread full message state here or inside input callbacks.
function render()
	if not opened then
		return
	end
	panel.setNeedsFrameTick(false)
	translations = shared["pc.trTable"] or {}
	local devices, order = shared["pc.devices"] or {}, shared["pc.order"] or {}
	local id = shared["pc.selected"]
	if preview then
		devices = preview.devices
		order = preview.order
		id = preview.selected
	end
	if not id or not devices[id] then
		id = order[1]
	end
	local device = id and devices[id]
	local state = shared["pc.messaging"] or { devices = {}, pending = {}, results = {} }
	if preview then
		state = preview.messaging
	end
	local deviceMessages = (id and state.devices[id]) or Model.device()
	local body, tabs = { header(devices, order, device) }, {}
	if preview then
		table.insert(body, note(t("chat.preview")))
	end
	local count = 0
	if state.bridgeStatus ~= "unavailable" then
		for _ in pairs(deviceMessages.notifications) do
			count = count + 1
		end
	end
	for _, tab in ipairs({ "messages", "notifications", "contacts", "device" }) do
		local text = t("chat.tab_" .. tab)
		if tab == "notifications" and count > 0 then
			text = text .. " (" .. count .. ")"
		end
		table.insert(
			tabs,
			ui.button({
				text = text,
				flexGrow = 1,
				controlSize = "sm",
				variant = preferences.tab == tab and "primary" or "ghost",
				selected = preferences.tab == tab,
				onClick = function()
					preferences.tab = tab
					saveView()
					render()
				end,
			})
		)
	end
	table.insert(body, ui.row({ gap = 6 }, tabs))
	table.insert(body, ui.separator({}))
	if state.bridgeStatus == "unavailable" and preferences.tab ~= "device" then
		table.insert(body, bridgeUnavailable(state))
	elseif not device then
		table.insert(body, empty("device-mobile", "panel.title", "panel.empty"))
	else
		if state.bridgeStatus ~= "unavailable" and state.error and state.error ~= "" then
			table.insert(body, note(state.error, true))
		end
		if deviceMessages.error and deviceMessages.error ~= "" then
			table.insert(body, note(deviceMessages.error, true))
		end
		if not deviceMessages.connected and preferences.tab ~= "device" then
			table.insert(body, note(t("chat.offline")))
		end
		if preferences.tab == "contacts" then
			table.insert(body, contactPicker(id, deviceMessages, false))
		elseif preferences.tab == "notifications" then
			table.insert(body, notificationsView(id, deviceMessages, state))
		elseif preferences.tab == "device" then
			table.insert(body, deviceView(device))
		else
			table.insert(body, messagesView(id, deviceMessages, state))
		end
	end
	panel.render(ui.column({
		key = "panel:" .. preferences.tab .. ":" .. tostring(preferences.compact),
		gap = 12,
		padding = 16,
		flexGrow = 1,
		align = "stretch",
	}, body))
end

function onOpen(_context)
	opened = true
	local defaultPage = noctalia.getConfig("default_page")
	preferences.tab = (
		defaultPage == "device"
		or defaultPage == "contacts"
		or defaultPage == "notifications"
	)
			and defaultPage
		or "messages"
	local id = shared["pc.selected"] or (shared["pc.order"] or {})[1]
	local state = shared["pc.messaging"]
	local deviceMessages = state and state.devices[id]
	-- The subscribed service keeps loaded conversations current. Re-requesting
	-- every thread on each open creates a large, redundant signal burst.
	if id and (not deviceMessages or not next(deviceMessages.threads)) then
		sync(id)
	end
	render()
end

function onClose()
	opened = false
	confirmUnpair = nil
	preview = nil
	panel.setNeedsFrameTick(false)
	if previewPreferences then
		preferences = previewPreferences
		previewPreferences = nil
	end
	saveView()
end

function onFrameTick()
	render()
end
-- View IPC drives native layout tests without simulating desktop input.
-- Preview data never enters the service, and all phone commands are blocked.
function onIpc(event, payload)
	local ok, value = pcall(noctalia.json.decode, payload or "{}")
	if not ok or type(value) ~= "table" then
		return
	end
	if
		event == "preview"
		and type(value.devices) == "table"
		and type(value.order) == "table"
		and type(value.messaging) == "table"
	then
		if not preview then
			previewPreferences = preferences
			preferences = { tab = "messages", compact = false, devices = {} }
		end
		preview = value
		if value.thread then
			viewFor(value.selected).thread = value.thread
			viewFor(value.selected).showThread = true
		end
		if type(value.expandedContact) == "string" then
			viewFor(value.selected).expandedContact = value.expandedContact
		end
	elseif event == "view" then
		if
			value.tab == "messages"
			or value.tab == "contacts"
			or value.tab == "notifications"
			or value.tab == "device"
		then
			preferences.tab = value.tab
		end
		if type(value.compact) == "boolean" then
			preferences.compact = value.compact
		end
		if type(value.search) == "string" then
			local id = preview and preview.selected or shared["pc.selected"]
			if id then
				viewFor(id).search = value.search
				viewFor(id).threadPage = 1
				saveView()
			end
		end
	end
	render()
end
for _, key in ipairs({
	"pc.devices",
	"pc.order",
	"pc.selected",
	"pc.backend",
	"pc.messaging",
	"pc.trTable",
	"pc.aliasMap",
	"pc.imageMap",
}) do
	noctalia.state.watch(key, function(value)
		shared[key] = value
		-- A sync emits many updates. Paint the newest snapshot once on the next
		-- frame instead of rebuilding the native tree for every signal.
		if opened and not preview then
			panel.setNeedsFrameTick(true)
		end
	end)
	shared[key] = noctalia.state.get(key)
end
