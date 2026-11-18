--!nonstrict
-- Pure logic for the Basecamp plugin: parsing, normalizing, sorting, filtering
-- and formatting. A port of Model.js from the Omarchy plugin.
--
-- This module touches NO noctalia API. Not `noctalia.json`, not `noctalia.tr`,
-- not `os.time`. Callers hand in decoded tables, translated label templates and
-- the current time, which is what makes the whole thing runnable and testable
-- under a bare `luau` with no shell:
--
--   nix run nixpkgs#luau -- tests/model_test.luau
--
-- The reason that matters: every genuinely risky part of this port lives here
-- (HTML entity ordering, ISO-8601 without a date library, numeric account ids,
-- unread inference), and none of it needs a running Wayland session to verify.

local M = {}

-- ── Text ────────────────────────────────────────────────────────────────────

function M.trim(text: string): string
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local ENTITIES = {
	nbsp = " ",
	lt = "<",
	gt = ">",
	quot = '"',
	apos = "'",
	["#39"] = "'",
	["#039"] = "'",
	["#x27"] = "'",
}

-- Sentinel for `&amp;`, so it resolves AFTER every other entity. Model.js does
-- this by ordering its replace() calls; a single pass needs the placeholder.
local AMP = "\1"

-- Order is the security property here, not a style choice: entities are decoded
-- first and tags stripped second, so encoded markup ("&lt;img onerror=...&gt;")
-- becomes real markup and is then removed. Never the reverse, which would let it
-- survive into the UI. `&amp;` resolves last, so double-encoded markup
-- ("&amp;lt;script&amp;gt;") re-forms as inert text rather than live brackets.
function M.cleanText(value: any): string
	if type(value) ~= "string" then
		return ""
	end

	-- Literal backslash-n sequences (the API sends these inside excerpts) and
	-- real newlines both have to go; Model.js only handled the literal form.
	local text = value:gsub("\\[nrt]", " ")

	text = text:gsub("&(#?%w+);", function(name: string): string?
		local lower = name:lower()
		if lower == "amp" then
			return AMP
		end
		-- An unknown entity is left exactly as it was, rather than eaten.
		return ENTITIES[lower]
	end)

	text = text:gsub("<br%s*/?%s*>", " ")
	text = text:gsub("<[^>]*>", " ")
	text = text:gsub(AMP, "&")
	text = text:gsub("%s+", " ")
	return M.trim(text)
end

-- Byte-safe truncation: never splits a UTF-8 sequence, because a half sequence
-- renders as a replacement character and can break the label.
function M.truncate(text: string, maxBytes: number): string
	if #text <= maxBytes then
		return text
	end
	local cut = maxBytes
	-- Walk back off any continuation byte (0b10xxxxxx).
	while cut > 0 do
		local byte = text:byte(cut + 1)
		if byte == nil or byte < 0x80 or byte >= 0xC0 then
			break
		end
		cut -= 1
	end
	return text:sub(1, cut) .. "…"
end

function M.concise(value: any, fallback: string?): string
	local text = M.cleanText(value)
	if text == "" then
		text = fallback or ""
	end
	return M.truncate(text, 180)
end

-- Fills {name} placeholders. Keeps translated templates in the caller's hands
-- while the finished string still gets built here.
function M.formatTemplate(template: string, subst: { [string]: any }): string
	return (template:gsub("{(%w+)}", function(key: string): string?
		local value = subst[key]
		return if value == nil then nil else tostring(value)
	end))
end

-- ── Ids ─────────────────────────────────────────────────────────────────────

-- `accounts list` returns ids as JSON numbers. tostring(1000001) is fine, but
-- tostring on a float that happens to be integral gives "1e+06", which
-- would reach the CLI as `--account 1e+06`. Format integrals as integers.
function M.idToString(value: any): string
	if type(value) == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return ""
		end
		if value % 1 == 0 then
			return string.format("%d", value)
		end
		return tostring(value)
	end
	if type(value) == "string" then
		return M.trim(value)
	end
	return ""
end

