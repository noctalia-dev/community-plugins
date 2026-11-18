-- model.luau: status, allowed count, bar/header/debug views. tr is the identity (no noctalia global).
local rules = loadModule("rules.luau")
local model = loadModule("model.luau")

local function snap(over)
  local s = {
    seq = 1, installed = true, hasSystemctl = true, source = "files", enabled = true,
    unit = { active = "active", bootEnabled = true },
    defaults = { input = "DROP", ipv6 = true },
    rules = {}, pending = {}, busy = false,
  }
  for k, v in pairs(over or {}) do s[k] = v end
  if s.enabled == "unreadable" then s.enabled = nil end
  return s
end

-- status: the 8 combinations
eq("status missing", model.status(snap({ installed = false })), "missing")
eq("status unknown", model.status(snap({ enabled = "unreadable" })), "unknown")
eq("status off", model.status(snap({ enabled = false })), "off")
eq("status on without systemctl", model.status(snap({ hasSystemctl = false, unit = {} })), "on")
eq("status on active", model.status(snap()), "on")
eq("status failed", model.status(snap({ unit = { active = "failed" } })), "failed")
eq("status stopped", model.status(snap({ unit = { active = "inactive", bootEnabled = true } })), "stopped")
eq("status not_running inactive, boot disabled", model.status(snap({ unit = { active = "inactive", bootEnabled = false } })), "not_running")
eq("status not_running inactive, boot unknown", model.status(snap({ unit = { active = "inactive" } })), "not_running")
eq("status not_running activating", model.status(snap({ unit = { active = "activating", bootEnabled = true } })), "not_running")
eq("status not_running deactivating", model.status(snap({ unit = { active = "deactivating", bootEnabled = true } })), "not_running")
eq("status failed with boot enabled", model.status(snap({ unit = { active = "failed", bootEnabled = true } })), "failed")
eq("status stopped needs systemctl", model.status(snap({ hasSystemctl = false, unit = { active = "inactive", bootEnabled = true } })), "on")
eq("status off wins over inactive", model.status(snap({ enabled = false, unit = { active = "inactive", bootEnabled = true } })), "off")
eq("status unknown while the unit is not known", model.status(snap({ unit = {} })), "unknown")
eq("status unknown with no unit table", model.status(snap({ unit = false })), "unknown")

-- count
local list = rules.parseRules(fixture("shapes.rules"), fixture("shapes6.rules"), true)
eq("model: count excludes deny/out/route", model.allowedCount(list), 11)
eq("model: count of nothing", model.allowedCount({}), 0)
eq("model: count ignores deny", model.allowedCount({ { action = "deny", direction = "in", route = false } }), 0)
eq("model: count ignores out", model.allowedCount({ { action = "allow", direction = "out", route = false } }), 0)
eq("model: count ignores route", model.allowedCount({ { action = "allow", direction = "in", route = true } }), 0)
eq("model: count limit", model.allowedCount({ { action = "limit", direction = "in", route = false } }), 1)

-- barView
local on = model.barView(snap({ rules = list }), true, true)
eq("bar on dot", on.dot, "#22c55e")
eq("bar on text", on.text, "bar.on")
eq("bar on count", on.count, "11")
eq("bar on tooltip, plural", on.tooltip, "tooltip.on_other")
local one = model.barView(snap({ rules = { { action = "allow", direction = "in", route = false } } }), true, true)
eq("bar on tooltip, singular", one.tooltip, "tooltip.on_one")
eq("bar on tooltip, zero is plural", model.barView(snap(), true, true).tooltip, "tooltip.on_other")

-- countKey: one key per count form, picked with n == 1
for _, key in ipairs({ "tooltip.on", "footer.unsaved", "notice.saved", "notice.pending_dropped",
  "error.save_partial", "error.save_dropped" }) do
  eq("countKey " .. key .. " 1", model.countKey(key, 1), key .. "_one")
  eq("countKey " .. key .. " 2", model.countKey(key, 2), key .. "_other")
end
eq("countKey 0 is other", model.countKey("footer.unsaved", 0), "footer.unsaved_other")
eq("countKey without n keeps the key", model.countKey("notice.cancelled", nil), "notice.cancelled")
eq("countKey ignores a non-number n", model.countKey("notice.cancelled", "1"), "notice.cancelled")
local off = model.barView(snap({ enabled = false }), true, true)
eq("bar off dot", off.dot, "error")
eq("bar off text", off.text, "bar.off")
eq("bar off count", off.count, nil)
eq("bar off tooltip", off.tooltip, "tooltip.off")
for _, case in ipairs({
  { "not_running", snap({ unit = { active = "inactive" } }), "#f59e0b" },
  { "failed", snap({ unit = { active = "failed" } }), "#f59e0b" },
  { "missing", snap({ installed = false }), "on_surface_variant" },
  { "unknown", snap({ enabled = "unreadable" }), "on_surface_variant" },
}) do
  local v = model.barView(case[2], true, true)
  eq("bar " .. case[1] .. " dot", v.dot, case[3])
  eq("bar " .. case[1] .. " text", v.text, "bar.unknown")
  eq("bar " .. case[1] .. " count", v.count, nil)
  eq("bar " .. case[1] .. " tooltip", v.tooltip, "tooltip." .. case[1])
