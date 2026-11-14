--!nonstrict
-- Formatting shared by the compact panel and the details window.

local diff = require("./diff.luau")

local M = {}

M.RESULT_KEY = "nixos_updates"
M.COMMAND_KEY = "nixos_updates_command"
M.DETAILS_ID = "dmopp/nixos-updates:details"
M.SYSTEM_KEY = "nixos_updates_system"

function M.send(action)
	noctalia.state.set(M.COMMAND_KEY, { action = action, nonce = tostring(noctalia.nowMs()) })
end

function M.date(unixSeconds)
	if (tonumber(unixSeconds) or 0) <= 0 then
		return ""
	end
	return noctalia.formatTime("{:%Y-%m-%d}", unixSeconds)
end

function M.clock(unixSeconds)
	if os.time() - unixSeconds >= 20 * 3600 then
		return noctalia.formatTime("{:%Y-%m-%d %H:%M}", unixSeconds)
	end
	return noctalia.formatTime(noctalia.timeFormat(), unixSeconds)
end

-- "1.2.3 → 1.2.4"; added and removed entries say so instead of an empty side.
function M.change(old, new)
	if old == "" then
		return noctalia.tr("panel.added", { version = new })
	elseif new == "" then
		return noctalia.tr("panel.removed", { version = old })
	end
	return old .. "  →  " .. new
end

function M.flatpakChange(fp)
	if fp.new == "" then
		return noctalia.tr("panel.new_commit")
	end
	return M.change(fp.old, fp.new)
end

-- True when a step of the last check failed, so that "nothing pending" would
-- claim more than is known. A refused token is not such a step: the check runs
-- without one.
function M.incomplete(result)
	for _, e in ipairs(result.errors or {}) do
		if e.step ~= "token" then
			return true
		end
	end
	return false
end

-- One line under the title: running step, last check, or "never".
function M.status(result)
	if result.running then
		if result.step ~= nil and result.step ~= "" then
			return noctalia.tr("panel.checking_step", { step = noctalia.tr("steps." .. result.step) })
		end
		return noctalia.tr("panel.checking")
	elseif result.checkedAt == nil then
		return noctalia.tr("panel.never_checked")
	elseif (tonumber(result.count) or 0) == 0 then
		if M.incomplete(result) then
			return noctalia.tr("panel.check_incomplete", { time = M.clock(result.checkedAt) })
		end
		return noctalia.tr("panel.up_to_date", { time = M.clock(result.checkedAt) })
	end
	return noctalia.trp("panel.pending", result.count, { time = M.clock(result.checkedAt) })
end

-- Opens a link in the default browser. Plugins get no activation token, so
-- whether the browser window comes to the front is up to the compositor.
function M.openUrl(url)
	-- Checked again here: result.json is a file on disk, not only our output.
	url = diff.safeUrl(url)
	if url == nil then
		return
	end
	local accepted = noctalia.runAsync({ "xdg-open", url }, function(r)
		if r.exitCode ~= 0 then
			noctalia.notifyError(noctalia.tr("errors.open_failed"), url)
		end
	end, 20000)
	if not accepted then
		noctalia.notifyError(noctalia.tr("errors.open_failed"), url)
	end
end

-- Bytes as Nix and df users read them: "1.2 GiB".
function M.bytes(n)
	n = tonumber(n) or 0
	local units = { "B", "KiB", "MiB", "GiB", "TiB" }
	local i = 1
	while n >= 1024 and i < #units do
		n /= 1024
		i += 1
	end
	return string.format(i == 1 and "%d %s" or "%.1f %s", n, units[i])
end

-- Lines under the status: a restart that is due, and what the update would
-- download and build. Each { glyph, text, color, tooltip }.
function M.notes(result, system)
	local notes = {}
	local reboot = type(system) == "table" and system.reboot or nil
	if type(reboot) == "table" then
		local text = noctalia.tr("panel.reboot")
		if reboot.installed ~= "" and reboot.running ~= "" and reboot.installed ~= reboot.running then
			text = noctalia.tr("panel.reboot_kernel", { installed = reboot.installed, running = reboot.running })
		end
		table.insert(notes, { glyph = "refresh-alert", text = text, color = "error", tooltip = noctalia.tr("panel.reboot_hint") })
	end
	local estimate = result.estimate
	if result.estimating then
		-- Shown by estimateButton, with its progress.
	elseif result.estimateError ~= nil then
		table.insert(notes, { glyph = "cloud-download", text = tostring(result.estimateError), color = "error" })
	elseif type(estimate) == "table" and (tonumber(result.count) or 0) > 0 then
		local parts = {}
		-- Always a line once there is an estimate, also when everything is in the
		-- store already, so the result is never just a vanished button.
		if (tonumber(estimate.fetch) or 0) > 0 then
			table.insert(parts, noctalia.trp("panel.estimate_fetch", estimate.fetch, { download = estimate.download, unpacked = estimate.unpacked }))
		else
			table.insert(parts, noctalia.tr("panel.estimate_no_fetch"))
		end
		if (tonumber(estimate.build) or 0) > 0 then
			table.insert(parts, noctalia.trp("panel.estimate_build", estimate.build))
		end
		table.insert(notes, {
			glyph = "cloud-download",
			text = table.concat(parts, " · "),
			color = "on_surface_variant",
			tooltip = noctalia.tr("panel.estimate_hint"),
		})
	end
	return notes
