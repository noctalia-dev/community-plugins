--!nonstrict
-- Basecamp service - the only entry that runs the Basecamp CLI.
--
-- It owns every piece of shared state. The bar and the panel are pure
-- presentation: they watch `basecamp.summary` (small, both of them) and
-- `basecamp.items` (the list, panel only), and they ask for work by writing
-- `basecamp.request`. One poller therefore serves every bar on every monitor,
-- which is what the QML original used a Quickshell singleton for.
--
-- All parsing, sorting and formatting lives in model.luau, which touches no
-- noctalia API at all and is unit-tested standalone (tests/model_test.luau).
-- This entry is the part that cannot be: subprocesses, timers and state.
--
-- probe -> accounts -> notifications -> publish, with a generation guard and
-- the auth_required short-circuit; then mark-read, open, filters and the
-- sign-in flow as requests from the panel.

local model = require("./model.luau")

local SUMMARY_KEY = "basecamp.summary"
local ITEMS_KEY = "basecamp.items"
local REQUEST_KEY = "basecamp.request"

-- Timeouts are per command, and runAsync clamps them to [50, 60000] anyway.
-- `version` is local and instant; the others hit the network.
local VERSION_TIMEOUT_MS = 5000
local AUTH_TIMEOUT_MS = 8000
local ACCOUNTS_TIMEOUT_MS = 15000
local OPEN_TIMEOUT_MS = 10000
-- A refresh somehow still in flight after this is treated as dead. runAsync
-- always calls back, but the notifications stream has no exit signal: if
-- basecamp hangs, its {end} line never comes and this is what frees the spinner.
local REFRESH_WATCHDOG_MS = 120000
-- A sign-in the user walked away from: the button comes back after this even
-- if processMatches never reports the terminal gone.
local SETUP_STALE_MS = 300000
-- Give the terminal time to start before its absence counts as "closed".
local SETUP_GRACE_MS = 5000
-- Probe rate after the user pressed sign-in or copy: the terminal takes focus,
-- the panel closes, and its own 3 s probe tick stops with it.
local SETUP_POLL_MS = 3000

-- ── Settings ────────────────────────────────────────────────────────────────
-- getConfig returns whatever is stored, which is not necessarily the declared
-- type: a hand-edited settings.toml can hold anything. Every reader clamps.

local function intConfig(key: string, fallback: number, low: number, high: number): number
	local value = tonumber(noctalia.getConfig(key))
	if value == nil then
		value = fallback
	end
	return math.max(low, math.min(high, math.floor(value)))
end

local function boolConfig(key: string, fallback: boolean): boolean
	local value = noctalia.getConfig(key)
	return if type(value) == "boolean" then value else fallback
end

local function stringConfig(key: string, fallback: string): string
	local value = noctalia.getConfig(key)
	return if type(value) == "string" and value ~= "" then value else fallback
end

local function refreshIntervalMs(): number
	return intConfig("refresh_interval", 600, 60, 3600) * 1000
end

local function markReadOnOpen(): boolean
	return boolConfig("mark_read_on_open", true)
end

-- Why this is configurable at all: a plugin cannot make the browser take focus.
-- The shell can — net::openInBrowser asks Wayland for an xdg-activation token
-- (WaylandConnection::requestActivationToken) and passes it to the child as
-- XDG_ACTIVATION_TOKEN / DESKTOP_STARTUP_ID, which is the compositor's
-- permission to raise the new window. None of that is exposed to plugins:
-- there is no activation token in the scripting bindings and no IPC verb that
-- opens a URL. So `xdg-open` from here starts the browser without focus
-- permission, and a strict compositor (niri) leaves it in the background where
-- a lenient one (Hyprland, hence the Omarchy original) raises it anyway.
--
-- Rather than guess a compositor-specific incantation, the command is a setting.
local function openArgv(url: string): { string }?
	local template = stringConfig("open_command", "xdg-open {url}")

	-- Split on whitespace into an argv and exec directly. The string form of
	-- runAsync would go through /bin/sh -c, which would make every URL a
	-- quoting question and a potential injection; argv has neither problem.
	-- The cost is that shell syntax (pipes, &&) is unavailable — point a script
	-- at it instead.
	local argv = {}
	local placed = false
	-- A URL can contain %, and % is the escape character in a gsub REPLACEMENT,
	-- so it has to be doubled or "%2F" would be read as a capture reference.
	local safeUrl = url:gsub("%%", "%%%%")

	for token in template:gmatch("%S+") do
		if token:find("{url}", 1, true) then
			table.insert(argv, (token:gsub("{url}", safeUrl)))
			placed = true
		else
			table.insert(argv, token)
		end
	end

	if #argv == 0 then
		return nil
	end
	-- Forgetting the placeholder is a likely mistake and harmless to fix.
	if not placed then
		table.insert(argv, url)
	end
	return argv