end
eq("bar showLabel=false", model.barView(snap({ rules = list }), false, true).text, nil)
eq("bar showCount=false", model.barView(snap({ rules = list }), true, false).count, nil)

-- barView stopped
local stopped = model.barView(snap({ unit = { active = "inactive", bootEnabled = true }, rules = list }), true, true)
eq("bar stopped dot", stopped.dot, "error")
eq("bar stopped text", stopped.text, "bar.off")
eq("bar stopped no count", stopped.count, nil)
eq("bar stopped tooltip", stopped.tooltip, "tooltip.stopped")

-- header
local h = model.header(snap())
eq("header on blocked", h.lineKey, "header.on_blocked")
eq("header reject blocked", model.header(snap({ defaults = { input = "REJECT" } })).lineKey, "header.on_blocked")
eq("header on open", model.header(snap({ defaults = { input = "ACCEPT" } })).lineKey, "header.on_open")
eq("header on unknown input", model.header(snap({ defaults = {} })).lineKey, "header.on")
eq("header on odd input", model.header(snap({ defaults = { input = "WAT" } })).lineKey, "header.on")
eq("header on no primary", h.primary, nil)
eq("header on no warning", h.warningKey, nil)
eq("header boot notice hidden", h.bootNotice, false)
eq("header boot notice shown", model.header(snap({ unit = { active = "active", bootEnabled = false } })).bootNotice, true)
eq("header boot notice needs systemctl", model.header(snap({ hasSystemctl = false, unit = { bootEnabled = false } })).bootNotice, false)
eq("header boot notice only on", model.header(snap({ enabled = false, unit = { bootEnabled = false } })).bootNotice, false)
local ho = model.header(snap({ enabled = false }))
eq("header off line", ho.lineKey, "header.off")
eq("header off warning", ho.warningKey, "warning.off")
eq("header off primary", ho.primary, "turn_on")
local hn = model.header(snap({ unit = { active = "inactive" } }))
eq("header not_running line", hn.lineKey, "header.not_running")
eq("header not_running warning", hn.warningKey, "warning.not_running")
eq("header not_running primary", hn.primary, "start_service")
local hs = model.header(snap({ unit = { active = "inactive", bootEnabled = true } }))
eq("header stopped status", hs.status, "stopped")
eq("header stopped line", hs.lineKey, "header.stopped")
eq("header stopped warning", hs.warningKey, "warning.off")
eq("header stopped primary", hs.primary, "turn_on")
eq("header stopped no boot notice", hs.bootNotice, false)
eq("switchOn on", model.switchOn(snap()), true)
eq("switchOn stopped", model.switchOn(snap({ unit = { active = "inactive", bootEnabled = true } })), false)
eq("switchOn off", model.switchOn(snap({ enabled = false })), false)
eq("switchOn not_running", model.switchOn(snap({ unit = { active = "inactive", bootEnabled = false } })), false)
eq("switchOn failed", model.switchOn(snap({ unit = { active = "failed", bootEnabled = true } })), false)
eq("switchOn unknown", model.switchOn(snap({ enabled = "unreadable" })), false)
eq("switchOn missing", model.switchOn(snap({ installed = false })), false)
eq("switchOn nil", model.switchOn(nil), false)
eq("switchOn on without systemctl", model.switchOn(snap({ hasSystemctl = false, unit = {} })), true)
local hf = model.header(snap({ unit = { active = "failed" } }))
eq("header failed line", hf.lineKey, "header.failed")
eq("header failed warning", hf.warningKey, "warning.failed")
local hu = model.header(snap({ enabled = "unreadable", source = "none" }))
eq("header unknown line", hu.lineKey, "header.unknown")
eq("header unknown primary", hu.primary, "load_rules")
eq("header missing line", model.header(snap({ installed = false })).lineKey, "header.missing")
eq("header missing primary", model.header(snap({ installed = false })).primary, nil)

