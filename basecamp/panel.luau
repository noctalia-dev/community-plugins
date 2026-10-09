--!nonstrict
-- Basecamp panel - the notification list.
--
-- Reads `basecamp.summary` and `basecamp.items`, and asks the service for work
-- through `basecamp.request`. It never runs the CLI itself.
--
-- Header, account filter, one list (unread on top, then read) with a Load more
-- button, empty states, the status line, keyboard navigation, and a setup card
-- when the CLI is missing, too old, or signed out.

local model = require("./model.luau")

local SUMMARY_KEY = "basecamp.summary"
local ITEMS_KEY = "basecamp.items"
local REQUEST_KEY = "basecamp.request"
-- The bar widget reads this to drop its tooltip while the panel is up. The host
-- does suppress bar tooltips for an open panel (suppressBarTooltipsForPanel),
-- but only when the panel reports itself open in the same breath as the click,
-- and a plugin panel does not: the script has to load and render first. So the
-- tooltip would otherwise stay parked on top of the panel we just opened.
local PANEL_OPEN_KEY = "basecamp.panelOpen"

-- How long a transient action status ("Marked as read") stays on screen. The
-- service stamps it and this side lets it decay, because the panel is the thing
-- with second ticks.
local ACTION_STATUS_MS = 2200
-- How long the copy button reads "Copied".
local COPIED_MS = 1500
-- Seconds between probes while the setup card is up, so a finished sign-in or
-- a fresh install is noticed without a manual refresh.
local SETUP_RETRY_TICKS = 3

-- Rows shown per "Load more". Panel-local like the cursor: the service only
-- hears from the panel once the held items run out and a CLI page is needed.
local PAGE_SIZE = 15

local LOADING_PHRASES = {
	"loading.campsite",
	"loading.tent",
	"loading.kindling",
	"loading.campfire",
	"loading.marshmallows",
	"loading.hillchart",
}

local summary = {}
local items = {}
local isOpen = false

-- Panel-local on purpose: two panels on two monitors must not fight over one
-- selection index or one hover. The shared half (counts, filters) is in state.
local selectedIndex = 1
local cursorActive = false
local hoveredKey = nil
local hoveredRowKey = nil
local visibleCount = PAGE_SIZE

-- Clock state, refreshed on the minute rather than the second (see update()).
local nowSec = 0
local lastMinute = -1
local tzOffsetSec = 0
local use24h = false
local phraseIndex = 0
local phraseTicks = 0
local statusWasFresh = false
local retryTicks = 0
local copiedAtMs = 0
local copiedShown = false
-- onKey delivers auto-repeat; a held `r` must refresh once, not every tick.
local heldChord = nil
local seq = 0

local function tr(key: string, subst: any?): string
	return noctalia.tr(key, subst)
end

local function request(action: string, payload: any?)
	seq += 1
	local message = payload or {}
	message.action = action
	message.seq = noctalia.nowMs() + seq % 1000
	noctalia.state.set(REQUEST_KEY, message)
end

-- The local UTC offset, as seconds to add to an epoch second. model.relativeTime
-- takes it as a parameter so its behaviour is testable without a timezone.
local function localOffsetSec(now: number): number
	local ok, offset = pcall(function()
		return os.time(os.date("*t", now)) - os.time(os.date("!*t", now))
	end)
	return if ok and type(offset) == "number" then offset else 0
end

local function refreshClock()
	nowSec = os.time()
	tzOffsetSec = localOffsetSec(nowSec)
	use24h = noctalia.timeFormat():find("%%H") ~= nil
end

-- Same glyph as the bar, so both surfaces draw the mark from one source and
-- take the palette. Falls back to a Tabler glyph if the font did not load.
local iconFamily = noctalia.loadFont("assets/basecamp-icon.ttf")

local function logo()
	if iconFamily == nil then
		return ui.glyph({ name = "mountain", size = 22, color = "on_surface" })
	end
	return ui.label({
		text = utf8.char(0xE000),
		fontFamily = iconFamily,
		fontSize = 22,
		baseline = "pictographic",
		color = "on_surface",
	})
