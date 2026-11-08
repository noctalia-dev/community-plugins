--!nonstrict
-- Pure presentation model: turns a ufw.state snapshot into bar/header/debug descriptions.
-- No noctalia calls except the optional translation lookup.

local model = {}

local GREEN = "#22c55e"
local AMBER = "#f59e0b"
local E2E_PREFIX = "noctalia-ufw-e2e-"

local function tr(key, subst)
  if noctalia and noctalia.tr then
    return noctalia.tr(key, subst)
  end
  return key
end

-- noctalia.tr has no plural forms, so every message with a count has two keys: <key>_one
-- (n == 1) and <key>_other. Pass the base key and the count; without a number n the key is
-- returned unchanged.
function model.countKey(key, n)
  if type(n) ~= "number" then
    return key
  end
  if n == 1 then
    return key .. "_one"
  end
  return key .. "_other"
end

function model.status(snap)
  if snap == nil then
    return "unknown"
  end
  if not snap.installed then
    return "missing"
  end
  if snap.enabled == nil then
    return "unknown"
  end
  if snap.enabled == false then
    return "off"
  end
  if not snap.hasSystemctl then
    return "on"
  end
  local active = nil
  if type(snap.unit) == "table" then
    active = snap.unit.active
  end
  if active == nil then
    return "unknown" -- `systemctl show` not answered yet, failed or timed out
  end
  if active == "active" then
    return "on"
  end
  if active == "failed" then
    return "failed"
  end
  -- Turned off from the panel (systemctl stop): ufw.conf still says yes and the unit is
  -- enabled at boot, so a restart brings the firewall back.
  if active == "inactive" and (snap.unit or {}).bootEnabled == true then
    return "stopped"
  end
  return "not_running"
end

-- Whether the panel's switch shows "on": only while the firewall is on (green). In the amber
-- states (not running, failed) it shows off, and flipping it on runs Turn on, which starts
-- (or restarts) the unit.
function model.switchOn(snap)
  return model.status(snap) == "on"
end

function model.allowedCount(rules)
  local n = 0
  for _, r in ipairs(rules or {}) do
    if (r.action == "allow" or r.action == "limit") and r.direction == "in" and not r.route then
      n = n + 1
    end
  end
  return n
end

function model.barView(snap, showLabel, showCount)
  if snap == nil then
    return {
      dot = "on_surface_variant",
      text = showLabel and tr("bar.unknown") or nil,
      count = nil,
      tooltip = tr("tooltip.loading"),
    }
  end
  local status = model.status(snap)
  local dot = "on_surface_variant"
  local textKey = "bar.unknown"
  local count = nil
  local tooltip
  local loading = status == "unknown" and snap.source == "loading"
  if status == "on" then
    dot = GREEN
    textKey = "bar.on"
    local n = model.allowedCount(snap.rules)
    if showCount then
      count = tostring(n)
    end
    tooltip = tr(model.countKey("tooltip.on", n), { n = n })
  else
    if status == "off" or status == "stopped" then
      dot = "error"
      textKey = "bar.off"
    elseif status == "not_running" or status == "failed" then
      dot = AMBER
    end
    tooltip = tr("tooltip." .. status)
    if loading then
      tooltip = tr("tooltip.loading")
    elseif status == "unknown" and snap.enabled ~= nil then
      -- ufw.conf was read: it is `systemctl show` that can't report the unit
      tooltip = tr("tooltip.unit_unknown")
    end
  end
  if snap.testMode == true then
    tooltip = tr("tooltip.test_mode", { text = tooltip })
  end
  return {
    dot = dot,
    text = showLabel and tr(textKey) or nil,
    count = count,
    tooltip = tooltip,
  }
end

local WARNING = { off = "warning.off", stopped = "warning.off", not_running = "warning.not_running", failed = "warning.failed" }
local PRIMARY = { off = "turn_on", stopped = "turn_on", not_running = "start_service", unknown = "load_rules" }
local LINE = {
  on = "header.on",
  off = "header.off",
  stopped = "header.stopped",
  not_running = "header.not_running",
  failed = "header.failed",
  missing = "header.missing",
  unknown = "header.unknown",
}

-- source "loading": nothing read yet (startup, or test mode just switched), which is not
-- "unreadable". Load rules is only offered when ufw.conf can't be read; an unknown unit state
-- (systemctl show failing) has its own line and offers nothing.
function model.header(snap)
  local status = model.status(snap)
  snap = snap or {}
  local lineKey = LINE[status]
  local primary = PRIMARY[status]
  if status == "unknown" and snap.source == "loading" then
    lineKey = "panel.loading"
    primary = nil
  elseif status == "unknown" and snap.enabled ~= nil then
    lineKey = "header.unit_unknown"
    primary = nil
  end
  if status == "on" then
    local input = snap.defaults and snap.defaults.input
    if input == "ACCEPT" then
      lineKey = "header.on_open"
    elseif input == "DROP" or input == "REJECT" then
      lineKey = "header.on_blocked"
    end
  end
  return {
    status = status,
    lineKey = lineKey,
    warningKey = WARNING[status],
    primary = primary,
    bootNotice = status == "on" and snap.hasSystemctl == true and snap.unit ~= nil and snap.unit.bootEnabled == false,
  }
end

-- Counts and keys only: no ports, addresses, app names or comments (except test comments).
function model.debugView(snap)
  local status = model.status(snap)
  snap = snap or {}
  local kinds = {}
  for _, op in ipairs(snap.pending or {}) do
    kinds[#kinds + 1] = op.kind
  end
  local e2e = {}
  for _, r in ipairs(snap.rules or {}) do
    if type(r.comment) == "string" and r.comment:sub(1, #E2E_PREFIX) == E2E_PREFIX then
      e2e[r.comment] = r.id
    end
  end
  return {
    seq = snap.seq,
    status = status,
    enabled = snap.enabled,
    unitActive = snap.unit and snap.unit.active,
    ruleCount = #(snap.rules or {}),
    allowedCount = model.allowedCount(snap.rules),
    pendingCount = #kinds,
    pendingKinds = kinds,
    busy = snap.busy,
    lastErrorKey = snap.lastError and snap.lastError.key,
    noticeKey = snap.notice and snap.notice.key,
    e2eRuleIds = e2e,
  }
end

return model
