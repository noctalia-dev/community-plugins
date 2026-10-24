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

local function refresh()
	local cfg = config()
	local plan, err = exporter.plan(cfg)
	publish(plan, err)
	if plan and plan.content ~= plan.current then
		runExport(false)
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
		noctalia.notifyError(noctalia.tr("notify.failed_title"), err)
		return
	end
	if plan.content == plan.current then
		publish(plan)
		if manual then
			noctalia.notify(noctalia.tr("notify.unchanged_title"), noctalia.tr("notify.unchanged_body", { path = plan.target }))
		end
		return
	end

	busy = true
	exporter.write(plan, function(ok, writeErr)
		busy = false
		if not ok then
			-- Not retried until settings.toml, the target or the setting changes, so a
			-- target that cannot be written does not notify every 2 seconds.
			publish(nil, writeErr)
			noctalia.notifyError(noctalia.tr("notify.failed_title"), writeErr)
			return
		end
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