end

local function accountOptions()
	return model.accountOptions(summary.accounts or {}, tr("account.all"))
end

local function setupPlan()
	return model.setupPlan(summary.installed == true, summary.supported == true, summary.authenticated == true)
end

-- The card also stays up on a probe error, so the retry keeps going, but it
-- only renders content when the plan says what is wrong.
local function needsSetup(): boolean
	return summary.probed == true and setupPlan().needed
end

-- Unread first, then read, both newest first: the two former tabs stacked.
-- Also returns where the read block starts, for the section heading.
local function listItems()
	local accountId = summary.accountId or ""
	local out = model.filterNotifications(items, accountId, "unread")
	local firstRead = #out + 1
	for _, item in ipairs(model.filterNotifications(items, accountId, "previous")) do
		table.insert(out, item)
	end
	return out, firstRead
end

-- Section heading as Basecamp draws it: "New for you" in the accent, "Previous
-- notifications" plain with air above it. A spacer rather than padding so the
-- air sits only on top.
local function sectionHeading(key: string, accent: boolean, spaceAbove: number)
	return ui.column({ key = `heading-{key}`, paddingH = 8 }, {
		ui.spacer({ height = spaceAbove }),
		ui.label({
			text = tr(key),
			fontSize = 12,
			fontWeight = "bold",
			color = if accent then "primary" else "on_surface",
		}),
	})
end

-- ── Pieces ──────────────────────────────────────────────────────────────────

local function actionStatusFresh(): boolean
	if (summary.actionStatus or "") == "" then
		return false
	end
	return noctalia.nowMs() - (summary.actionStatusAtMs or 0) < ACTION_STATUS_MS
end