-- A Basecamp id is a positive integer. Ids end up interpolated into shell
-- commands, so anything that is not plain digits is dropped here, at the source.
local function validId(value: any): string?
	local id = M.idToString(value)
	if not string.match(id, "^[1-9]%d*$") then
		return nil
	end
	return id
end

-- ── Envelopes ───────────────────────────────────────────────────────────────

export type Envelope = {
	ok: boolean,
	data: any,
	error: string,
	code: string,
	retryable: boolean,
}

-- The CLI wraps everything in {ok, data, summary}, and reports failures as
-- {ok:false, error, code, retryable} on STDOUT with exit code 2. `code` is what
-- the service switches on: "auth_required" aborts a whole refresh, because
-- credentials are shared and every remaining account would fail identically.
function M.parseEnvelope(decoded: any): Envelope
	if type(decoded) ~= "table" then
		return { ok = false, data = nil, error = "", code = "", retryable = false }
	end
	if decoded.ok == false then
		return {
			ok = false,
			data = nil,
			error = M.concise(decoded.error or decoded.message, ""),
			code = if type(decoded.code) == "string" then decoded.code else "",
			retryable = decoded.retryable == true,
		}
	end
	return {
		ok = true,
		data = decoded.data,
		error = "",
		code = "",
		retryable = false,
	}
end

-- ── CLI version ─────────────────────────────────────────────────────────────

local MIN_MAJOR, MIN_MINOR, MIN_PATCH = 0, 9, 0

-- `basecamp version` prints "basecamp version 0.9.1". 0.9.0 is the first
-- release whose read-only logins can still mark notifications as read, so it is
-- the floor. A prerelease of the floor itself (0.9.0-rc.1) predates it and is
-- not supported; a prerelease of anything higher is.
function M.parseCliVersion(raw: any): { ok: boolean, error: string, version: string, supported: boolean }
	local text = M.trim(if type(raw) == "string" then raw else "")
	local major, minor, patch, rest = text:match("^basecamp version v?(%d+)%.(%d+)%.(%d+)(.*)$")
	if major == nil then
		return { ok = false, error = "unreadable version", version = "", supported = false }
	end

	local suffix = M.trim(rest)
	local prerelease = suffix:match("^%-[%w%.%-]+") or ""
	local majorN, minorN, patchN = tonumber(major), tonumber(minor), tonumber(patch)

	local newerThanFloor = majorN > MIN_MAJOR
		or (majorN == MIN_MAJOR and minorN > MIN_MINOR)
		or (majorN == MIN_MAJOR and minorN == MIN_MINOR and patchN > MIN_PATCH)
	local isFloor = majorN == MIN_MAJOR and minorN == MIN_MINOR and patchN == MIN_PATCH and prerelease == ""

	return {
		ok = true,
		error = "",
		version = `{majorN}.{minorN}.{patchN}{suffix}`,
		supported = newerThanFloor or isFloor,
	}
end

-- ── Accounts ────────────────────────────────────────────────────────────────

export type Account = { id: string, name: string, order: number }

