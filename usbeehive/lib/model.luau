--!nonstrict
-- Shared model: turns `usbeehive --json` output into the snapshot the service
-- publishes over noctalia.state, and owns every derived decision (which
-- devices are peripherals, which way power flows) plus the formatting helpers
-- the widget and panel share. Pure functions only - no host calls.

local M = {}

-- noctalia.state "command" protocol between the views and the service.
M.REFRESH = "refresh"

function M.refreshCommand(nowMs)
  return { action = M.REFRESH, at = nowMs } -- `at` makes repeated refreshes distinct
end

local CLASS_GLYPHS = {
  Keyboard = "keyboard",
  Mouse = "mouse",
  InputTablet = "writing",
  Gamepad = "device-gamepad-2",
  Storage = "database",
  Display = "device-desktop",
  Audio = "headphones",
  Camera = "camera",
  VideoCapture = "video",
  Printer = "printer",
  Phone = "device-mobile",
  Hub = "sitemap",
  NetworkWired = "network",
  NetworkWireless = "wifi",
  SecurityKey = "key",
  SmartcardReader = "id",
  Bluetooth = "bluetooth",
  Serial = "terminal-2",
}

local FLOW_GLYPHS = { charging = "bolt", supplying = "arrow-up-right", idle = "usb" }

-- JSON nulls may decode to a sentinel rather than nil, so every field read is
-- type-checked instead of truth-tested.
local function tbl(v)
  return type(v) == "table" and v or nil
end

local function str(v)
  return type(v) == "string" and v or ""
end

local function num(v)
  return type(v) == "number" and v or 0
end

function M.watts(mw)
  local w = num(mw) / 1000
  if w < 10 then
    return string.format("%.1fW", w)
  end
  return string.format("%.0fW", w)
end

function M.speed(mbps)
  mbps = num(mbps)
  if mbps <= 0 then
    return ""
  elseif mbps >= 1000 then
    return string.format("%g Gbps", mbps / 1000)
  end
  return string.format("%g Mbps", mbps)
end

function M.pdoLabel(p)
  if p.voltageMV > 0 then
    return string.format("%s %gV %gA (%s)", p.type, p.voltageMV / 1000, p.currentMA / 1000, M.watts(p.powerMW))
  end
  return string.format("%s %gA", p.type, p.currentMA / 1000)
end

function M.flowGlyph(mode)
  return FLOW_GLYPHS[mode] or "usb"
end

-- The full snapshot shape, before the first reading arrives. Views never need
-- to special-case a missing or partial snapshot.
function M.emptySnapshot()
  return {
    status = "starting", -- "starting" | "ok" | "error"
    error = nil,
    devices = {},
    count = 0,
    flow = { mode = "idle", mw = 0, requested = false },
    warnings = {},
  }
end

local function deviceKey(d, usb, typec)
  if typec then
    return "typec-" .. tostring(num(typec.port))
  end
  local where
  if usb and str(usb.serial) ~= "" then
    where = usb.serial
  elseif usb then
    where = tostring(num(usb.bus)) .. "-" .. tostring(num(usb.device))
  else
    where = str(d.headline)
  end
  return str(d.vendorId) .. ":" .. str(d.productId) .. ":" .. where
end

-- One usbeehive device entry -> the flat table the UI consumes.
local function simplify(d)
  local usb = tbl(d.usb)
  local typec = tbl(d.typec)
  local power = tbl(d.power) or {}
  local psy = typec and tbl(typec.powerSupply)
  local category = str(d.category)
  local status = str(d.status)
  local charging = tbl(d.charging)
  local cable = tbl(d.cable)
  local pd = tbl(d.powerDelivery)

  local pdos = {}
  if pd and tbl(pd.sourceCapabilities) then
    for _, p in ipairs(pd.sourceCapabilities) do
      if type(p) == "table" then
        table.insert(pdos, {
          type = str(p.type),
          voltageMV = num(p.voltageMV),
          currentMA = num(p.currentMA),
          powerMW = num(p.powerMW),
          active = p.active == true,
        })
      end
    end
  end

  local glyph
  if category == "typec" then
    glyph = status == "Empty" and "plug" or "plug-connected"
  else
    glyph = CLASS_GLYPHS[str(d.deviceClass)] or "usb"
  end

  return {
    key = deviceKey(d, usb, typec),
    category = category,
    isPeripheral = category == "usb",
    status = status,
    glyph = glyph,
    headline = str(d.headline),
    subtitle = str(d.subtitle),
    vendorId = str(d.vendorId),
    productId = str(d.productId),
    driver = str(d.primaryDriver),
    linkSpeedMbps = num(d.linkSpeedMbps),
    usbVersion = str(d.usbVersion),
    removable = usb and str(usb.removable) or "",
    -- usbeehive already resolves these: >0 exactly while sinking / sourcing,
    -- preferring the UCSI operating point over the PDO estimate.
    inMW = num(power.powerInMW),
    outMW = num(power.powerOutMW),
    contractMW = num(power.contractMW),
    -- True when inMW is the device's own requested operating point (UCSI)
    -- rather than the charger's active-profile estimate.
    requested = psy ~= nil and psy.online == true and num(psy.negotiatedPowerMW) > 0,
    charging = charging and {
      summary = str(charging.summary),
      detail = str(charging.detail),
      isWarning = charging.isWarning == true,
    } or nil,
    cable = cable and {
      kind = str(cable.type),
      speed = str(cable.speed),
      current = str(cable.current),
      maxWatts = num(cable.maxWatts),
      vendor = str(cable.vendorName),
    } or nil,
    pdos = pdos,
  }
end

local CATEGORY_ORDER = { typec = 1, usb = 2, hub = 3 }

-- Full usbeehive array -> the published snapshot.
--   opts.hideInternal: drop devices whose sysfs `removable` is "fixed"
--   opts.showHubs:     keep hub entries
function M.buildSnapshot(raw, opts)
  local snap = M.emptySnapshot()
  snap.status = "ok"
  local inMW, outMW, charging, supplying, requested = 0, 0, false, false, false

  for _, entry in ipairs(raw) do
    if type(entry) == "table" then
      local d = simplify(entry)
      local hidden = (d.category == "hub" and not opts.showHubs) or (opts.hideInternal and d.removable == "fixed")
      if not hidden then
        table.insert(snap.devices, d)
        if d.isPeripheral then
          snap.count += 1
        end
      end
      -- Power and diagnostics count even for hidden entries.
      inMW += d.inMW
      outMW += d.outMW
      charging = charging or d.status == "Charging"
      supplying = supplying or d.status == "Sourcing"
      requested = requested or (d.inMW > 0 and d.requested)
      if d.charging and d.charging.isWarning then
        table.insert(snap.warnings, { key = d.key, headline = d.headline, summary = d.charging.summary, detail = d.charging.detail })
      end
    end
  end

  -- Outbound wattage is usually unreported (usbeehive: "the role flag
  -- carries"), so supplying can be active with mw = 0.
  if charging then
    snap.flow = { mode = "charging", mw = inMW, requested = requested }
  elseif supplying then
    snap.flow = { mode = "supplying", mw = outMW, requested = false }
  end

  table.sort(snap.devices, function(a, b)
    local ca, cb = CATEGORY_ORDER[a.category] or 9, CATEGORY_ORDER[b.category] or 9
    if ca ~= cb then
      return ca < cb
    end
    return string.lower(a.headline) < string.lower(b.headline)
  end)

  return snap
end

return M
