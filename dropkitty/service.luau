-- dropkitty service: mirrors settings to the helper and turns helper events into the
-- bar state at noctalia.state["dropkitty"] = { alive, open, badge, error }.
-- The helper (bin/dropkitty) owns kitty; this entry only observes and configures it.

local KEY = "dropkitty"
local DEFAULT_THICKNESS = 34 -- Style::barThicknessDefault
local BAR_POLL_MS = 10000 -- bar edits do not fire onConfigChanged; re-check reserves this often

local snap = { alive = false, open = false, badge = nil, error = nil }
local last_reserves = nil

local function publish()
  noctalia.state.set(KEY, { alive = snap.alive, open = snap.open, badge = snap.badge, error = snap.error })
end

local function helper()
  local dir = noctalia.pluginDir and noctalia.pluginDir()
  return dir and (dir .. "/bin/dropkitty") or nil
end

local function num(v, fallback)
  local n = tonumber(v)
  return n or fallback
end

-- Space each noctalia bar reserves per screen edge, mirroring reservedBarExclusiveZone()
-- without the shadow-bleed term (over-reserves by at most the bar's edge margin).
local function reserves()
  local r = { top = 0, bottom = 0, left = 0, right = 0 }
  if noctalia.getConfig("bar_aware") == false then
    return r
  end
  local bars = noctalia.getSetting and noctalia.getSetting("bar")
  if type(bars) ~= "table" then
    return r
  end
  for _, b in pairs(bars) do
    -- `order` and other arrays sit beside the named bar tables; skip them.
    if type(b) == "table" and #b == 0 and b.enabled ~= false and b.reserve_space ~= false then
      local pos = b.position or "top"
      local zone = num(b.thickness, DEFAULT_THICKNESS)
        + math.max(0, num(b.margin_edge, 0))
        + math.max(0, num(b.margin_opposite_edge, 0))
      if r[pos] then
        r[pos] = math.max(r[pos], math.floor(zone))
      end
    end
  end
  return r
end

local function setting(key, fallback)
  local v = noctalia.getConfig(key)
  if v == nil then
    return fallback
  end
  return v
end

local function reserves_key(r)
  return r.top .. "," .. r.bottom .. "," .. r.left .. "," .. r.right
end

local function settings_argv(bin)
  local r = reserves()
  last_reserves = reserves_key(r)
  local conf = setting("kitty_conf", "")
  return {
    bin,
    "_settings",
    "orientation=" .. setting("orientation", "landscape"),
    "edge_h=" .. setting("edge_h", "top"),
    "edge_v=" .. setting("edge_v", "right"),
    "size=" .. setting("size", "normal"),
    "normal_height=" .. math.floor(num(setting("normal_height", 40), 40)),
    "normal_width=" .. math.floor(num(setting("normal_width", 50), 50)),
    "opacity=" .. string.format("%.2f", num(setting("opacity", 0.9), 0.9)),
    "focus_policy=" .. setting("focus_policy", "on-demand"),
    "hide_on_focus_loss=" .. (setting("hide_on_focus_loss", false) and "yes" or "no"),
    "kitty_conf=" .. (conf ~= "" and noctalia.expandPath(conf) or ""),
    "reserve_top=" .. r.top,
    "reserve_bottom=" .. r.bottom,
    "reserve_left=" .. r.left,
    "reserve_right=" .. r.right,
  }
end

local function report(result)
  local code = type(result) == "table" and result.exitCode or 0
  if code ~= 0 then
    local msg = type(result) == "table" and result.stderr or ""
    snap.error = (msg ~= "" and msg:gsub("%s+$", "")) or ("exit " .. tostring(code))
  else
    snap.error = nil
  end
  publish()
end

local function sync_settings()
  local bin = helper()
  if bin then
    noctalia.runAsync(settings_argv(bin), report)
  end
end

local function refresh_status()
  local bin = helper()
  if not bin then
    return
  end
  noctalia.runAsync({ bin, "status" }, function(result)
    local out = type(result) == "table" and result.stdout or ""
    snap.alive = out:match("alive=1") ~= nil
    snap.open = snap.alive and out:match("visible=1") ~= nil
    report(result)
  end)
end

function onIpc(event, payload)
  if event == "shown" then
    snap.alive, snap.open, snap.badge = true, true, nil
  elseif event == "hidden" then
    snap.alive, snap.open = true, false
  elseif event == "exited" then
    snap.alive, snap.open, snap.badge = false, false, nil
  elseif event == "cmd-finished" then
    if not snap.alive then
      return -- kitty can report the shell's `exit` after the last window closed
    end
    snap.badge = math.floor(num(payload, 0))
  else
    return
  end
  publish()
end

function onConfigChanged()
  sync_settings()
end

function update()
  if reserves_key(reserves()) ~= last_reserves then
    sync_settings()
  end
end

publish()
sync_settings()
refresh_status()
noctalia.setUpdateInterval(BAR_POLL_MS)