end

-- Translated templates, passed into model.luau so it can finish a title without
-- knowing that translations exist.
local function itemLabels()
	return {
		fallbackTitle = noctalia.tr("notification.fallback_title"),
		pingTitle = noctalia.tr("ping.title"),
	}
end

-- ── State ───────────────────────────────────────────────────────────────────

local items = {}

local summary = {
	probed = false,
	installed = true,
	supported = true,
	authenticated = true,
	cliVersion = "",
	probeError = false,
	refreshing = false,
	accounts = {},
	unreadTotal = 0,
	unreadByAccount = {},
	itemCount = 0,
	updatedAtMs = 0,
	error = "",
	actionStatus = "",
	-- Stamped when actionStatus is set, so the panel can let it decay without
	-- the service needing a sub-interval timer.
	actionStatusAtMs = 0,
	setupRunning = false,
	accountId = "",
	canLoadMore = false,
}

-- Publishing `items` costs a marshal into every open panel, so it only happens
-- when the list actually changed. `summary` is small and always published: that
-- separation is the whole reason the two live on different channels. Without
-- this, a setup retry (every 3s while the panel is up) would re-send the entire
-- list on every tick.
local itemsSignature = ""

-- Which CLI page each account is on, reset by a full refresh. Absent means page
-- 1 fetched and page 2 untried, so it counts as "more may exist".
local pages = {}

local function inScope(accountId: string): boolean
	return summary.accountId == "" or summary.accountId == accountId
end

local function canLoadMore(): boolean
	for _, account in ipairs(summary.accounts) do
		local page = pages[account.id]
		if inScope(account.id) and (page == nil or not page.exhausted) then
			return true
		end
	end
	return false
end

local function signatureOf(list): string
	local first = if #list > 0 then tostring(list[1].id) else ""
	local last = if #list > 0 then tostring(list[#list].id) else ""
	return `{#list}:{summary.unreadTotal}:{first}:{last}`
end

local function publish()
	-- O(n) over at most a few dozen items on every publish. Deliberately not
	-- maintained incrementally: that would be more code and more bugs for an
	-- unmeasurable gain.
	summary.unreadTotal = model.unreadCount(items, "")
	summary.unreadByAccount = model.unreadByAccount(items)
	summary.itemCount = #items
	summary.canLoadMore = canLoadMore()

	local signature = signatureOf(items)
	if signature ~= itemsSignature then
		itemsSignature = signature
		noctalia.state.set(ITEMS_KEY, items)
	end

	-- Summary last: a watcher reacting to it already sees consistent items.
	noctalia.state.set(SUMMARY_KEY, summary)
end

-- Only the auth probe decides signed-in state. A data call (accounts,
-- notifications) can return auth_required on a transient 401 and that must not
-- flip the bar to "sign in" for the next ten minutes; it is a status-line error
-- like any other, and the probe at the start of the next refresh settles it.
local function setAuthenticated(value: boolean, source: string)
	if summary.authenticated and not value then
		noctalia.log(`basecamp: signed out according to {source}`)
		-- The held list belongs to a session that no longer exists: drop it so
		-- the bar stops counting it, and so the probe after sign-in fetches again.
		items = {}
		summary.updatedAtMs = 0
	end
	summary.authenticated = value
	if value then
		summary.setupRunning = false
	end
end