local function statusText(): string
	if actionStatusFresh() then
		return summary.actionStatus
	end
	local err = summary.error or ""
	if err ~= "" then
		return err
	end
	if summary.refreshing == true then
		return tr(LOADING_PHRASES[(phraseIndex % #LOADING_PHRASES) + 1])
	end
	if (summary.updatedAtMs or 0) > 0 then
		return model.formatTemplate(tr("status.updated"), {
			time = noctalia.formatTime(noctalia.timeFormat(), math.floor(summary.updatedAtMs / 1000)),
		})
	end
	return tr("status.never")
end

local function header()
	local isError = not actionStatusFresh() and (summary.error or "") ~= ""
	return ui.row({ gap = 9, align = "center" }, {
		logo(),
		ui.column({ gap = 1, flexGrow = 1 }, {
			ui.label({ text = tr("title"), fontSize = 15, fontWeight = "bold" }),
			ui.label({
				text = statusText(),
				fontSize = 10,
				color = if isError then "error" else "on_surface_variant",
				maxLines = 1,
			}),
		}),
		ui.button({
			glyph = if summary.refreshing == true then "loader" else "refresh",
			variant = "ghost",
			controlSize = "sm",
			tooltip = tr("tooltip.refresh"),
			enabled = summary.refreshing ~= true,
			onClick = "onRefreshClicked",
		}),
		ui.button({
			glyph = "settings",
			variant = "ghost",
			controlSize = "sm",
			tooltip = tr("tooltip.settings"),
			onClick = "onSettingsClicked",
		}),
		ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = "onCloseClicked" }),
	})
end

-- A real dropdown, as the original has. The plan argued for buttons instead,
-- because Panel.qml:496-500 documents a QML bug where the dropdown trigger kept
-- focus after its popup closed and swallowed Enter/Space/Down — repaired there
-- with forceActiveFocus(), which has no equivalent here. Keep an eye on that in
-- step 8: if the select turns out to eat capture_keys chords, the fallback is a
-- cycler button (onCycleAccountForward is already written for the keyboard).
local function accountFilter()
	-- With a single account, "All accounts" and that account are the same list
	-- with the same count, so the control is pure noise. Count ACCOUNTS, not
	-- options: options always includes the "All" entry.
	if #(summary.accounts or {}) < 2 then
		return nil
	end

	local options = accountOptions()
	local selected = summary.accountId or ""
	local counts = summary.unreadByAccount or {}

	local labels = {}
	local selectedIndex = 0
	for index, option in ipairs(options) do
		local count = if option.value == "" then (summary.unreadTotal or 0) else (counts[option.value] or 0)
		if count > 0 then
			labels[index] = model.formatTemplate(tr("account.with_count"), { name = option.label, count = count })
		else
			labels[index] = option.label
		end
		if option.value == selected then
			-- selectedIndex is zero-based, and onChange reports the same way.
			selectedIndex = index - 1
		end
	end

	return ui.select({
		options = labels,
		selectedIndex = selectedIndex,
		controlSize = "sm",
		onChange = "onAccountChanged",
	})
end

local function row(item, index: number)
	local id = `{item.accountId}:{item.id}`
	local rowKey = `row-{id}`
	local badgeKey = `badge-{id}`
	-- The badge is the innermost node while the pointer is on it, so the row
	-- reports a leave; count the badge as "on the row" or it blinks dark there.
	local hovered = hoveredRowKey == rowKey or hoveredKey == badgeKey
	local selected = (cursorActive and index == selectedIndex) or hovered
	local showAccount = (summary.accountId or "") == "" and #(summary.accounts or {}) > 1

	local children = {
		-- A 24px circle. ui.row, not ui.box: a box is a leaf and takes no
		-- children, so it cannot hold the glyph.
		ui.row({
			width = 24,
			height = 24,
			radius = 12,
			align = "center",
			justify = "center",
			fill = model.typeColorRole(item.kind),
		}, {
			ui.glyph({ name = model.typeGlyph(item.kind), size = 13, color = "surface" }),
		}),
	}

	local lines = {
		ui.label({
			text = item.title,
			fontSize = 12,
			fontWeight = if item.unread then "semibold" else "normal",
			maxLines = 2,
		}),
	}
	if item.excerpt ~= "" then
		table.insert(
			lines,
			ui.label({ text = item.excerpt, fontSize = 10, color = "on_surface_variant", maxLines = 2 })
		)
	end
	table.insert(
		lines,
		ui.label({
			text = model.metaLine(item, nowSec, tzOffsetSec, use24h, showAccount),
			fontSize = 10,
			color = "primary",
			maxLines = 1,
		})
	)
	table.insert(children, ui.column({ gap = 2, flexGrow = 1 }, lines))

	if item.unread then
		-- Hover flips the count to a close glyph: that is how the original let
		-- you dismiss without opening. A named handler receives (state, key), so
		-- one function serves every row.
		local badgeHovered = hoveredKey == badgeKey
		-- A row, not a button: ui.button has no radius prop, so it stays a wide
		-- rectangle, while the original is a small circle. A row gives radius,
		-- fill, onClick and onHover, which is everything this needs.
		table.insert(
			children,
			ui.row({
				key = badgeKey,
				width = 20,
				height = 20,
				radius = 10,
				align = "center",
				justify = "center",
				fill = "error",
				onHover = "onBadgeHover",
				onClick = function()
					request("mark_read", { accountId = item.accountId, ids = { item.id } })
				end,
			}, {
				if badgeHovered
					then ui.glyph({ name = "x", size = 11, color = "on_error" })
					else ui.label({
						text = model.badgeText(item, false),
						fontSize = 10,
						fontWeight = "bold",
						color = "on_error",
					}),
			})
		)
	end

	return ui.row({
		key = rowKey,
		gap = 9,
		align = "start",
		paddingH = 8,
		paddingV = 7,
		radius = 8,
		-- Explicit transparent, not nil: an unset prop keeps the previous value
		-- on a keyed node, so a row once lit would stay lit.
		fill = if selected then "primary/0.18" else "primary/0",
		onHover = "onRowHover",
		-- The whole row opens; the badge inside is the inner click target and
		-- wins, so dismissing cannot also open. With the click on a text column
		-- instead, that column swallowed the hover and only the padding lit up.
		onClick = function()
			request("open", { accountId = item.accountId, id = item.id })
			-- Close on open: the notification is now the thing the user wants
			-- to look at, and leaving the panel parked over the browser is
			-- noise. Also the only visible confirmation the click landed, since
			-- the browser window may not raise itself (see docs/PLAN.md on
			-- activation tokens).
			panel.close()
		end,
	}, children)
end

local function copiedFresh(): boolean
	return copiedAtMs > 0 and noctalia.nowMs() - copiedAtMs < COPIED_MS
end

-- Replaces filter and list while the CLI is missing, too old, or signed out.
-- Install and update open the CLI docs: there is no portable package command
-- across distributions, so guessing one would fail on most machines.
local function setupCard()
	local plan = setupPlan()
	local running = summary.setupRunning == true
	local children = {
		ui.glyph({ name = "campfire", size = 30, color = "outline" }),
		ui.label({ text = tr(plan.titleKey), fontSize = 13, fontWeight = "bold", textAlign = "center" }),
		ui.label({
			text = model.formatTemplate(tr(plan.bodyKey), { version = summary.cliVersion or "" }),
			fontSize = 11,
			color = "on_surface_variant",
			textAlign = "center",
			maxLines = 4,
		}),
		ui.button({
			key = "setup-action",
			text = tr(if running then "setup.running" else plan.buttonKey),
			variant = "primary",
			controlSize = "sm",
			enabled = not running,
			onClick = "onSetupClicked",
		}),
	}
	if plan.command ~= "" then
		table.insert(
			children,
			ui.row({ gap = 6, align = "center" }, {
				ui.label({ text = tr("setup.or_run"), fontSize = 10, color = "on_surface_variant" }),
				ui.label({ text = plan.command, fontSize = 10, fontFamily = "monospace" }),
				ui.button({
					key = "setup-copy",
					text = tr(if copiedFresh() then "setup.copied" else "setup.copy"),
					variant = "ghost",
					controlSize = "sm",
					onClick = "onCopyCommand",
				}),
			})
		)
	end
	return ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 10, paddingH = 16 }, children)