end

-- Nix reports no progress for a dry run, so the bar runs against how long the
-- last estimate took (30 s before the first one) and stops short of the end
-- when it takes longer.
local DEFAULT_ESTIMATE_MS = 30 * 1000

local function estimateProgress(result)
	local elapsed = math.max(noctalia.nowMs() - (tonumber(result.estimateStartedMs) or noctalia.nowMs()), 0)
	local expected = math.max(tonumber(result.estimateMs) or DEFAULT_ESTIMATE_MS, 1000)
	local seconds = math.floor(elapsed / 1000)
	local hint
	if elapsed < expected then
		local key = result.estimateMs ~= nil and "panel.estimate_left" or "panel.estimate_left_guess"
		hint = noctalia.tr(key, { seconds = tostring(math.ceil((expected - elapsed) / 1000)) })
	else
		hint = noctalia.tr("panel.estimate_longer")
	end
	return ui.column({ key = "estimate-progress", gap = 4 }, {
		ui.button({
			key = "estimate",
			text = noctalia.tr("panel.estimate_running", { seconds = tostring(seconds) }),
			glyph = "cloud-download",
			fontSize = 12,
			glyphSize = 12,
			variant = "ghost",
			controlSize = "sm",
			contentAlign = "start",
			enabled = false,
		}),
		ui.progress({ progress = math.min(elapsed / expected, 0.95), height = 4, radius = 2 }),
		ui.label({ text = hint, fontSize = 11, color = "on_surface_variant" }),
	})
end

-- The button that starts the download estimate: only while updates are pending,
-- package versions are compared and no estimate is there. While it runs: the
-- disabled button with elapsed seconds and a progress bar.
function M.estimateButton(result)
	if result.estimating then
		return estimateProgress(result)
	end
	if result.running or result.estimate ~= nil or (tonumber(result.count) or 0) == 0 then
		return nil
	end
	if type(result.packages) ~= "table" then
		return nil
	end
	return ui.button({
		key = "estimate",
		text = noctalia.tr("panel.estimate_button"),
		glyph = "cloud-download",
		fontSize = 12,
		glyphSize = 12,
		variant = "ghost",
		controlSize = "sm",
		contentAlign = "start",
		tooltip = noctalia.tr("panel.estimate_button_hint"),
		onClick = function()
			M.send("estimate")
		end,
	})
end

function M.noteRows(notes)
	local rows = {}
	for i, note in ipairs(notes) do
		table.insert(rows, ui.row({ key = "note-" .. i, align = "center", gap = 8, tooltip = note.tooltip }, {
			ui.glyph({ name = note.glyph, size = 14, color = note.color }),
			ui.label({ text = note.text, fontSize = 12, color = note.color, flexGrow = 1, maxLines = 2 }),
		}))
	end
	return rows
end

-- "Nix store: 1.0 TiB free of 1.8 TiB · 91 system generations", or nil.
function M.storage(system)
	if type(system) ~= "table" or system.size == nil then
		return nil
	end
	return noctalia.tr("panel.storage", {
		free = M.bytes(system.free),
		size = M.bytes(system.size),
		generations = tostring(system.generations or 0),
	})
end

-- Check now, Clean up unless turned off, and Update (or a
-- shortcut to the settings when no update command is set), for the bottom of
-- both panels.
function M.actions(result, onUpdate)
	local buttons = {
		ui.button({
			text = noctalia.tr("panel.check_now"),
			glyph = "refresh",
			variant = "ghost",
			controlSize = "sm",
			enabled = not result.running,
			onClick = function()
				M.send("check")
			end,
		}),
		ui.box({ flexGrow = 1, height = 1, fill = "on_surface/0" }),
	}
	if result.hasCleanupButton then
		table.insert(buttons, ui.button({
			text = noctalia.tr("panel.cleanup"),
			glyph = "trash",
			variant = "ghost",
			controlSize = "sm",
			tooltip = noctalia.tr("panel.cleanup_hint"),
			onClick = function()
				M.send("cleanup")
				onUpdate()
			end,
		}))
	end
	if result.hasUpdateCommand then
		table.insert(buttons, ui.button({
			text = noctalia.tr("panel.update"),
			glyph = "terminal",
			controlSize = "sm",
			onClick = function()
				M.send("update")
				onUpdate()
			end,
		}))
	else
		table.insert(buttons, ui.button({
			text = noctalia.tr("panel.set_update_command"),
			glyph = "settings",
			variant = "ghost",
			controlSize = "sm",
			onClick = function()
				noctalia.openSettings()
			end,
		}))
	end
	return buttons
end

return M