-- ── Refresh state machine ───────────────────────────────────────────────────
--
-- One chain at a time, sequential per account. Sequential rather than parallel
-- for three reasons: N accounts against the same rate-limited API buys nothing,
-- the auth_required short-circuit only means something in a chain, and holding
-- one raw CLI response at a time keeps peak memory at ~0.5 MB instead of N
-- times that (a raw notification item is 1.5-2.5 KB and a page holds 50).
--
-- Subprocesses cannot be cancelled, so `generation` is the only way to disown
-- callbacks from a superseded refresh: every callback closes over the generation
-- it started in and returns early when it no longer matches.

local refreshing = false
local generation = 0
local refreshStartedMs = 0
local probeOnly = false

local partialErrors = {}
-- Entries are { account, page }: a refresh lists page 1 of every account, a
-- load-more the next page of the accounts in scope.
local pendingAccounts = {}
local fetchIndex = 1
local fetched = {}
local appending = false

local function stale(): boolean
	if summary.updatedAtMs <= 0 then
		return true
	end
	return noctalia.nowMs() - summary.updatedAtMs >= refreshIntervalMs()
end

local function current(gen: number): boolean
	return gen == generation and refreshing
end

-- Ends a refresh without data: a setup state, or an error that makes carrying on
-- pointless.
local function stopRefresh(gen: number)
	if not current(gen) then
		return
	end
	refreshing = false
	summary.refreshing = false
	publish()
end

local function finishRefresh(gen: number)
	if not current(gen) then
		return
	end
	items = model.sortNotifications(if appending then model.mergeItems(items, fetched) else fetched)
	appending = false
	refreshing = false
	summary.refreshing = false
	summary.updatedAtMs = noctalia.nowMs()
	summary.error = if #partialErrors > 0 then table.concat(partialErrors, " · ") else ""
	publish()
end

-- The CLI reports API failures as an envelope on stdout with exit code 2, so
-- stdout is worth decoding even when the exit code is non-zero.
local function decode(result): (any, any)
	local decoded = noctalia.json.decode(result.stdout)
	return decoded, model.parseEnvelope(decoded)
end

-- Notifications arrive as one JSON line per item through runStream, not as one
-- document through runAsync. Every script callback gets 25 ms of CPU and this
-- host's VM is slow enough (a 100k-iteration loop does not finish in it) that
-- normalizing one page of ~54 items in a single callback never made it. A line
-- is its own callback, so each item gets a fresh budget. jq does the splitting
-- and keeps only the fields normalizeItem reads: a header line {ok, error,
-- code}, then {unread, item} per notification. runStream has no exit signal,
-- so the shell appends an {end} line even when basecamp or jq is missing.
local NOTIFICATIONS_FILTER = table.concat({
	"def slim: {id, type, section, title, named, bucket_name, content_excerpt,",
	" created_at, updated_at, read_at, unread_count, app_url,",
	" creator: (.creator | if . then {name} else . end),",
	" participants: (.participants | if . then map({name}) else . end)};",
	" if .ok then {ok: true}, (.data",
	" | if type == \"array\" then {name: \"notifications\", items: .}",
	" elif type == \"object\" then (to_entries[] | select(.value | type == \"array\") | {name: .key, items: .value})",
	" else empty end",
	" | .name as $name | .items[] | {unread: ($name | test(\"unread\"; \"i\")), item: slim})",
	" else {ok: false, error, code} end",
})
local END_LINE = "{\"end\":true}"

-- One account failing does not abandon the others; failures are collected and
-- shown as a single line, exactly as the original did.
local function addPartialError(accountName: string, detail: string)
	table.insert(partialErrors, `{accountName}: {detail}`)
end

local fetchNextAccount

-- Called once per account page when its {end} line arrives.
local function onPageDone(gen: number, entry, collected)
	if not current(gen) then
		return
	end
	-- Count against what is already held: every page repeats the unread
	-- section, so a page of nothing but repeats is the end of the list.
	local base = if appending then model.mergeItems(items, fetched) else fetched
	local merged = model.mergeItems(base, collected)
	-- Read before the loop: on a refresh `base` IS `fetched`, so it grows below.
	local added = #merged - #base
	for index = #base + 1, #merged do
		table.insert(fetched, merged[index])
	end
	pages[entry.account.id] = { page = entry.page, exhausted = added == 0 }

	fetchIndex += 1
	fetchNextAccount(gen)
