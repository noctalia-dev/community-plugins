--!nonstrict
-- Pure presentation model: turns a snapshot into bar/header/error descriptions.

local model = {}

local function tr(key, subst)
  if noctalia and noctalia.tr then
    return noctalia.tr(key, subst)
  end
  return key
end

local function isTunnelState(snapshot, state)
  return snapshot.tunnel ~= nil and snapshot.tunnel.state == state
end

-- Error reasons from talpid-types ErrorStateCause (Linux variants).
local REASON_INFO = {
  set_firewall_policy_error = { key = "error.firewall", actions = { "restart_service", "disconnect" } },
  auth_failed = { key = "error.auth_failed", actions = { "open_account_tab" } },
  ipv6_unavailable = { key = "error.ipv6_unavailable", actions = { "disconnect" } },
  set_dns_error = { key = "error.set_dns", actions = { "restart_service", "disconnect" } },
  start_tunnel_error = { key = "error.start_tunnel", actions = { "disconnect" } },
  tunnel_parameter_error = { key = "error.tunnel_parameter", actions = { "disconnect" } },
  is_offline = { key = "error.offline", actions = { "disconnect" } },
}

local function copy(list)
  local out = {}
  for i = 1, #list do
    out[i] = list[i]
  end
  return out
end

local function tunnelErrorInfo(snapshot)
  local tunnel = snapshot.tunnel
  local reason = tunnel.errorReason
  if reason == "set_firewall_policy_error" and snapshot.kernelModulesPresent == false then
    return { key = "error.kernel_updated", actions = { "reboot_notice" } }
  end
  local known = reason and REASON_INFO[reason]
  if known then
    return { key = known.key, actions = copy(known.actions) }
  end
  return { key = "error.unknown", actions = { "disconnect" } }
end

function model.errorInfo(snapshot)
  if snapshot.daemon == "down" then
    return nil
  end
  if isTunnelState(snapshot, "error") then
    return tunnelErrorInfo(snapshot)
  end
  local tunnel = snapshot.tunnel
  if tunnel and tunnel.state == "disconnected" and tunnel.lockedDown == true then
    return { key = "error.lockdown_blocking", actions = { "connect", "lockdown_off" } }
  end
  local account = snapshot.account
  if account ~= nil then
    if account.expiry == "expired" then
      return { key = "error.expired", actions = { "open_account_page" } }
    end
    if account.loggedIn == false then
      return { key = "error.logged_out", actions = { "open_account_tab" } }
    end
  end
  return nil
end

function model.header(snapshot, showFlags)
  if snapshot.daemon == "down" then
    return { kind = "daemon_down", textKey = "header.daemon_down", subs = {}, actions = { "start_service" } }
  end
  local info = model.errorInfo(snapshot)
  if info then
    local textKey = info.key
    local subs = {}
    if info.key == "error.unknown" then
      local reason = snapshot.tunnel and snapshot.tunnel.errorReason or ""
      if reason == "" then
        textKey = "error.unknown_no_reason"
      else
        subs.reason = (reason:gsub("_", " "))
      end
    end
    return { kind = "error", textKey = textKey, subs = subs, actions = info.actions }
  end
  local tunnel = snapshot.tunnel
  local actions = {}
  if snapshot.bootEnabled == false then
    actions[1] = "enable_service"
  end
  local textKey = "header.unknown"
  local subs = {}
  if tunnel then
    textKey = "header." .. tunnel.state
    subs.place = model.place(snapshot, showFlags)
    if tunnel.state == "connected" and subs.place == "" then
      textKey = "header.connected_nowhere"
    end
  end
  return { kind = "ok", textKey = textKey, subs = subs, actions = actions }
end

-- The tunnel's location as one phrase: "{city} 🇩🇪 Germany" with a flag,
-- "{city}, {country}" without; just the (flagged) country with no city, just the
-- city (never a flag) with no country, and "" when neither is known.
function model.place(snapshot, showFlags)
  local tunnel = snapshot.tunnel or {}
  local city = type(tunnel.city) == "string" and tunnel.city ~= "" and tunnel.city or nil
  local country = type(tunnel.country) == "string" and tunnel.country ~= "" and tunnel.country or nil
  if country == nil then
    return city or ""
  end
  local flagged = model.withFlag(country, model.tunnelCountryCode(snapshot), showFlags)
  if city == nil then
    return flagged
  end
  return tr(model.hasFlag(snapshot, showFlags) and "header.place_flag" or "header.place", { city = city, country = flagged })
end

-- Flag emoji for a two-letter country code (any case): the two regional
-- indicator symbols U+1F1E6.. as UTF-8 (F0 9F 87 A6+n). "" for anything else.
function model.flag(code)
  if type(code) ~= "string" or not code:match("^%a%a$") then
    return ""
  end
  local out = ""
  for letter in code:lower():gmatch("%a") do
    out = out .. string.char(0xF0, 0x9F, 0x87, 0xA6 + letter:byte() - 97)
  end
  return out
end

-- True when withFlag would put a flag on the tunnel's country.
function model.hasFlag(snapshot, showFlags)
  return showFlags == true and model.flag(model.tunnelCountryCode(snapshot)) ~= ""
