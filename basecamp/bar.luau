--!nonstrict
-- Basecamp bar widget - the logo plus the unread count.
--
-- Imperative rather than declarative, and that is a measured choice, not a
-- shortcut. Step 1 in docs/PLAN.md tested it on the live bar:
--
--   barWidget.setImage(...)      renders the SVG, and does NOT tint it
--   barWidget.setColor(role)     colours the text, and composes with setImage
--
-- The logo as a font glyph, then: the host's own bar icons are font glyphs
-- and take the palette, while the white SVG sat next to them looking yellow.
-- assets/basecamp-icon.ttf holds the 37signals mark at U+E000 (built from
-- assets/basecamp-light.svg with fontforge); setText renders it like any text,
-- so setColor colours it. The count follows in the same string.
--
-- Every Basecamp call lives in the service, so several bars on several monitors
-- share one poller. This entry only reads state and asks for refreshes.

local ICON = utf8.char(0xE000)
local iconFamily = nil

local SUMMARY_KEY = "basecamp.summary"
local REQUEST_KEY = "basecamp.request"
local PANEL_OPEN_KEY = "basecamp.panelOpen"

local summary = {}
local panelOpen = false
local hasTooltip = false
local seq = 0

local function request(action: string)
	seq += 1
	noctalia.state.set(REQUEST_KEY, {
		action = action,
		-- nowMs alone can repeat within a millisecond; the counter makes it
		-- strictly increasing per widget instance.
		seq = noctalia.nowMs() + seq % 1000,
	})
end

-- The original colours on the selected account, so a filtered view is honest
-- about what the badge is counting.
local function unreadForSelection(): number
	local accountId = summary.accountId or ""
	if accountId == "" then
		return summary.unreadTotal or 0
	end
	return (summary.unreadByAccount or {})[accountId] or 0
end

local function needsSetup(): boolean
	if summary.probed ~= true then
		return false
	end
	return summary.installed ~= true or summary.supported ~= true or summary.authenticated ~= true
end

local function setupHeadline(): string
	if summary.installed ~= true then
		return noctalia.tr("setup.missing_title")
	end
	if summary.supported ~= true then
		return noctalia.tr("setup.outdated_title")
	end
	return noctalia.tr("setup.signin_title")
end

local function lastCheckedLabel(): string
	local updatedAtMs = summary.updatedAtMs or 0
	if updatedAtMs <= 0 then
		return noctalia.tr("status.never")
	end
	return noctalia.formatTime(noctalia.timeFormat(), math.floor(updatedAtMs / 1000))
end

local function accountLabel(): string
	local accountId = summary.accountId or ""
	if accountId == "" then
		return noctalia.tr("account.all")
	end
	for _, account in ipairs(summary.accounts or {}) do
		if account.id == accountId then
			return account.name
		end
	end
	return noctalia.tr("account.all")
end

local function applyTooltip(tooltip)
	barWidget.setTooltip(tooltip)
	hasTooltip = true
end

local function updateTooltip(unread: number)
	-- Clicking the widget opens the panel right underneath the pointer, so a
	-- tooltip left standing would cover what the click just opened. The host
	-- suppresses bar tooltips for an open panel, but only when the panel is
	-- already open the moment the click is dispatched, and a plugin panel is
	-- not: its script loads and renders first. So drop it here instead, and put
	-- it back on close.
	if panelOpen then
		if hasTooltip then
			barWidget.clearTooltip()
			hasTooltip = false
		end
		return
	end

	-- A setup problem is the only thing the user can act on, so it replaces the
	-- rows rather than hiding below them.
	if needsSetup() then
		applyTooltip(setupHeadline())
		return
	end

	if summary.refreshing == true then
		applyTooltip(noctalia.tr("status.refreshing"))
		return
	end

	local rows = {
		{ key = noctalia.tr("tooltip.unread"), value = noctalia.trp("unread_count", unread, { count = unread }) },
	}
	if #(summary.accounts or {}) > 1 then
		table.insert(rows, { key = noctalia.tr("tooltip.account"), value = accountLabel() })
	end
	table.insert(rows, { key = noctalia.tr("tooltip.last_updated"), value = lastCheckedLabel() })

	local err = summary.error or ""
	if err ~= "" then
		table.insert(rows, { key = "", value = err })
	else
		table.insert(rows, { key = "", value = noctalia.tr("tooltip.refresh_hint") })
	end

	applyTooltip(rows)
end

local function render()
	local unread = unreadForSelection()

	-- A vertical bar has no room for a number beside the logo.
	local showCount = noctalia.getConfig("show_count") ~= false and not barWidget.isVertical()
	local count = if showCount and unread > 0 then ` {unread}` else ""
	if iconFamily ~= nil then
		barWidget.setText(ICON .. count)
	else
		-- Font failed to load: fall back to a Tabler glyph so the bar is never blank.
		barWidget.setGlyph("mountain")
		barWidget.setText(count)
	end

	-- A setup problem is an error; unread is just news, so it takes the accent.
	-- Logo and count colour together: a lit-up mark reads better than a grey one
	-- with a blue number beside it.
	local role = if needsSetup() then "error" elseif unread > 0 then "primary" else "on_surface"
	barWidget.setColor(role)
	barWidget.setGlyphColor(role)

	updateTooltip(unread)
end

-- Left click comes from [widget.actions] in the manifest, so the user can remap
-- it. Right and middle both refresh, matching the original; middle only fires at
-- all because the manifest binds it to "none".
function onRightClick()
	request("refresh")
end

function onMiddleClick()
	request("refresh")
end

noctalia.state.watch(SUMMARY_KEY, function(value)
	if type(value) == "table" then
		summary = value
		render()
	end
end)

noctalia.state.watch(PANEL_OPEN_KEY, function(value)
	panelOpen = value == true
	render()
end)

local family, fontError = noctalia.loadFont("assets/basecamp-icon.ttf")
if family ~= nil then
	iconFamily = family
	barWidget.setFont(family, "inkCentered")
else
	noctalia.log(`basecamp: icon font not loaded: {tostring(fontError)}`)
end

summary = noctalia.state.get(SUMMARY_KEY) or summary
panelOpen = noctalia.state.get(PANEL_OPEN_KEY) == true
render()