end

function fetchNextAccount(gen: number)
	if not current(gen) then
		return
	end

	local entry = pendingAccounts[fetchIndex]
	if entry == nil then
		finishRefresh(gen)
		return
	end
	local account = entry.account

	-- Safe to interpolate into a shell string: model.validId only admits
	-- plain digits, and the page is a number.
	local page = if entry.page > 1 then ` --page {entry.page}` else ""
	local command = `basecamp notifications list --account {account.id} --json{page}`
		.. ` | jq -c '{NOTIFICATIONS_FILTER}'; echo '{END_LINE}'`

	local sawHeader = false
	local done = false
	local collected = {}

	local started = noctalia.runStream(command, function(line: string)
		if done or not current(gen) then
			return
		end
		local decoded = noctalia.json.decode(line)
		if type(decoded) ~= "table" then
			return
		end

		if decoded["end"] == true then
			done = true
			if not sawHeader then
				-- Nothing but the sentinel: basecamp or jq never produced output.
				addPartialError(account.name, noctalia.tr("error.spawn"))
			end
			onPageDone(gen, entry, collected)
		elseif decoded.ok ~= nil then
			sawHeader = true
			if decoded.ok ~= true then
				-- auth_required included: see setAuthenticated.
				addPartialError(account.name, model.concise(decoded.error, noctalia.tr("error.notifications")))
			end
		elseif type(decoded.item) == "table" then
			local item = model.normalizeItem(decoded.item, account, decoded.unread == true, itemLabels())
			if item ~= nil then
				table.insert(collected, item)
			end
		end
	end)

	if not started then
		addPartialError(account.name, noctalia.tr("error.spawn"))
		fetchIndex += 1
		fetchNextAccount(gen)
	end
end

local function onAccounts(gen: number, result)
	if not current(gen) then
		return
	end

	local decoded, envelope = decode(result)

	if not envelope.ok or result.exitCode ~= 0 or result.timedOut then
		-- auth_required included: see setAuthenticated.
		local stderr = model.trim(result.stderr)
		summary.error =
			model.concise(if stderr ~= "" then stderr else envelope.error, noctalia.tr("error.accounts"))
		stopRefresh(gen)
		return
	end

	local parsed = model.parseAccounts(decoded)
	if not parsed.ok then
		summary.error = model.concise(parsed.error, noctalia.tr("error.accounts"))
		stopRefresh(gen)
		return
	end

	summary.accounts = parsed.accounts

	-- A stored account filter for an account that no longer exists would
	-- silently show an empty list forever.
	if summary.accountId ~= "" then
		local found = false
		for _, account in ipairs(parsed.accounts) do
			if account.id == summary.accountId then
				found = true
				break
			end
		end
		if not found then
			summary.accountId = ""
		end
	end

	pendingAccounts = {}
	for _, account in ipairs(parsed.accounts) do
		table.insert(pendingAccounts, { account = account, page = 1 })
	end
	fetchIndex = 1
	fetched = {}
	fetchNextAccount(gen)
end

local function fetchAccounts(gen: number)
	if not current(gen) then
		return
	end
	local started = noctalia.runAsync({ "basecamp", "accounts", "list", "--json" }, function(result)
		onAccounts(gen, result)
	end, ACCOUNTS_TIMEOUT_MS)
	if not started then
		summary.error = noctalia.tr("error.spawn")
		stopRefresh(gen)
	end
end

