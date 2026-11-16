-- model.luau: kernel check, wording, tile, panel state, row views.
local model = loadModule("model.luau")

-- Stub translation: key plus the substitution table, so tests see both.
local savedNoctalia = noctalia
noctalia = {
  tr = function(key, subst)
    local parts = {}
    for k, v in pairs(subst or {}) do
      parts[#parts + 1] = k .. "=" .. tostring(v)
    end
    table.sort(parts)
    if #parts == 0 then
      return key
    end
    return key .. "|" .. table.concat(parts, ",")
  end,
}

local function conn(id, status, extra)
  local c = {
    id = id, name = "Work", host = "vpn.example.com", account = "user@example.com",
    status = status, authorized = true, dns = {},
  }
  for k, v in pairs(extra or {}) do
    c[k] = v
  end
  return c
end

local function snap(connections, extra)
  local s = {
    installed = true, service = "running", connections = connections,
    inFlight = {}, rowErrors = {}, rebootNeeded = false, busy = false,
  }
  for k, v in pairs(extra or {}) do
    s[k] = v
  end
  return s
end

-- reboot rule
local rebootCases = {
  { "loaded, dir, zst", { wgLoaded = true, release = "6.1", moduleDirExists = true, wgModuleFiles = { "wireguard.ko.zst" } }, false },
  { "not loaded, no dir", { wgLoaded = false, release = "6.1", moduleDirExists = false, wgModuleFiles = {} }, true },
  { "not loaded, dir without wireguard", { wgLoaded = false, release = "6.1", moduleDirExists = true, wgModuleFiles = { "other.ko" } }, true },
  { "not loaded, dir with xz", { wgLoaded = false, release = "6.1", moduleDirExists = true, wgModuleFiles = { "wireguard.ko.xz" } }, false },
  { "loaded, no dir", { wgLoaded = true, release = "6.1", moduleDirExists = false, wgModuleFiles = {} }, false },
}
for _, case in ipairs(rebootCases) do
  eq("model: reboot rule " .. case[1], model.rebootNeeded(case[2]), case[3])
end

-- connectError mapping
local function ce(outcome, reboot)
  return model.connectError(outcome, reboot)
end
eq("model: connectError signin", ce({ ok = false, kind = "signin" }, false).key, "error.needs_signin")
eq("model: connectError timeout", ce({ ok = false, kind = "timeout" }, false).key, "error.connect_timeout")
local withDetail = ce({ ok = false, kind = "failed", detail = "no route" }, false)
eq("model: connectError failed detail key", withDetail.key, "error.connect_failed_detail")
eq("model: connectError failed detail text", withDetail.detail, "no route")
local noDetail = ce({ ok = false, kind = "failed" }, false)
eq("model: connectError failed key", noDetail.key, "error.connect_failed")
eq("model: connectError failed no detail", noDetail.detail, nil)
eq("model: connectError reboot overrides failed", ce({ ok = false, kind = "failed", detail = "x" }, true).key, "error.reboot_needed")
eq("model: connectError reboot overrides signin", ce({ ok = false, kind = "signin" }, true).key, "error.reboot_needed")

-- disconnectError mapping
eq("model: disconnectError timeout", model.disconnectError({ ok = false, kind = "timeout" }).key, "error.disconnect_timeout")
local dWith = model.disconnectError({ ok = false, kind = "failed", detail = "nope" })
eq("model: disconnectError detail key", dWith.key, "error.disconnect_failed_detail")
eq("model: disconnectError detail text", dWith.detail, "nope")
eq("model: disconnectError plain", model.disconnectError({ ok = false, kind = "failed" }).key, "error.disconnect_failed")
eq("model: disconnectError nil outcome", model.disconnectError(nil).key, "error.disconnect_failed")

-- rowTitle
eq("model: rowTitle name", model.rowTitle(conn(0, "DISCONNECTED")), "Work")
eq("model: rowTitle falls back to host", model.rowTitle(conn(0, "DISCONNECTED", { name = "" })), "vpn.example.com")

-- bar priority
local function bar(s, label)
  return model.barView(s, label)
end
local function expectBar(name, v, glyph, color, label)
  eq("model: bar " .. name .. " glyph", v.glyph, glyph)
  eq("model: bar " .. name .. " color", v.color, color)
  eq("model: bar " .. name .. " label", v.label, label)
end
eq("model: GREEN constant", model.GREEN, "#22c55e")
local v = bar(nil)
expectBar("nil snapshot", v, "lock", "on_surface_variant", "")
eq("model: bar nil tooltip", v.tooltip, "tooltip.loading")
expectBar("string snapshot", bar("x"), "lock", "on_surface_variant", "")
expectBar("not installed", bar(snap({}, { installed = false })), "lock-exclamation", "error", "!")
eq("model: bar not installed tooltip", bar(snap({}, { installed = false })).tooltip, "panel.not_installed")
expectBar("service down", bar(snap({ conn(0, "CONNECTED") }, { service = "down" })), "lock-exclamation", "error", "!")
v = bar(snap({ conn(0, "CONNECTED") }, { rebootNeeded = true }))
expectBar("reboot", v, "lock-exclamation", "error", "!")
eq("model: bar reboot tooltip", v.tooltip, "error.reboot_needed")
v = bar(snap({ conn(0, "CONNECTED") }))
expectBar("connected", v, "lock-filled", model.GREEN, "On")
eq("model: bar connected label colour is default text", v.labelColor, "on_surface")
eq("model: bar off label colour follows glyph", bar(snap({ conn(0, "DISCONNECTED") })).labelColor, "on_surface_variant")
eq("model: bar problem label colour follows glyph", bar(snap({}, { installed = false })).labelColor, "error")
eq("model: bar connected tooltip", v.tooltip, "tooltip.connected|host=vpn.example.com")
v = bar(snap({ conn(0, "CONNECTED"), conn(1, "CONNECTED", { host = "vpn2.example.org" }) }))
eq("model: bar two connected tooltip", v.tooltip, "tooltip.connected_n_other|n=2")
expectBar("connected plus unauthorized", bar(snap({ conn(0, "CONNECTED"), conn(1, "DISCONNECTED", { authorized = false }) })), "lock-filled", model.GREEN, "On")
expectBar("connected plus row error", bar(snap({ conn(0, "CONNECTED") }, { rowErrors = { ["0"] = { key = "error.connect_failed" } } })), "lock-filled", model.GREEN, "On")
expectBar("in flight", bar(snap({ conn(0, "DISCONNECTED") }, { inFlight = { ["0"] = "connecting" } })), "lock", "primary", "…")
expectBar("CONNECTING", bar(snap({ conn(0, "CONNECTING") })), "lock", "primary", "…")
expectBar("DISCONNECTING", bar(snap({ conn(0, "DISCONNECTING") })), "lock", "primary", "…")
expectBar("AUTHORIZING", bar(snap({ conn(0, "AUTHORIZING") })), "lock", "primary", "…")
expectBar("in flight beats row error", bar(snap({ conn(0, "DISCONNECTED") }, { inFlight = { ["0"] = "connecting" }, rowErrors = { ["0"] = { key = "error.connect_failed" } } })), "lock", "primary", "…")
v = bar(snap({ conn(0, "DISCONNECTED") }, { rowErrors = { ["0"] = { key = "error.connect_failed_detail", detail = "no route" } } }))
expectBar("row error", v, "lock-exclamation", "error", "!")
eq("model: bar row error tooltip", v.tooltip, "error.connect_failed_detail|detail=no route")
v = bar(snap({}))
expectBar("zero connections", v, "lock-exclamation", "error", "!")
eq("model: bar zero connections tooltip", v.tooltip, "panel.no_connections")
v = bar(snap({ conn(0, "DISCONNECTED", { authorized = false }), conn(1, "DISCONNECTED", { authorized = false }) }))
expectBar("all unauthorized", v, "lock-exclamation", "error", "!")
eq("model: bar all unauthorized tooltip", v.tooltip, "status.needs_signin")
v = bar(snap({ conn(0, "DISCONNECTED"), conn(1, "DISCONNECTED", { authorized = false }) }))
expectBar("off", v, "lock", "on_surface_variant", "Off")
eq("model: bar off tooltip", v.tooltip, "tooltip.disconnected")
eq("model: bar showLabel false blanks", bar(snap({ conn(0, "CONNECTED") }), false).label, "")
eq("model: bar showLabel nil keeps", bar(snap({ conn(0, "CONNECTED") }), nil).label, "On")
eq("model: bar showLabel true keeps", bar(snap({ conn(0, "CONNECTED") }), true).label, "On")

-- panel state order
eq("model: panel nil is loading", model.panelState(nil), "loading")
eq("model: panel not installed first", model.panelState(snap({ conn(0, "CONNECTED") }, { installed = false, service = "down" })), "not_installed")
eq("model: panel service down", model.panelState(snap({ conn(0, "CONNECTED") }, { service = "down" })), "service_down")
eq("model: panel no connections", model.panelState(snap({})), "no_connections")
eq("model: panel list", model.panelState(snap({ conn(0, "DISCONNECTED") })), "list")
eq("model: panel unknown service loading", model.panelState(snap({}, { service = "unknown" })), "loading")

-- row views
local s = snap({})
local r = model.rowView(conn(0, "DISCONNECTED"), s)
eq("model: row disconnected title", r.title, "Work")
eq("model: row disconnected subtitle", r.subtitle, "vpn.example.com")
eq("model: row disconnected status", r.statusKey, "status.disconnected")
eq("model: row disconnected button", r.button, "connect")
eq("model: row disconnected enabled", r.buttonDisabled, false)
eq("model: row disconnected dns", r.dns, nil)
eq("model: row disconnected error", r.error, nil)

r = model.rowView(conn(0, "CONNECTED", { dns = { "198.51.100.2", "198.51.100.3" } }), s)
eq("model: row connected status", r.statusKey, "status.connected")
eq("model: row connected button", r.button, "disconnect")
eq("model: row connected dns", r.dns, "198.51.100.2, 198.51.100.3")
eq("model: row connected empty dns hidden", model.rowView(conn(0, "CONNECTED"), s).dns, nil)
eq("model: row disconnected dns hidden", model.rowView(conn(0, "DISCONNECTED", { dns = { "198.51.100.2" } }), s).dns, nil)

r = model.rowView(conn(0, "DISCONNECTED", { authorized = false }), s)
eq("model: row unauthorized status", r.statusKey, "status.needs_signin")
eq("model: row unauthorized button", r.button, "open_gui")
r = model.rowView(conn(0, "AUTHORIZING"), s)
eq("model: row authorizing status", r.statusKey, "status.needs_signin")
eq("model: row authorizing button", r.button, "open_gui")

r = model.rowView(conn(0, "DISCONNECTED"), snap({}, { inFlight = { ["0"] = "connecting" } }))
eq("model: row connecting status", r.statusKey, "status.connecting")
eq("model: row connecting disabled", r.buttonDisabled, true)
eq("model: row connecting button", r.button, "connect")
r = model.rowView(conn(0, "CONNECTED"), snap({}, { inFlight = { ["0"] = "disconnecting" } }))
eq("model: row disconnecting status", r.statusKey, "status.disconnecting")
eq("model: row disconnecting disabled", r.buttonDisabled, true)
eq("model: row disconnecting button", r.button, "disconnect")

r = model.rowView(conn(0, "TEMPORARILY_OFFLINE"), s)
eq("model: row offline status", r.statusKey, "status.offline")
eq("model: row offline button", r.button, "disconnect")
eq("model: row CONNECTING status", model.rowView(conn(0, "CONNECTING"), s).statusKey, "status.connecting")
eq("model: row DISCONNECTING status", model.rowView(conn(0, "DISCONNECTING"), s).statusKey, "status.disconnecting")

r = model.rowView(conn(0, "DISCONNECTED", { name = "" }), s)
eq("model: row empty name title", r.title, "vpn.example.com")
eq("model: row empty name subtitle", r.subtitle, "user@example.com")
r = model.rowView(conn(0, "DISCONNECTED"), snap({}, { rowErrors = { ["0"] = { key = "error.connect_failed" } } }))
eq("model: row error", r.error and r.error.key, "error.connect_failed")

-- fix: startup loading, nil-safety, GUI-started transitions
v = bar(snap({}, { service = "unknown" }))
expectBar("unknown service no connections is loading", v, "lock", "on_surface_variant", "")
eq("model: bar loading tooltip", v.tooltip, "tooltip.loading")
eq("model: isLoading agrees with panelState", model.isLoading(snap({}, { service = "unknown" })), true)
eq("model: isLoading false when running", model.isLoading(snap({})), false)
expectBar("not installed beats unknown", bar(snap({}, { installed = false, service = "unknown" })), "lock-exclamation", "error", "!")
expectBar("unknown service with connections is not loading", bar(snap({ conn(0, "DISCONNECTED") }, { service = "unknown" })), "lock", "on_surface_variant", "Off")

r = model.rowView(conn(0, "DISCONNECTED", { name = "", account = false }), s)
eq("model: row subtitle never nil", r.subtitle, "")
local noAccount = conn(0, "DISCONNECTED", { name = "" })
noAccount.account = nil
r = model.rowView(noAccount, s)
eq("model: row subtitle nil account", r.subtitle, "")
r = model.rowView(conn(0, "DISCONNECTED"), { connections = {} })
eq("model: row without inFlight/rowErrors tables", r.button, "connect")
eq("model: row without rowErrors", r.error, nil)
r = model.rowView(conn(0, "CONNECTING"), s)
eq("model: GUI-started connecting disabled", r.buttonDisabled, true)
eq("model: GUI-started connecting status", r.statusKey, "status.connecting")
r = model.rowView(conn(0, "DISCONNECTING"), s)
eq("model: GUI-started disconnecting disabled", r.buttonDisabled, true)
eq("model: GUI-started disconnecting status", r.statusKey, "status.disconnecting")

-- fix: a failed first read is an error, not "loading" forever
local readFailed = snap({}, { service = "unknown", lastError = { key = "error.read" } })
eq("model: failed first read is not loading", model.isLoading(readFailed), false)
eq("model: failed first read panel state", model.panelState(readFailed), "read_error")
v = bar(readFailed)
expectBar("failed first read", v, "lock-exclamation", "error", "!")
eq("model: failed first read tooltip", v.tooltip, "error.read")
eq("model: unknown service without error still loading", model.isLoading(snap({}, { service = "unknown" })), true)

-- fix: TEMPORARILY_OFFLINE is in between, not Off
v = bar(snap({ conn(0, "TEMPORARILY_OFFLINE") }))
expectBar("temporarily offline", v, "lock", "primary", "…")
eq("model: temporarily offline tooltip", v.tooltip, "status.offline")
expectBar("offline beside connected", bar(snap({ conn(0, "TEMPORARILY_OFFLINE"), conn(1, "CONNECTED") })), "lock-filled", model.GREEN, "On")

noctalia = savedNoctalia

eq("model: button key open_gui", model.BUTTON_KEYS.open_gui, "button.open_gui")
eq("model: count key one", model.countKey("tooltip.connected_n", 1), "tooltip.connected_n_one")
eq("model: count key other", model.countKey("tooltip.connected_n", 3), "tooltip.connected_n_other")