end

local function emptyState()
	local key
	if (summary.updatedAtMs or 0) == 0 and summary.refreshing == true then
		key = "empty.loading"
	else
		key = "empty.caught_up"
	end
	return ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
		ui.glyph({ name = "campfire", size = 30, color = "outline" }),
		ui.label({ text = tr(key), fontSize = 12, color = "on_surface_variant" }),
	})
end

local function body()
	local all, firstRead = listItems()
	if #all == 0 then
		return emptyState()
	end

	local rows = {}
	for index = 1, math.min(#all, visibleCount) do
		if index == 1 and firstRead > 1 then
			table.insert(rows, sectionHeading("section.new", true, 0))
		elseif index == firstRead then
			table.insert(rows, sectionHeading("section.previous", false, if firstRead > 1 then 14 else 0))
		end
		table.insert(rows, row(all[index], index))
	end
	if #all > visibleCount or summary.canLoadMore == true then
		local loading = summary.refreshing == true
		table.insert(
			rows,
			ui.button({
				key = "load-more",
				text = tr(if loading then "empty.loading" else "list.load_more"),
				variant = "ghost",
				controlSize = "sm",
				enabled = not loading,
				onClick = "onLoadMore",
			})
		)
	end
	-- One stable key in every state: a flexGrow scroll that changes identity
	-- gets stuck at the wrong height and clips its content.
	return ui.scroll({ key = "bc-list", flexGrow = 1, gap = 5 }, rows)
end

local function render()
	if not isOpen then
		return
	end

	local children = { header(), ui.separator({}) }

	if needsSetup() then
		table.insert(children, setupCard())
	else
		local accounts = accountFilter()
		if accounts ~= nil then
			table.insert(children, accounts)
		end
		table.insert(children, body())
	end

	panel.render(ui.column({ flexGrow = 1, gap = 9, padding = 12 }, children))
end

-- ── Handlers ────────────────────────────────────────────────────────────────

function onRefreshClicked()
	request("refresh", { mode = "full" })
end

function onSettingsClicked()
	noctalia.openSettings()
end

function onCloseClicked()
	panel.close()
end

function onSetupClicked()
	local plan = setupPlan()
	if plan.runsInTerminal then
		request("run_setup")
	elseif plan.docUrl ~= "" then
		request("open_docs")
	end
end

function onCopyCommand()
	local plan = setupPlan()
	if plan.command ~= "" and noctalia.copyToClipboard(plan.command, "text/plain") then
		copiedAtMs = noctalia.nowMs()
		request("watch_setup")
		render()
	end
end

-- Reveal another page from what is held; ask the service for a CLI page only
-- when that is not enough. The bump happens either way so the fetched items
-- show up without a second click.
function onLoadMore()
	visibleCount += PAGE_SIZE
	if #listItems() < visibleCount and summary.canLoadMore == true then
		request("load_more")
	end
	render()
end

local function cycleAccount(delta: number)
	visibleCount = PAGE_SIZE
	request("set_filters", {
		accountId = model.cycleAccount(accountOptions(), summary.accountId or "", delta),
	})
end

-- Written for the keyboard (left / right in step 8), and the fallback if the
-- select turns out to interfere with capture_keys.
function onCycleAccountForward()
	cycleAccount(1)
end

function onCycleAccountBack()
	cycleAccount(-1)
end

-- ui.select reports a zero-based index, as a string like every callback arg.
function onAccountChanged(index: string, _text: string)
	local option = accountOptions()[(tonumber(index) or -1) + 1]
	if option ~= nil then
		visibleCount = PAGE_SIZE
		request("set_filters", { accountId = option.value })
	end
end

-- onHover gives (state, key); state is the STRING "true" or "false", and only
-- the innermost hovered node reports, so the badge wins over its row. Hover sits
-- on the row and the badge only, as rss-notifier does: a handler on every nested
-- node made each boundary crossing a leave/enter pair plus a render, and the
-- highlight flickered. A leave only clears its own key, because row B's enter
-- can arrive before row A's leave.
function onRowHover(state: string, key: string)
	local wanted = if state == "true" then key else nil
	if state == "false" and hoveredRowKey ~= key then
		return
	end
	if wanted ~= nil and cursorActive then
		cursorActive = false
		hoveredRowKey = wanted
		render()
		return
	end
	if hoveredRowKey ~= wanted then
		hoveredRowKey = wanted
		render()
	end
end

-- ── Keys ────────────────────────────────────────────────────────────────────
-- Only the chords in capture_keys arrive. Escape is never one of them: the
-- host reserves it to dismiss the panel. Arrows keep auto-repeat on purpose;
-- `r` is debounced through heldChord so holding it refreshes once.

local function openSelected()
	local all = listItems()
	local item = all[selectedIndex]
	if item == nil or selectedIndex > visibleCount then
		return
	end
	request("open", { accountId = item.accountId, id = item.id })
	panel.close()
end

local function moveCursor(delta: number)
	local count = math.min(#listItems(), visibleCount)
	if count == 0 then
		return
	end
	if not cursorActive then
		-- The first press only reveals the cursor, at the top, as the original.
		cursorActive = true
		selectedIndex = 1
	else
		selectedIndex = ((selectedIndex - 1 + delta) % count) + 1
	end
	hoveredRowKey = nil
	hoveredKey = nil
	render()
end

function onKey(chord: string, pressed: boolean)
	if not pressed then
		if heldChord == chord then
			heldChord = nil
		end
		return
	end

	if chord == "r" then
		if heldChord == "r" then
			return
		end
		heldChord = "r"
		request("refresh", { mode = "full" })
		return
	end

	if needsSetup() then
		if chord == "return" then
			onSetupClicked()
		end
		return
	end

	if chord == "down" then
		moveCursor(1)
	elseif chord == "up" then
		moveCursor(-1)
	elseif chord == "return" then
		if cursorActive then
			openSelected()
		end
	elseif chord == "right" then
		if #(summary.accounts or {}) > 1 then
			cycleAccount(1)
		end
	elseif chord == "left" then
		if #(summary.accounts or {}) > 1 then
			cycleAccount(-1)
		end
	end
end

function onBadgeHover(state: string, key: string)
	local wanted = if state == "true" then key else nil
	if state == "false" and hoveredKey ~= key then
		return
	end
	if hoveredKey ~= wanted then
		hoveredKey = wanted
		render()
	end
end

-- ── Lifecycle ───────────────────────────────────────────────────────────────

function onOpen(_context)
	-- watch() alone misses everything the service published before this panel
	-- was first created, so read the current values on every open.
	summary = noctalia.state.get(SUMMARY_KEY) or summary
	items = noctalia.state.get(ITEMS_KEY) or items

	isOpen = true
	selectedIndex = 1
	cursorActive = false
	hoveredKey = nil
	hoveredRowKey = nil
	visibleCount = PAGE_SIZE
	phraseTicks = 0
	retryTicks = 0
	heldChord = nil
	lastMinute = -1
	refreshClock()

	noctalia.state.set(PANEL_OPEN_KEY, true)
	panel.setWantsSecondTicks(true)
	request("refresh", { mode = "stale" })
	render()
end

function onClose()
	isOpen = false
	panel.setWantsSecondTicks(false)
	noctalia.state.set(PANEL_OPEN_KEY, false)
end

-- One second tick replaces all four QML timers, but it must NOT re-render every
-- second: a 40-row tree is ~350 tables and the labels only change on the minute.
-- So each cause of change is checked and the render only runs when one fired.
function update()
	if not isOpen then
		return
	end

	local dirty = false

	local now = os.time()
	local minute = now // 60
	if minute ~= lastMinute then
		lastMinute = minute
		refreshClock()
		dirty = true
	end

	if summary.refreshing == true then
		phraseTicks += 1
		if phraseTicks >= 3 then
			phraseTicks = 0
			phraseIndex += 1
			dirty = true
		end
	end

	-- One render on the transition, not one per second while it is stale.
	local fresh = actionStatusFresh()
	if fresh ~= statusWasFresh then
		statusWasFresh = fresh
		dirty = true
	end

	local copied = copiedFresh()
	if copied ~= copiedShown then
		copiedShown = copied
		dirty = true
	end

	-- Two CLI calls every few seconds while the card is up, instead of a full
	-- sweep: the probe continues into a fetch by itself once sign-in succeeds.
	if needsSetup() or summary.probeError == true then
		retryTicks += 1
		if retryTicks >= SETUP_RETRY_TICKS then
			retryTicks = 0
			request("refresh", { mode = "probe" })
		end
	end

	if dirty then
		render()
	end
end

noctalia.state.watch(SUMMARY_KEY, function(value)
	if type(value) == "table" then
		summary = value
		render()
	end
end)

noctalia.state.watch(ITEMS_KEY, function(value)
	if type(value) == "table" then
		items = value
		render()
	end
end)

function onConfigChanged()
	render()
end

-- Hot-reloading this file while the panel is open loses `isOpen`, because the
-- module state resets and the host does not replay onOpen. The panel then sits
-- there rendering nothing until it is toggled twice. The panelOpen channel
-- already knows the answer, so recover from it: this makes editing a live panel
-- actually iterative.
if noctalia.state.get(PANEL_OPEN_KEY) == true then
	summary = noctalia.state.get(SUMMARY_KEY) or summary
	items = noctalia.state.get(ITEMS_KEY) or items
	isOpen = true
	lastMinute = -1
	refreshClock()
	panel.setWantsSecondTicks(true)
	render()
end