local function onAuth(gen: number, result)
	if not current(gen) then
		return
	end

	local _, envelope = decode(result)

	-- Only a well-formed success is authoritative for `authenticated`. Anything
	-- else gets the error line and leaves the flag alone: telling the user to
	-- sign in cannot fix a garbled response, and probeError keeps the panel's
	-- retry alive so a probe that fails mid-install recovers on its own.
	if not envelope.ok or type(envelope.data) ~= "table" then
		if envelope.code == "auth_required" then
			setAuthenticated(false, "auth probe")
			summary.probed = true
			summary.probeError = false
			stopRefresh(gen)
			return
		end
		summary.authenticated = true
		summary.probed = true
		summary.probeError = true
		summary.error = model.formatTemplate(noctalia.tr("error.check"), {
			reason = model.concise(
				if model.trim(result.stderr) ~= "" then result.stderr else envelope.error,
				noctalia.tr("error.parse")
			),
		})
		stopRefresh(gen)
		return
	end

	-- `auth status` never refreshes; the next API call does. Only an expired
	-- token without a refresh token is signed out.
	local expired = envelope.data.expired == true and envelope.data.refreshable ~= true
	setAuthenticated(
		envelope.data.authenticated == true and not expired,
		if expired then "auth probe (token expired)" else "auth probe"
	)
	summary.probed = true
	summary.probeError = false
	summary.error = ""

	-- A probe stops here only when data is already held; otherwise the panel
	-- would show "signed in" over an empty list until the next scheduled refresh.
	if not summary.authenticated or (probeOnly and summary.updatedAtMs > 0) then
		stopRefresh(gen)
		return
	end

	fetchAccounts(gen)
end

local function onVersion(gen: number, result)
	if not current(gen) then
		return
	end

	local parsed = if result.exitCode == 0 and not result.timedOut
		then model.parseCliVersion(result.stdout)
		else { ok = false, version = "", supported = false }

	if not parsed.ok then
		summary.probed = true
		summary.probeError = true
		summary.error = noctalia.tr("error.version")
		stopRefresh(gen)
		return
	end

	summary.cliVersion = parsed.version
	summary.supported = parsed.supported
	if not parsed.supported then
		-- The setup card takes it from here. probeError stays false: nothing
		-- failed, the version is simply too old.
		summary.probed = true
		summary.probeError = false
		summary.error = ""
		stopRefresh(gen)
		return
	end

	local started = noctalia.runAsync({ "basecamp", "auth", "status", "--json" }, function(authResult)
		onAuth(gen, authResult)
	end, AUTH_TIMEOUT_MS)
	if not started then
		summary.probed = true
		summary.probeError = true
		summary.error = noctalia.tr("error.spawn")
		stopRefresh(gen)
	end
end

-- The QML original wrapped its probe in `bash -c`, because a Quickshell Process
-- on a missing binary never emits `exited` and the spinner would stick forever.
-- Neither hazard exists here: commandExists is a synchronous host call, and
-- runAsync always invokes its callback (timedOut on expiry) and returns false
-- synchronously when it cannot spawn. So: two plain argv calls, no shell.
local function probe(gen: number)
	if not current(gen) then
		return
	end

	if not noctalia.commandExists("basecamp") then
		summary.probed = true
		summary.installed = false
		summary.probeError = false
		summary.cliVersion = ""
		summary.error = ""
		stopRefresh(gen)
		return
	end
	summary.installed = true

	local started = noctalia.runAsync({ "basecamp", "version" }, function(result)
		onVersion(gen, result)
	end, VERSION_TIMEOUT_MS)
	if not started then
		summary.probed = true
		summary.probeError = true
		summary.error = noctalia.tr("error.spawn")
		stopRefresh(gen)
	end
end

-- mode: "full" always runs, "stale" only when the data is older than the
-- interval, "probe" runs the two probe commands and stops there unless no data
-- has been fetched yet. One function rather than three actions: all three share
-- the whole chain and differ only in their start condition and stopping point.
-- The flock lockfile of the original, observed instead of written: the button
-- stays disabled while a `basecamp auth login` process is alive, and comes back
-- when it is gone or after SETUP_STALE_MS, so a closed terminal never locks the
-- user out. Checked on every refresh start because the panel probes every 3 s
-- while the card is up.
local setupStartedMs = 0
local setupWatchUntilMs = 0
local lastTickWatching = false

local function needsSetup(): boolean
	return summary.installed ~= true or summary.supported ~= true or summary.authenticated ~= true
end