function M.parseAccounts(decoded: any, fallbackName: string?): { ok: boolean, error: string, accounts: { Account } }
	local envelope = M.parseEnvelope(decoded)
	if not envelope.ok then
		return { ok = false, error = envelope.error, accounts = {} }
	end

	local accounts: { Account } = {}
	local data = if type(envelope.data) == "table" then envelope.data else {}
	for _, entry in ipairs(data) do
		if type(entry) == "table" then
			local id = validId(entry.id)
			if id ~= nil then
				local name = M.cleanText(entry.name)
				if name == "" then
					name = M.formatTemplate(fallbackName or "Account {id}", { id = id })
				end
				table.insert(accounts, { id = id, name = name, order = #accounts })
			end
		end
	end

	return { ok = true, error = "", accounts = accounts }
end

-- ── Notifications ───────────────────────────────────────────────────────────

export type Item = {
	id: string,
	accountId: string,
	accountName: string,
	accountOrder: number,
	title: string,
	creator: string,
	excerpt: string,
	project: string,
	kind: string,
	tsSec: number,
	url: string,
	unread: boolean,
	unreadCount: number,
}

local TITLE_MAX_BYTES = 200
local EXCERPT_MAX_BYTES = 240

-- Workaround for the CLI/API: /my/notifications.json returns REST endpoint URLs
-- in app_url for some notification types (BoostReport, reminder answers). Opened
-- in a browser those render raw JSON or a 401, so rewrite them to the web app.
function M.normalizeAppUrl(raw: any): string
	local url = M.trim(if type(raw) == "string" then raw else "")
	return (url:gsub("^https://3%.basecampapi%.com/", "https://app.basecamp.com/"))
end

-- Days since 1970-01-01 from a proleptic Gregorian date (Howard Hinnant's
-- days_from_civil). Needed because Luau has no date library and os.time is off
-- limits in this module.
function M.daysFromCivil(y: number, m: number, d: number): number
	local year = if m <= 2 then y - 1 else y
	local era = (if year >= 0 then year else year - 399) // 400
	local yoe = year - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

-- The inverse, for formatting.
function M.civilFromDays(days: number): { y: number, m: number, d: number }
	local z = days + 719468
	local era = (if z >= 0 then z else z - 146096) // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local d = doy - (153 * mp + 2) // 5 + 1
	local m = if mp < 10 then mp + 3 else mp - 9
	return { y = if m <= 2 then y + 1 else y, m = m, d = d }
end

-- "2026-09-03T15:16:25.678Z", "…+02:00" and "…-0500" all occur. Returns UTC
-- epoch seconds, or 0 when unparseable (which callers render as no timestamp).
function M.parseIso8601(value: any): number
	if type(value) ~= "string" then
		return 0
	end
	local text = M.trim(value)
	local y, mo, d, h, mi, s, rest = text:match("^(%d%d%d%d)-(%d%d)-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$")
	if y == nil then
		return 0
	end

	local seconds = M.daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
		+ tonumber(h) * 3600
		+ tonumber(mi) * 60
		+ tonumber(s)

	-- Strip fractional seconds before looking for an offset.
	local tail = rest:gsub("^%.%d+", "")
	local sign, offH, offM = tail:match("^([%+%-])(%d%d):?(%d%d)")
	if sign ~= nil then
		local offset = tonumber(offH) * 3600 + tonumber(offM) * 60
		seconds += if sign == "+" then -offset else offset
	end
	return seconds
end

local GLYPHS = {
	mention = "at",
	comment = "message",
	chat = "messages",
	completion = "check",
	event = "calendar-event",
	reminder = "calendar-event",
	bulletin = "speakerphone",
	document = "file-text",
	message = "file-text",
	hill = "chart-line",
	boostreport = "rocket",
	assignment = "checkbox",
}

local COLOR_ROLES = {
	mention = "error",
	comment = "primary",
	chat = "primary",
	completion = "on_surface_variant",
	event = "secondary",
	reminder = "secondary",
	bulletin = "secondary",
	document = "on_surface_variant",
	message = "on_surface_variant",
	hill = "on_surface_variant",
	boostreport = "tertiary",
	assignment = "secondary",
}

-- The CLI capitalises `type` ("BoostReport"), so lower before the lookup. These
-- are Tabler glyph names, not the Nerd Font code points Model.js embedded:
-- ui.glyph takes names, and a name is themeable and font-independent.
function M.typeGlyph(kind: any): string
	local key = M.trim(tostring(kind or "")):lower()
	return GLYPHS[key] or "bell"
end

function M.typeColorRole(kind: any): string
	local key = M.trim(tostring(kind or "")):lower()
	return COLOR_ROLES[key] or "on_surface"
end

-- Joins names the way the original did: "A", "A & B", "A, B & C".
function M.joinNames(names: { string }): string
	if #names <= 1 then
		return names[1] or ""
	end
	local head = table.concat(names, ", ", 1, #names - 1)
	return `{head} & {names[#names]}`
end

-- An unnamed ping arrives titled just "Ping", so the participants are the only
-- thing that identifies it. `named` was null on every ping observed, which makes
-- this the normal path rather than an edge case.
function M.pingNames(item: any): string
	if type(item) ~= "table" then
		return ""
	end
	local names = {}
	for _, participant in ipairs(if type(item.participants) == "table" then item.participants else {}) do
		if type(participant) == "table" then
			local name = M.cleanText(participant.name)
			if name ~= "" then
				table.insert(names, name)
			end
		end
	end
	return M.joinNames(names)
end

export type ItemLabels = {
	fallbackTitle: string?,
	pingTitle: string?,
}

function M.normalizeItem(value: any, account: Account, sectionUnread: boolean, labels: ItemLabels?): Item?
	if type(value) ~= "table" then
		return nil
	end
	local id = validId(value.id)
	if id == nil then
		return nil
	end

	local label = labels or {}

	-- The item's own truth ORed with the section name. Model.js trusted the
	-- section alone, which is correct for this CLI but a single point of failure;
	-- every item also carries read_at / unread_at.
	local readAt = value.read_at
	local itemUnread = readAt == nil or (type(readAt) == "string" and M.trim(readAt) == "")
	local unread = sectionUnread or itemUnread

	-- Never fall back to readable_identifier: in this CLI it is an opaque base64
	-- GID ("Z2lkOi8vYmMzL1JlY29yZGluZy85…") and would render as garbage.
	local title = M.cleanText(value.title)
	if M.trim(tostring(value.section or "")):lower() == "pings" and value.named ~= true then
		local names = M.pingNames(value)
		if names ~= "" then
			title = M.formatTemplate(label.pingTitle or "Ping with {names}", { names = names })
		end
	end
	if title == "" then
		title = M.cleanText(value.bucket_name)
	end
	if title == "" then
		title = label.fallbackTitle or "Basecamp notification"
	end

	local creator = ""
	if type(value.creator) == "table" then
		creator = M.cleanText(value.creator.name)
	end

	local unreadCount = tonumber(value.unread_count) or 0
	if unreadCount < 0 then
		unreadCount = 0
	end

	-- Everything not listed here is dropped on purpose: the raw item carries a
	-- full creator object with bio and permissions, plus sgids and bookmark and
	-- subscription URLs. Keeping them would multiply what crosses into every
	-- panel VM on each publish for no gain. See "Memory" in docs/PLAN.md.
	return {
		id = id,
		accountId = account.id,
		accountName = account.name,
		accountOrder = account.order,
		title = M.truncate(title, TITLE_MAX_BYTES),
		creator = creator,
		excerpt = M.truncate(M.cleanText(value.content_excerpt), EXCERPT_MAX_BYTES),
		project = M.cleanText(value.bucket_name or value.section),
		kind = M.trim(tostring(value.type or "")),
		tsSec = M.parseIso8601(value.updated_at or value.created_at),
		url = M.normalizeAppUrl(value.app_url),
		unread = unread,
		unreadCount = unreadCount,
	}
end

-- ── Collections ─────────────────────────────────────────────────────────────

-- Newest first across every account, ties broken by account order then id, so
-- the list is stable between refreshes.
function M.sortNotifications(items: { Item }): { Item }
	local sorted = table.clone(items or {})
	table.sort(sorted, function(a: Item, b: Item): boolean
		if a.tsSec ~= b.tsSec then
			return a.tsSec > b.tsSec
		end
		if a.accountOrder ~= b.accountOrder then
			return a.accountOrder < b.accountOrder
		end
		return a.id < b.id
	end)
	return sorted
end

-- Appends `incoming` to `existing`, skipping items already present. Every CLI
-- page repeats the unread section, so page 2 is never pure additions.
function M.mergeItems(existing: { Item }, incoming: { Item }): { Item }
	local seen = {}
	local out = {}
	for _, item in ipairs(existing or {}) do
		seen[`{item.accountId}:{item.id}`] = true
		table.insert(out, item)
	end
	for _, item in ipairs(incoming or {}) do
		local key = `{item.accountId}:{item.id}`
		if not seen[key] then
			seen[key] = true
			table.insert(out, item)
		end
	end
	return out
end

function M.filterNotifications(items: { Item }, accountId: string?, tab: string?): { Item }
	local selected = accountId or ""
	local wanted = tab or "all"
	local out = {}
	for _, item in ipairs(items or {}) do
		local accountMatches = selected == "" or item.accountId == selected
		local tabMatches = wanted == "all"
			or (wanted == "unread" and item.unread)
			or (wanted == "previous" and not item.unread)
		if accountMatches and tabMatches then
			table.insert(out, item)
		end
	end
	return out
end

function M.unreadCount(items: { Item }, accountId: string?): number
	local selected = accountId or ""
	local count = 0
	for _, item in ipairs(items or {}) do
		if item.unread and (selected == "" or item.accountId == selected) then
			count += 1
		end
	end
	return count
end

function M.unreadByAccount(items: { Item }): { [string]: number }
	local counts = {}
	for _, item in ipairs(items or {}) do
		if item.unread then
			counts[item.accountId] = (counts[item.accountId] or 0) + 1
		end
	end
	return counts
end

-- Optimistic local flip, so the panel reacts before the CLI answers. Returns a
-- NEW array (state values are copied out to every entry, so mutating in place
-- would be invisible), or nil when nothing matched and there is nothing to
-- publish.
function M.markReadLocally(items: { Item }, accountId: string, ids: { string }): { Item }?
	local wanted = {}
	for _, id in ipairs(ids or {}) do
		wanted[M.idToString(id)] = true
	end

	local changed = false
	local out = {}
	for index, item in ipairs(items or {}) do
		if item.accountId == accountId and wanted[item.id] and item.unread then
			local copy = table.clone(item)
			copy.unread = false
			copy.unreadCount = 0
			out[index] = copy
			changed = true
		else
			out[index] = item
		end
	end

	return if changed then out else nil
end

-- The CLI takes `read <id>...`, so ids for one account coalesce into a single
-- argv instead of one subprocess per notification.
function M.enqueueRead(queue, accountId: string, ids: { string })
	local fresh = {}
	for _, id in ipairs(ids or {}) do
		local text = M.idToString(id)
		if text ~= "" then
			table.insert(fresh, text)
		end
	end
	if #fresh == 0 then
		return
	end

	for _, batch in ipairs(queue) do
		if batch.accountId == accountId then
			local seen = {}
			for _, id in ipairs(batch.ids) do
				seen[id] = true
			end
			for _, id in ipairs(fresh) do
				if not seen[id] then
					table.insert(batch.ids, id)
				end
			end
			return
		end
	end

	table.insert(queue, { accountId = accountId, ids = fresh })
end

export type AccountOption = { value: string, label: string }

-- "All accounts" first, then accounts by name, case-insensitively.
function M.accountOptions(accounts: { Account }, allLabel: string): { AccountOption }
	local options: { AccountOption } = { { value = "", label = allLabel } }
	local sorted = table.clone(accounts or {})
	table.sort(sorted, function(a: Account, b: Account): boolean
		local left, right = a.name:lower(), b.name:lower()
		if left ~= right then
			return left < right
		end
		return a.id < b.id
	end)
	for _, account in ipairs(sorted) do
		table.insert(options, { value = account.id, label = account.name })
	end
	return options
end

function M.cycleAccount(options: { AccountOption }, current: string, delta: number): string
	if #options < 2 then
		return current
	end
	local index = 1
	for position, option in ipairs(options) do
		if option.value == current then
			index = position
			break
		end
	end
	local next = ((index - 1 + delta) % #options) + 1
	return options[next].value
end

-- ── Presentation ────────────────────────────────────────────────────────────

M.MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- Today shows a clock, this year a day, otherwise a year too. tzOffsetSec and
-- use24h are parameters rather than looked up, which is what makes this
-- deterministic in tests.
function M.relativeTime(tsSec: number, nowSec: number, tzOffsetSec: number, use24h: boolean): string
	if type(tsSec) ~= "number" or tsSec <= 0 then
		return ""
	end
	local offset = tzOffsetSec or 0
	local localSec = tsSec + offset
	local nowLocal = (nowSec or 0) + offset

	local days = localSec // 86400
	local nowDays = nowLocal // 86400
	local date = M.civilFromDays(days)

	if days == nowDays then
		local secondOfDay = localSec - days * 86400
		local hour = secondOfDay // 3600
		local minute = (secondOfDay % 3600) // 60
		if use24h then
			return string.format("%d:%02d", hour, minute)
		end
		local hour12 = hour % 12
		if hour12 == 0 then
			hour12 = 12
		end
		return string.format("%d:%02d%s", hour12, minute, if hour >= 12 then "pm" else "am")
	end

	local nowDate = M.civilFromDays(nowDays)
	local month = M.MONTHS[date.m] or "?"
	if date.y ~= nowDate.y then
		return string.format("%s %d, %d", month, date.d, date.y)
	end
	return string.format("%s %d", month, date.d)
end

-- "9:41am • Samwise Gamgee • Fellowship (The Shire)"
function M.metaLine(
	item: Item,
	nowSec: number,
	tzOffsetSec: number,
	use24h: boolean,
	showAccount: boolean
): string
	if item == nil then
		return ""
	end
	local parts = {}
	local age = M.relativeTime(item.tsSec, nowSec, tzOffsetSec, use24h)
	if age ~= "" then
		table.insert(parts, age)
	end
	if item.creator ~= "" then
		table.insert(parts, item.creator)
	end
	if item.project ~= "" then
		if showAccount and item.accountName ~= "" then
			table.insert(parts, `{item.project} ({item.accountName})`)
		else
			table.insert(parts, item.project)
		end
	elseif showAccount and item.accountName ~= "" then
		table.insert(parts, item.accountName)
	end
	return table.concat(parts, " • ")
end

-- The badge shows the unread count, and a close glyph while hovered, which is
-- how the original let you dismiss without opening.
function M.badgeText(item: Item, hovered: boolean): string
	if hovered then
		return ""
	end
	return tostring(math.max(1, item and item.unreadCount or 0))
end

-- ── Setup state ─────────────────────────────────────────────────────────────

export type SetupPlan = {
	needed: boolean,
	kind: string,
	titleKey: string,
	bodyKey: string,
	buttonKey: string,
	command: string,
	runsInTerminal: boolean,
	docUrl: string,
}

local CLI_DOCS = "https://github.com/basecamp/basecamp-cli"

-- Priority: a missing CLI beats an outdated one beats being signed out, because
-- that is the order in which they have to be fixed. Everything Omarchy-specific
-- is gone: no flock lock file, no omarchy-shell IPC callback, and no
-- omarchy-pkg-add / omarchy update, which have no portable equivalent. Only
-- signing in runs a command; the other two open the CLI's own instructions,
-- because picking a package manager for the user is not this plugin's business.
function M.setupPlan(installed: boolean, supported: boolean, authenticated: boolean): SetupPlan
	if installed ~= true then
		return {
			needed = true,
			kind = "missing",
			titleKey = "setup.missing_title",
			bodyKey = "setup.missing_body",
			buttonKey = "setup.missing_button",
			command = "",
			runsInTerminal = false,
			docUrl = CLI_DOCS,
		}
	end
	if supported ~= true then
		return {
			needed = true,
			kind = "outdated",
			titleKey = "setup.outdated_title",
			bodyKey = "setup.outdated_body",
			buttonKey = "setup.outdated_button",
			command = "",
			runsInTerminal = false,
			docUrl = CLI_DOCS,
		}
	end
	if authenticated ~= true then
		return {
			needed = true,
			kind = "signin",
			titleKey = "setup.signin_title",
			bodyKey = "setup.signin_body",
			buttonKey = "setup.signin_button",
			command = "basecamp auth login",
			runsInTerminal = true,
			docUrl = "",
		}
	end
	return {
		needed = false,
		kind = "",
		titleKey = "",
		bodyKey = "",
		buttonKey = "",
		command = "",
		runsInTerminal = false,
		docUrl = "",
	}
end

return M
