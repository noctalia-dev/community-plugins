--!nonstrict
-- Formatting shared by the compact panel and the details window.

local diff = require("./diff.luau")

local M = {}

M.RESULT_KEY = "nixos_updates"
M.COMMAND_KEY = "nixos_updates_command"
M.DETAILS_ID = "dmopp/nixos-updates:details"

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

-- Check now plus Update (or a shortcut to the settings when no update
-- command is set), for the bottom of both panels.
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
