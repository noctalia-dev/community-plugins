--!nonstrict
-- Opt-in vertical shift: an override file in the Noctalia config dir trades
-- margin for thickness, so the bar content moves while the reserved space
-- (and therefore every window) stays where it is.

local util = require("../core/util.luau")

local M = {}
M.FILE = "zz-pixel-shift.toml"
M.SETTLE_MS = 3000 -- after a change, until Noctalia has reloaded its config
M.host = nil -- the host API; tests put a fake here

local changedAt = -math.huge

local function host()
	return M.host or noctalia
end

function M.path(): string
	return util.configDir(host().getenv) .. "/" .. M.FILE
end

function M.active(): boolean
	return host().fileExists(M.path())
end

-- Has Noctalia had time to reload since the plugin last changed the file?
function M.settled(): boolean
	return host().nowMs() - changedAt >= M.SETTLE_MS
end

function M.reload()
	host().runAsync({ "noctalia", "msg", "config-reload" })
end

-- base = {bar, margin, thickness}: the user's own values, read while no
-- override was in effect. v = content offset in logical px. Noctalia reloads
-- by itself when a *.toml file appears in its config dir, so the file is
-- written under another name and renamed into place: one reload per step.
function M.apply(base, v: number): boolean
	if v <= 0 then
		return M.clear()
	end
	local h = host()
	local path = M.path()
	local content = util.verticalToml(base.bar, base.margin + 2 * v, base.thickness - 2 * v)
	if h.fileExists(path) and h.readFile and h.readFile(path) == content then
		return true -- already in effect (plugin reload): no reload, no blink
	end
	local ok = h.writeFile(path .. ".tmp", content) and h.renameFile(path .. ".tmp", path)
	changedAt = h.nowMs()
	return ok == true
end

-- A deleted file is not watched, so removal asks for a reload.
function M.clear(): boolean
	if M.active() then
		host().removeFile(M.path())
		changedAt = host().nowMs()
		M.reload()
	end
	return true
end

-- Did the override take effect? A GUI setting for the bar's margin or
-- thickness takes precedence over config files and would defeat it.
function M.effective(base, v: number): boolean
	local get = host().getSetting
	return get(`bar.{base.bar}.margin_edge`) == base.margin + 2 * v and get(`bar.{base.bar}.thickness`) == base.thickness - 2 * v
end

return M