local function watchingSetup(): boolean
	return needsSetup() and noctalia.nowMs() < setupWatchUntilMs
end

local function applyInterval()
	noctalia.setUpdateInterval(if watchingSetup() then SETUP_POLL_MS else refreshIntervalMs())
end

local function startSetupWatch()
	setupWatchUntilMs = noctalia.nowMs() + SETUP_STALE_MS
	applyInterval()
end

local function checkSetupRunning()
	if summary.setupRunning ~= true then
		return
	end
	local age = noctalia.nowMs() - setupStartedMs
	if age > SETUP_STALE_MS then
		summary.setupRunning = false
		return
	end
	if age < SETUP_GRACE_MS then
		return
	end
	noctalia.processMatches(function(matched: boolean)
		if summary.setupRunning == true and not matched then
			summary.setupRunning = false
			publish()
		end
	end, "basecamp", "auth", "login")
end

local function startRefresh(mode: string?)
	local wanted = mode or "full"

	checkSetupRunning()
	if refreshing then
		return
	end
	if wanted == "stale" and not stale() then
		return
	end

	refreshing = true
	probeOnly = wanted == "probe"
	generation += 1
	refreshStartedMs = noctalia.nowMs()
	partialErrors = {}
	pages = {}
	appending = false
	summary.refreshing = true
	summary.error = ""
	publish()

	probe(generation)
end

-- The next CLI page for every account in scope, appended to what is held. Skips
-- the probe and the account listing: both were done by the refresh that put the
-- current list there.
local function startLoadMore()
	if refreshing or summary.authenticated ~= true then
		return
	end

	pendingAccounts = {}
	for _, account in ipairs(summary.accounts) do
		local page = pages[account.id] or { page = 1, exhausted = false }
		if inScope(account.id) and not page.exhausted then
			table.insert(pendingAccounts, { account = account, page = page.page + 1 })
		end
	end
	if #pendingAccounts == 0 then
		return
	end

	refreshing = true
	probeOnly = false
	generation += 1
	refreshStartedMs = noctalia.nowMs()
	partialErrors = {}
	appending = true
	fetchIndex = 1
	fetched = {}
	summary.refreshing = true
	summary.error = ""
	publish()

	fetchNextAccount(generation)
end

-- ── Mark as read ────────────────────────────────────────────────────────────
--
-- Three deliberate differences from Service.qml:219-289.
--
-- 1. Batched. The CLI takes `read <id>...`, so one argv per account per drain
--    replaces one subprocess per notification.
-- 2. No unconditional re-refresh afterwards. The original refreshed 1200 ms
--    after every successful drain to reconcile its optimistic flip, but a `read`
--    that exits 0 has committed server-side, so the flip is already true and the
--    refresh cost 1+N CLI round trips for nothing. Only failure resyncs.
-- 3. The transient status decays in the PANEL, not here. The panel is the thing
--    with second ticks; a service whose tick is 600 s has no mechanism for a
--    sub-interval one-shot short of `runAsync({"sleep", …})`. So the service
--    stamps actionStatusAtMs and the panel stops showing it after 2.2 s.

local READ_TIMEOUT_MS = 15000

local readQueue = {}
local readInFlight = false

local function setActionStatus(text: string)
	summary.actionStatus = text
	summary.actionStatusAtMs = noctalia.nowMs()
end

local function findItem(accountId: string, id: string)
	for _, item in ipairs(items) do
		if item.accountId == accountId and item.id == id then
			return item
		end
	end
	return nil
end

local runNextRead