-- debugView
local listCopy = {}
for i, r in ipairs(list) do listCopy[i] = r end
local secret = snap({
  rules = listCopy,
  pending = { { id = "p1", kind = "add", port = 49152, comment = "hunter2" }, { id = "p2", kind = "remove", ruleId = "allow|in|tcp|8080" } },
  lastError = { key = "error.busy", detail = "198.51.100.7 failed" },
  notice = { key = "notice.added" },
  busy = true,
})
secret.rules[#secret.rules + 1] = { id = "allow|in|tcp|40001|any||any|||0|", action = "allow", direction = "in", comment = "noctalia-ufw-e2e-one" }
local dv = model.debugView(secret)
eq("debug seq", dv.seq, 1)
eq("debug status", dv.status, "on")
eq("debug ruleCount", dv.ruleCount, 16)
eq("debug allowedCount", dv.allowedCount, 12)
eq("debug pendingCount", dv.pendingCount, 2)
eq("debug pendingKinds", table.concat(dv.pendingKinds, ","), "add,remove")
eq("debug busy", dv.busy, true)
eq("debug lastErrorKey", dv.lastErrorKey, "error.busy")
eq("debug noticeKey", dv.noticeKey, "notice.added")
eq("debug e2e id", dv.e2eRuleIds["noctalia-ufw-e2e-one"], "allow|in|tcp|40001|any||any|||0|")
local encoded = json.encode(dv)
for _, needle in ipairs({ "198.51.100.7", "192.0.2", "2001:db8", "8080", "api dev server", "hunter2", "49152", "60000" }) do
  check("debug has no " .. needle, not encoded:find(needle, 1, true))
end
check("debug keeps e2e comment", encoded:find("noctalia-ufw-e2e-one", 1, true) ~= nil)

-- nil snapshot (before the service's first publish)
eq("nil status", model.status(nil), "unknown")
local nb = model.barView(nil, true, true)
eq("nil bar dot", nb.dot, "on_surface_variant")
eq("nil bar text", nb.text, "bar.unknown")
eq("nil bar count", nb.count, nil)
eq("nil bar tooltip", nb.tooltip, "tooltip.loading")
eq("nil bar no label", model.barView(nil, false, true).text, nil)
eq("nil header status", model.header(nil).status, "unknown")
eq("nil debug status", model.debugView(nil).status, "unknown")
eq("nil debug rules", model.debugView(nil).ruleCount, 0)

-- not read yet (source "loading") is not unreadable
local loadingSnap = snap({ enabled = "unreadable", source = "loading", unit = {} })
eq("loading status", model.status(loadingSnap), "unknown")
eq("loading header line", model.header(loadingSnap).lineKey, "panel.loading")
eq("loading header offers nothing", model.header(loadingSnap).primary, nil)
eq("loading bar tooltip", model.barView(loadingSnap, true, true).tooltip, "tooltip.loading")
eq("loading bar dot muted", model.barView(loadingSnap, true, true).dot, "on_surface_variant")
local unreadableConf = snap({ enabled = "unreadable", source = "none" })
eq("unreadable ufw.conf header offers Load rules", model.header(unreadableConf).primary, "load_rules")
eq("unreadable ufw.conf header line", model.header(unreadableConf).lineKey, "header.unknown")
eq("unreadable ufw.conf bar tooltip", model.barView(unreadableConf, true, true).tooltip, "tooltip.unknown")
-- systemctl show failing: unknown (muted), and Load rules would not help
local unitUnknown = snap({ unit = {} })
eq("unit unknown status", model.status(unitUnknown), "unknown")
eq("unit unknown header offers nothing", model.header(unitUnknown).primary, nil)
eq("unit unknown bar dot muted", model.barView(unitUnknown, true, true).dot, "on_surface_variant")
eq("unit unknown bar tooltip", model.barView(unitUnknown, true, true).tooltip, "tooltip.unit_unknown")
eq("unit unknown header line", model.header(unitUnknown).lineKey, "header.unit_unknown")
-- ufw.conf unreadable as well: that is the settings line, not the unit's
local bothUnknown = snap({ enabled = "unreadable", source = "none", unit = {} })
eq("ufw.conf and unit unknown header line", model.header(bothUnknown).lineKey, "header.unknown")
eq("ufw.conf and unit unknown bar tooltip", model.barView(bothUnknown, true, true).tooltip, "tooltip.unknown")
-- still loading with the unit unknown: the loading line wins
local loadingUnit = snap({ source = "loading", unit = {} })
eq("loading with the unit unknown header line", model.header(loadingUnit).lineKey, "panel.loading")
eq("loading with the unit unknown bar tooltip", model.barView(loadingUnit, true, true).tooltip, "tooltip.loading")

-- test mode: the bar tooltip says so
do
  local previous = _G.noctalia
  _G.noctalia = { tr = function(key, subst)
    if subst and subst.text then return key .. "[" .. subst.text .. "]" end
    if subst and subst.n then return key .. "[" .. subst.n .. "]" end
    return key
  end }
  eq("test mode bar tooltip suffix", model.barView(snap({ testMode = true }), true, true).tooltip, "tooltip.test_mode[tooltip.on_other[0]]")
  eq("test mode suffix on off", model.barView(snap({ testMode = true, enabled = false }), true, true).tooltip, "tooltip.test_mode[tooltip.off]")
  eq("no suffix outside test mode", model.barView(snap({ enabled = false }), true, true).tooltip, "tooltip.off")
  _G.noctalia = previous
end
