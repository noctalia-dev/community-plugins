--!nonstrict
-- Service: mirrors the GUI layer into the configured Nix file whenever settings.toml
-- changes, and on request (control-center tile, panel, IPC). Publishes a status snapshot
-- for the tile and panel. The only process it runs is `nix-instantiate --parse` on the
-- file it is about to write.

local exporter = require("./lib/export.luau")

local STATUS_KEY = "settings_to_nix.status"
local COMMAND_KEY = "settings_to_nix.command"

local lastSignature = nil
local busy = false

-- A failed export is tried again on its own: after 5 s, then doubling up to 5 min, so a
-- passing hiccup (a slow or busy system while Noctalia reloads its plugins) heals without
-- a settings change. Only the first failure of a streak notifies; a manual export always does.
local RETRY_FIRST = 5
local RETRY_MAX = 300
local failures = 0
local retryAt = nil

noctalia.setUpdateInterval(2000)

local function config()
	return { target = noctalia.getConfig("target_path") }
end

local function fileSignature(path)
	local info = path and noctalia.fileInfo(path)
	if not info then
		return "-"
	end
	return `{info.mtime}:{info.size}`
end

local function publish(plan, err)
	noctalia.state.set(STATUS_KEY, {
		pending = plan ~= nil and plan.content ~= plan.current,
		target = plan and plan.target or "",
		values = plan and plan.stats.values or 0,
		error = err or "",
	})
end

local runExport

local function succeeded()
	failures = 0
	retryAt = nil
end

local function failed(err, manual)
	failures += 1
	retryAt = os.time() + math.min(RETRY_FIRST * 2 ^ (failures - 1), RETRY_MAX)
	noctalia.log(`settings-to-nix: export failed (attempt {failures}): {err}`)
	if manual or failures == 1 then
		noctalia.notifyError(noctalia.tr("notify.failed_title"), err)
	end
end

local function refresh()
	local cfg = config()
	local plan, err = exporter.plan(cfg)
	publish(plan, err)
	if not plan then
		failed(err, false)
	elseif plan.content ~= plan.current then
		runExport(false)
	else
		succeeded()
	end
end

function runExport(manual)
	if busy then
		return
	end
	local cfg = config()
	local plan, err = exporter.plan(cfg)
	if not plan then
		publish(nil, err)
		failed(err, manual)
		return
	end
	if plan.content == plan.current then
		publish(plan)
		succeeded()
		if manual then
			noctalia.notify(noctalia.tr("notify.unchanged_title"), noctalia.tr("notify.unchanged_body", { path = plan.target }))
		end
		return
	end

	busy = true
	exporter.write(plan, function(ok, writeErr)
		busy = false
		if not ok then
			publish(nil, writeErr)
			failed(writeErr, manual)
			return
		end
		succeeded()
		lastSignature = nil
		plan.current = plan.content
		publish(plan)
		if manual then
			noctalia.notify(
				noctalia.tr("notify.done_title"),
				noctalia.trp("notify.done_body", plan.stats.values, { path = plan.target })
			)
		end
	end)
end

function update()
	local cfg = config()
	local signature = fileSignature(exporter.settingsPath())
		.. "|"
		.. fileSignature(exporter.targetPath(cfg.target))
		.. "|"
		.. tostring(cfg.target)
	if signature ~= lastSignature then
		lastSignature = signature
		refresh()
	elseif retryAt ~= nil and not busy and os.time() >= retryAt then
		retryAt = nil
		refresh()
	end
end

function onConfigChanged()
	lastSignature = nil
	update()
end

function onIpc(event, _payload)
	if event == "export" then
		runExport(true)
	end
end

noctalia.state.watch(COMMAND_KEY, function(value)
	if type(value) == "table" then
		onIpc(value.action, nil)
	end
end)

update()