function runNextRead()
	if readInFlight or #readQueue == 0 then
		return
	end

	local batch = table.remove(readQueue, 1)
	readInFlight = true

	local argv = { "basecamp", "notifications", "read" }
	for _, id in ipairs(batch.ids) do
		table.insert(argv, id)
	end
	table.insert(argv, "--account")
	table.insert(argv, batch.accountId)
	table.insert(argv, "--json")

	local started = noctalia.runAsync(argv, function(result)
		readInFlight = false
		local _, envelope = decode(result)

		if result.exitCode ~= 0 or result.timedOut or not envelope.ok then
			local stderr = model.trim(result.stderr)
			summary.error = model.concise(
				if stderr ~= "" then stderr else envelope.error,
				noctalia.tr("error.mark_read")
			)
			setActionStatus(summary.error)
			-- The optimistic flip may now be a lie, and every queued batch was
			-- built on the same assumption. Drop the queue and ask the server.
			readQueue = {}
			publish()
			startRefresh("full")
			return
		end

		setActionStatus(noctalia.tr("status.marked"))
		publish()
		runNextRead()
	end, READ_TIMEOUT_MS)

	if not started then
		readInFlight = false
		summary.error = noctalia.tr("error.spawn")
		setActionStatus(summary.error)
		publish()
	end
end

local function markRead(accountId: any, ids: any)
	if type(accountId) ~= "string" or type(ids) ~= "table" then
		return
	end

	-- Optimistic: flip locally and publish, so the badge disappears under the
	-- pointer instead of after a network round trip.
	local updated = model.markReadLocally(items, accountId, ids)
	if updated == nil then
		return
	end
	items = updated
	setActionStatus(noctalia.tr("status.marking"))
	publish()

	model.enqueueRead(readQueue, accountId, ids)
	runNextRead()
end

-- Returns false when nothing was launched, so the caller can skip follow-ups.
local function openUrl(url: string): boolean
	local argv = openArgv(url)
	if argv == nil then
		summary.error = noctalia.tr("error.open")
		setActionStatus(summary.error)
		publish()
		return false
	end

	-- With a callback rather than fire-and-forget, so a broken open_command
	-- reports itself instead of failing silently.
	local started = noctalia.runAsync(argv, function(result)
		if result.exitCode ~= 0 or result.timedOut then
			local stderr = model.trim(result.stderr)
			noctalia.log(`basecamp: open failed exit={result.exitCode} stderr="{stderr}"`)
			summary.error = model.concise(stderr, noctalia.tr("error.open"))
			setActionStatus(summary.error)
			publish()
		end
	end, OPEN_TIMEOUT_MS)

	if not started then
		summary.error = noctalia.tr("error.open")
		setActionStatus(summary.error)
		publish()
		return false
	end
	return true
end

local function openItem(accountId: any, id: any)
	if type(accountId) ~= "string" or type(id) ~= "string" then
		return
	end

	-- The service looks the item up rather than trusting a url from the panel:
	-- one source of truth, and the url has already been normalized away from
	-- 3.basecampapi.com by model.normalizeAppUrl.
	local item = findItem(accountId, id)
	if item == nil then
		return
	end

	if item.url ~= "" and not openUrl(item.url) then
		return
	end

	if item.unread and markReadOnOpen() then
		markRead(accountId, { id })
	end
end

-- ── Setup ───────────────────────────────────────────────────────────────────
-- The panel sends intent, never a command or a url: the service derives both
-- from its own probe results, so a stale or forged request cannot run anything
-- the current state would not.

local function setupPlan()
	return model.setupPlan(summary.installed == true, summary.supported == true, summary.authenticated == true)
end

local function runSetup()
	local plan = setupPlan()
	if not plan.runsInTerminal or plan.command == "" or summary.setupRunning == true then
		return
	end
	summary.setupRunning = true
	setupStartedMs = noctalia.nowMs()
	startSetupWatch()
	if not noctalia.runInTerminal(plan.command) then
		summary.setupRunning = false
		summary.error = noctalia.tr("error.no_terminal")
		setActionStatus(summary.error)
	end
	publish()
end

local function openDocs()
	local plan = setupPlan()
	if plan.docUrl ~= "" then
		openUrl(plan.docUrl)
	end
end

-- ── Filters ─────────────────────────────────────────────────────────────────
-- The account filter lives in the summary because it is shared: switching
-- accounts on one monitor switches it on every monitor, which is what the
-- original promised. Where the cursor is, by contrast, stays panel-local.

local function knownAccount(accountId: string): boolean
	if accountId == "" then
		return true
	end
	for _, account in ipairs(summary.accounts) do
		if account.id == accountId then
			return true
		end
	end
	return false
end