end

-- name prefixed with its flag and a space when showFlags is true and the code
-- has a flag; otherwise unchanged.
function model.withFlag(name, code, showFlags)
  local flag = showFlags == true and model.flag(code) or ""
  if flag == "" then
    return name
  end
  return flag .. " " .. name
end

-- The relay list's code for a country name, or nil.
function model.countryCodeByName(snapshot, name)
  for _, c in ipairs(type(snapshot.relays) == "table" and snapshot.relays or {}) do
    if c.name == name then
      return c.code
    end
  end
  return nil
end

-- The tunnel's country code: from the relay hostname when it has one, else the
-- relay list entry with the tunnel's country name (a disconnected tunnel reports
-- the visible location by name only).
function model.tunnelCountryCode(snapshot)
  local tunnel = snapshot.tunnel
  if tunnel == nil then
    return nil
  end
  if tunnel.countryCode ~= nil then
    return tunnel.countryCode
  end
  return model.countryCodeByName(snapshot, tunnel.country)
end

function model.bar(snapshot, showFlags)
  local tunnel = snapshot.tunnel
  if snapshot.daemon == "down" or model.errorInfo(snapshot) ~= nil then
    local header = model.header(snapshot, showFlags)
    return {
      label = "!",
      color = "error",
      glyph = "shield-exclamation",
      tooltip = tr(header.textKey, header.subs),
    }
  end
  if tunnel == nil then
    return { label = "…", color = "on_surface_variant", glyph = "shield-off", tooltip = tr("tooltip.unknown") }
  end
  if tunnel.state == "connected" then
    local exit = tunnel.countryCode and tunnel.countryCode:upper() or "VPN"
    local label = exit
    if tunnel.entryCountryCode then
      label = tunnel.entryCountryCode:upper() .. "→" .. exit
    end
    local place = model.place(snapshot, showFlags)
    local tooltip = place == "" and tr("tooltip.connected_nowhere") or tr("tooltip.connected", { place = place })
    if tunnel.ipv4 ~= nil and tunnel.ipv4 ~= "" then
      tooltip = tr("tooltip.with_ip", { text = tooltip, ip = tunnel.ipv4 })
    end
    return {
      label = label,
      color = "tertiary",
      glyph = "shield-check",
      tooltip = tooltip,
    }
  end
  if tunnel.state == "connecting" or tunnel.state == "disconnecting" then
    return { label = "…", color = "primary", glyph = "shield", tooltip = tr("tooltip." .. tunnel.state) }
  end
  return { label = "Off", color = "on_surface_variant", glyph = "shield-off", tooltip = tr("tooltip.disconnected") }
end

-- What the bar widget shows. Loading until a snapshot table arrives; showLabel
-- false (and only false) hides the label.
function model.barView(snapshot, showLabel, showFlags)
  local view
  if type(snapshot) ~= "table" then
    view = { glyph = "shield", color = "on_surface_variant", label = "", tooltip = tr("tooltip.loading") }
  else
    view = model.bar(snapshot, showFlags)
  end
  if showLabel == false then
    view.label = ""
  end
  return view
end

-- ── account ──────────────────────────────────────────────────────────────────

-- "1234567890123456" -> "•••• •••• •••• 3456"; nil without at least 4 digits.
function model.maskAccount(number)
  if type(number) ~= "string" then
    return nil
  end
  local digits = number:gsub("%D", "")
  if #digits < 4 then
    return nil
  end
  return "•••• •••• •••• " .. digits:sub(-4)
end

-- Days since 1970-01-01 of a proleptic Gregorian date (H. Hinnant's days_from_civil).
local function daysFromCivil(y, m, d)
  if m <= 2 then
    y = y - 1
  end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * ((m + 9) % 12) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- "YYYY-MM-DD HH:MM:SS[.frac] +HH:MM" (how `account get` prints the expiry, in
-- local time with its offset) -> Unix seconds, or nil.
function model.expiresAtSeconds(text)
  if type(text) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s, sign, oh, om =
    text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):(%d%d)%.?%d* ([%+%-])(%d%d):(%d%d)$")
  if y == nil then
    return nil
  end
  local offset = tonumber(oh) * 3600 + tonumber(om) * 60
  if sign == "-" then
    offset = -offset
  end
  return daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s) - offset
end

local WARN_SECONDS = 7 * 86400

-- "ok" | "warn" (under 7 days left) | "expired", or nil when the text does not parse.
function model.expiryLevel(expiresAt, nowSeconds)
  local at = model.expiresAtSeconds(expiresAt)
  if at == nil or type(nowSeconds) ~= "number" then
    return nil
  end
  local left = at - nowSeconds
  if left <= 0 then
    return "expired"
  end
  if left < WARN_SECONDS then
    return "warn"
  end
  return "ok"
end

-- Replace every run of 16 or more digits (account numbers) with '#'.
function model.scrub(text)
  return (tostring(text):gsub("%d+", function(run)
    if #run >= 16 then
      return string.rep("#", #run)
    end
    return nil
  end))
end

return model