local function setFilters(accountId: any)
	local changed = false

	if type(accountId) == "string" and knownAccount(accountId) and summary.accountId ~= accountId then
		summary.accountId = accountId
		changed = true
	end

	if changed then
		publish()
	end
end

-- ── Requests ────────────────────────────────────────────────────────────────
-- Requests carry a monotonic `seq` so a repeated identical table still counts
-- as a new request, and two panels on two monitors cannot double-handle one.

local handledSeq = 0

noctalia.state.watch(REQUEST_KEY, function(request)
	if type(request) ~= "table" then
		return
	end

	local seq = tonumber(request.seq) or 0
	if seq <= handledSeq then
		return
	end
	handledSeq = seq

	local action = tostring(request.action or "")
	if action == "refresh" then
		startRefresh(tostring(request.mode or "full"))
	elseif action == "set_filters" then
		setFilters(request.accountId)
	elseif action == "load_more" then
		startLoadMore()
	elseif action == "open" then
		openItem(request.accountId, request.id)
	elseif action == "mark_read" then
		markRead(request.accountId, request.ids)
	elseif action == "run_setup" then
		runSetup()
	elseif action == "watch_setup" then
		startSetupWatch()
	elseif action == "open_docs" then
		openDocs()
	else
		noctalia.log(`basecamp: unhandled request "{action}"`)
	end
end)

-- ── Debug ───────────────────────────────────────────────────────────────────
-- `noctalia msg plugin kjvdven/basecamp:service all dump` writes the current
-- state to the log. onIpc is one-way with no return value, so a log line is as
-- close to a queryable API as a plugin gets.

function onIpc(event: string, payload: string?)
	if event == "refresh" then
		startRefresh("full")
	elseif event == "account" then
		-- An empty payload selects all accounts.
		setFilters(payload or "")
	elseif event == "load_more" then
		startLoadMore()
	elseif event == "dump" then
		noctalia.log(
			`basecamp: probed={tostring(summary.probed)} installed={tostring(summary.installed)} `
				.. `supported={tostring(summary.supported)} authed={tostring(summary.authenticated)} `
				.. `cli={summary.cliVersion} accounts={#summary.accounts} items={#items} `
				.. `unread={summary.unreadTotal} refreshing={tostring(summary.refreshing)} `
				.. `updatedAtMs={summary.updatedAtMs} error="{summary.error}" `
				.. `canLoadMore={tostring(summary.canLoadMore)} pages={noctalia.json.encode(pages) or "?"}`
		)
	end
end

-- ── Lifecycle ───────────────────────────────────────────────────────────────

-- Rehydrate before publishing: noctalia.state lives in the host, so a hot
-- reload of this file finds the previous snapshot still there and the bar does
-- not blink back to zero.
items = noctalia.state.get(ITEMS_KEY) or items
local stored = noctalia.state.get(SUMMARY_KEY)
if type(stored) == "table" then
	summary.accountId = stored.accountId or summary.accountId
	summary.accounts = stored.accounts or summary.accounts
	summary.updatedAtMs = stored.updatedAtMs or 0
	summary.cliVersion = stored.cliVersion or ""
end

applyInterval()
publish()
-- The host timer does not fire immediately, so the first read is explicit.
startRefresh("full")

function update()
	if refreshing and noctalia.nowMs() - refreshStartedMs > REFRESH_WATCHDOG_MS then
		refreshing = false
		summary.refreshing = false
		publish()
	end
	local watching = watchingSetup()
	if watching then
		startRefresh("probe")
	elseif not lastTickWatching then
		-- The tick that closes the window skips: the probe that closed it fetched.
		startRefresh("full")
	end
	lastTickWatching = watching
	applyInterval()
end

function onConfigChanged()
	-- Defining this keeps the service VM alive across a settings edit; without
	-- it the host restarts the runtime and every timer and cache is lost. So
	-- every config-derived value must be re-read here.
	applyInterval()

	-- mark_read_on_open is read here so the setting is provably wired; step 7
	-- consumes it when a row is opened.
	local _ = markReadOnOpen()
	publish()
end

function onEnable()
	startRefresh("full")
end
