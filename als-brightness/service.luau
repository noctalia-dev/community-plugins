--!nonstrict
-- Noctalia [[service]] entry point for ambient-light adaptive panel brightness.
--
-- This file and hardware.luau are the only places that touch hardware, the shell
-- or the filesystem; hardware.luau does it through an injected environment, so a
-- fake machine can replace it in tests. All decision logic lives in pure modules,
-- which run under a bare `luau` and are unit-tested offline:
--
--   hardware.luau    device discovery: every path the service uses, probed at start
--   adaptation.luau  the adaptation session: what to DO this tick (the
--                    idle/override/learning timeline, decide() with an
--                    injected clock)
--   policy.luau      temporal shaping, the override window, the guards
--   curve.luau       the user-owned mapping curves (PCHIP interpolation)
--   curve_source.luau  which curve is live, and why: config readers, precedence,
--                    learned nudges, and every curve log line (one report)
--   profile.luau     the learned profile fitted from the owner's overrides
--   colortemp.luau   the night-light config splice and its guard rail
--   temperature.luau the night-light temperature write path: the splice gate
--                    and the applied-K bookkeeping (one function, injected IO)
--
-- What is left here is a thin, boring shim: read settings and sysfs into one
-- snapshot, hand it to adaptation.decide() with the injected clock, and perform
-- the returned actions (IO only) in order.
--
-- Design notes and the measurements behind every constant: docs/DESIGN.md.

local policy = require("./policy.luau")
local adaptation = require("./adaptation.luau")
local curve_source = require("./curve_source.luau")
local temperature = require("./temperature.luau")
local profile = require("./profile.luau")
local hardware = require("./hardware.luau")

-- ── hardware report ─────────────────────────────────────────────────────────
-- Every device path is resolved ONCE by hardware.discover() at start (the start
-- block at the bottom of this file): no path, device number or connector is ever
-- guessed here, and the report stays their single home -- reads go through
-- HW.paths.* / HW.devices.* rather than through copies that could drift. Until
-- the probe runs HW is nil, and while a required device is missing HW_OK stays
-- false and every entry point returns early.
local HW  -- the full discovery report: paths, devices, reason lists, guard_state
local HW_OK = false
local HW_ENV  -- injected env, shared by the probe and the per-tick guard reads

-- ── config ───────────────────────────────────────────────────────────────────
-- Every reader tolerates the wrong type rather than trusting the stored config,
-- because a settings file is a file the owner can edit by hand.
local function setting_bool(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "boolean" then return value end
  return fallback
end

local function setting_number(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "number" then return value end
  if type(value) == "string" then return tonumber(value) or fallback end
  return fallback
end

local function setting_string(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "string" and value ~= "" then return value end
  if type(value) == "number" then return tostring(value) end
  return fallback
end

-- The curve keys ("curve_brightness", "thr_brightness_01".."thr_temperature_10",
-- "learning_profile") are read by curve_source.luau, which owns their tolerance
-- rules; the snapshot below is the only thing this file does with them.
local function snapshot_settings()
  local settings = {}
  for _, key in ipairs(curve_source.setting_keys()) do
    settings[key] = noctalia.getConfig(key)
  end
  return settings
end

-- ── logging ──────────────────────────────────────────────────────────────────
-- writeFile replaces the file, so keep a bounded ring buffer in memory and rewrite
-- it. That gives real history without needing an append mode.
local DATA_DIR
do
  local ok, dir = pcall(noctalia.pluginDataDir)
  DATA_DIR = (ok and type(dir) == "string" and dir or "/tmp")
end
local LOG_PATH = DATA_DIR .. "/als-brightness.log"
local PROFILE_PATH = DATA_DIR .. "/profile.json"

local LOG_LINES = {}
local LOG_KEEP = 200

local function log(line)
  LOG_LINES[#LOG_LINES + 1] = line
  while #LOG_LINES > LOG_KEEP do
    table.remove(LOG_LINES, 1)
  end
  noctalia.writeFile(LOG_PATH, table.concat(LOG_LINES, "\n") .. "\n")
end

--- Log a line once per run: runtime read failures repeat every tick, and the log
--- is a bounded ring buffer, so a repeating line would evict real history.
local WARNED = {}
local function warn_once(key, line)
  if WARNED[key] then return end
  WARNED[key] = true
  log(line)
end

-- ── config-derived state ─────────────────────────────────────────────────────
local CFG = {}
for k, v in pairs(policy.DEFAULTS) do CFG[k] = v end
-- CFG.enabled / CFG.colortemp_enabled are filled by reload() below.

-- ── the adaptation session ───────────────────────────────────────────────────
-- One explicit state table, owned by adaptation.decide()'s timeline: what the
-- session has seen (log, last_written, override, idle, locked, last_reason) and
-- what it has done (last_ms, applied_k, last_temp_s). The learned profile and
-- the curve-source report live here too, because decide() records observations
-- and rebuilds the curves as part of the decision. Two fields are written from
-- IO outcomes, never by decide(): `locked` (the async status poll below) and
-- `applied_k`/`last_temp_s` (temperature.write_path's splice bookkeeping --
-- its ONE owner, see temperature.luau).
--
-- cs is the curve-source report from curve_source.resolve(): which curve the
-- tick evaluates, and why. curve_settings is one snapshot of the curve config
-- keys, so the per-observation rebuild re-lays learned nudges on the exact
-- thresholds reload() saw instead of re-reading config mid-flight.
local SESSION = {
  log = nil,            -- stabilised log10 reading
  last_written = nil,   -- percent we last commanded
  override = nil,       -- {raw=, percent=, at=} -- at in SECONDS
  idle = false,         -- set by the idle handshake, not inferred
  locked = false,       -- refreshed by a slow poll
  last_reason = nil,
  last_ms = nil,        -- injected clock, MILLISECONDS
  applied_k = nil,      -- night-light temperature we last wrote
  last_temp_s = nil,
  profile = profile.new(),
  curve_settings = {},
  cs = nil,
}

local function load_profile()
  local text = noctalia.readFile(PROFILE_PATH)
  if text == nil or text == "" then return end
  local ok, decoded = pcall(noctalia.json.decode, text)
  if not ok or decoded == nil then
    -- A corrupt profile must cost the learned data, never the service.
    log("profile: cannot parse " .. PROFILE_PATH .. "; starting a fresh one")
    return
  end
  SESSION.profile = profile.sanitise(decoded)
end

local LAST_SAVE_S = nil
local DIRTY = false

local function save_profile(now_s, force)
  if not DIRTY and not force then return end
  -- Throttled rather than saved per observation: holding a brightness key fires
  -- many events, and this file is a convenience, not a transaction log.
  if not force and LAST_SAVE_S ~= nil and (now_s - LAST_SAVE_S) < 2 then
    return
  end
  SESSION.profile.updated_at = math.floor(now_s)
  local ok, encoded = pcall(noctalia.json.encode, SESSION.profile)
  if not ok or encoded == nil then return end
  if noctalia.writeFile(PROFILE_PATH, encoded) then
    DIRTY = false
    LAST_SAVE_S = now_s
  end
end

local function reload()
  CFG.enabled = setting_bool("enabled", true)
  CFG.colortemp_enabled = setting_bool("colortemp", false)
  -- The connector comes from the start probe (HW.devices.connector), never
  -- from a guess; changing the setting takes effect on the next plugin restart
  -- (hardware is probed once).
  CFG.min_percent = setting_number("min_percent", 15)
  CFG.max_percent = setting_number("max_percent", 100)

  -- Which curve is live, and why: curve_source absorbs the curve-key readers,
  -- the map-vs-sliders precedence, the learned nudges and every curve log line.
  -- The lines come back verbatim (and in the old order) so this file only
  -- decides WHEN to write them -- the per-observation rebuild stays silent.
  SESSION.curve_settings = snapshot_settings()
  SESSION.cs = curve_source.resolve(SESSION.curve_settings, { profile = SESSION.profile })
  for _, line in ipairs(SESSION.cs.log) do
    log(line)
  end
end

-- ── IO helpers ───────────────────────────────────────────────────────────────
local function trim(s)
  if s == nil then return nil end
  return (tostring(s):gsub("%s+$", ""))
end

local function read_num(path)
  return tonumber(trim(noctalia.readFile(path)))
end

-- ── the slow lock poll ───────────────────────────────────────────────────────
-- `noctalia msg status` is the only way to learn the lock state, and shelling out
-- every second would be wasteful, so decide() emits `poll_lock` on its own slow
-- cadence and this runs it. RunAsync with an argv table needs plugin_api 24,
-- which is why the manifest declares it.
local function poll_locked()
  noctalia.runAsync({ "noctalia", "msg", "status" }, function(result)
    if result == nil or result.exitCode ~= 0 then return end
    local ok, decoded = pcall(noctalia.json.decode, result.stdout or "")
    if ok and type(decoded) == "table" and decoded.locked ~= nil then
      SESSION.locked = decoded.locked and true or false
    end
  end, 4000)
end

-- ── applying a change ────────────────────────────────────────────────────────
local function write_percent(pct)
  local frac = pct / 100.0
  noctalia.runAsync({ "noctalia", "msg", "brightness-set", HW.devices.connector,
                      string.format("%.4f", frac) }, nil, 4000)
  -- decide() records what we asked for in SESSION.last_written, not what we read
  -- back: the readback path has its own transfer curve (actual ~= requested), but
  -- `brightness` is the value both brightnessctl and Noctalia agree on, and it is
  -- what we compare against.
end

-- ── the learned profile ──────────────────────────────────────────────────────
-- Recording an observation (profile.add + the curve rebuild) is part of the
-- timeline decision and lives in adaptation.decide(); what is left here is
-- persistence. A `record` action means the observation is already folded into
-- SESSION.profile / SESSION.cs and wants saving.

-- ── colour temperature ───────────────────────────────────────────────────────
-- Noctalia owns the gamma LUT, so rather than opening a second writer on
-- zwlr_gamma_control_v1 we edit its own setting and ask it to reload. The edit is
-- an atomic replace (write a sibling, rename over the target) so a reader never
-- sees a half-written file, and the content is spliced as text so the user's
-- comments and key order survive.
--
-- The write path itself -- which attempt skips, which performs, and what each
-- does to the applied-K bookkeeping -- is temperature.write_path(): one pure
-- function over an injected environment (the hardware.discover() shape), so
-- every exit path lives in one place and each is named in
-- tests/temperature.test.luau. What is left here is the IO bindings and the
-- executor dispatch.
--
-- perform is forward-declared because the write path hands its action list back
-- to the executor, exactly like decide()'s list.
local perform

local function apply_temperature(kelvin, now_s)
  perform(temperature.write_path(SESSION, kelvin, now_s, {
    settings_path = HW.paths.settings_path,
    read_file = noctalia.readFile,
    write_file = noctalia.writeFile,
    rename = noctalia.renameFile,
    reload = function()
      noctalia.runAsync({ "noctalia", "msg", "config-reload" }, nil, 8000)
    end,
  }))
end

-- ── the executor ─────────────────────────────────────────────────────────────
-- Walks decide()'s action list in order. Everything here is IO or IO feedback;
-- every choice about WHAT to do was already made in adaptation.decide().
perform = function(actions)
  for _, action in ipairs(actions) do
    local kind = action.kind
    if kind == "log" then
      log(action.line)
    elseif kind == "warn_once" then
      warn_once(action.key, action.line)
    elseif kind == "write" then
      write_percent(action.percent)
    elseif kind == "record" then
      -- The observation is already folded into SESSION.profile / SESSION.cs
      -- (decide() did the pure part); what is left is the persistence half of
      -- the old record_observation: mark dirty, throttled save.
      DIRTY = true
      save_profile(action.now_s, false)
    elseif kind == "save_profile" then
      save_profile(action.now_s, action.force)
    elseif kind == "poll_lock" then
      poll_locked()
    elseif kind == "apply_temperature" then
      apply_temperature(action.kelvin, action.now_s)
    end
  end
end

-- The snapshot decide() reads: sysfs plus the hardware guards. All IO lives
-- here; a read that fails yields nil and decide() decides what that means (hold,
-- warn once) -- the path strings the warn lines quote ride along in opts.paths.
local function read_observed()
  local observed = {}
  observed.raw = read_num(HW.paths.als_raw)
  observed.percent = policy.percent_of(read_num(HW.paths.bl_cur), read_num(HW.paths.bl_max))
  observed.guards = HW.guard_state(HW_ENV)
  if CFG.colortemp_enabled then
    observed.ambient_k = read_num(HW.paths.als_ct)
  end
  return observed
end

-- ── the tick ─────────────────────────────────────────────────────────────────
local ticks = 0
noctalia.setUpdateInterval(1000)

function update()
  if not HW_OK then return end
  ticks = ticks + 1
  -- The clock is INJECTED as a reading (noctalia.nowMs, milliseconds); decide()
  -- converts to seconds exactly once. Nothing below this line does time math.
  -- Sampled first and hoisted to a local: Lua argument-evaluation order is
  -- unspecified, and the clock must be the tick's instant, not "somewhere
  -- around" the observation.
  local now_ms = noctalia.nowMs()
  local observed = read_observed()
  perform(adaptation.decide(SESSION, ticks, observed, {}, CFG,
    { now_ms = now_ms, paths = HW.paths }))
end

-- ── hooks ────────────────────────────────────────────────────────────────────
-- The idle chain is an explicit handshake, because logind IdleHint is never set on
-- this setup and DPMS only flips at the 70 s screen-off, leaving a ~20 s window
-- where the panel is deliberately dimmed and still DPMS-On. The idle behaviour in
-- ~/.config/noctalia/config.toml therefore emits these events (see docs/DESIGN.md,
-- "idle handshake").
function onIpc(event, _payload)
  if not HW_OK then
    warn_once("ipc-while-down", "ipc event '" .. tostring(event) .. "' ignored: hardware unavailable")
    return
  end
  -- The event is decided at its own instant (tick = nil): the handshake and the
  -- keybinding signal land in the log when they happen, never a tick later. The
  -- event vocabulary and every state transition live in adaptation.decide().
  -- Clock first, hoisted, same as the tick above.
  local now_ms = noctalia.nowMs()
  local observed = read_observed()
  perform(adaptation.decide(SESSION, nil, observed, { event }, CFG,
    { now_ms = now_ms, paths = HW.paths }))
end

function onConfigChanged()
  reload()
  if not HW_OK then
    log("config changed; hardware still unavailable -- toggle the plugin to re-probe")
    return
  end
  log("config changed; curves rebuilt, now using " .. SESSION.cs.brightness.source)
end

-- ── start ────────────────────────────────────────────────────────────────────
-- The probe runs FIRST, before the profile, the curves or any tick: hardware
-- availability is decided exactly once, here. Nothing below runs when a required
-- device is missing -- the service idles, says why, and never writes to a panel
-- it cannot see.
HW_ENV = { listDir = noctalia.listDir, readFile = noctalia.readFile,
           outputs = noctalia.outputs, getenv = noctalia.getenv }
HW = hardware.discover(HW_ENV,
  { backlight = setting_string("backlight", ""),
    connector = setting_string("connector", "") })

for _, note in ipairs(HW.degraded) do
  log("hardware degraded: " .. note)
end

if #HW.required_missing > 0 then
  for _, reason in ipairs(HW.required_missing) do
    log("hardware unavailable: " .. reason)
  end
  noctalia.notifyError("ALS Brightness: hardware unavailable",
    table.concat(HW.required_missing, "\n"))
  log("service idle: nothing will be written; fix the hardware and toggle the plugin to re-probe")
  return
end
HW_OK = true

load_profile()
reload()

log(string.format("hardware: als=%s backlight=%s connector=%s%s%s%s",
  tostring(HW.devices.als), tostring(HW.devices.backlight),
  tostring(HW.devices.connector),
  HW.devices.colortemp and " colortemp=" .. HW.devices.colortemp or "",
  HW.paths.dpms ~= nil and " dpms=" .. HW.paths.dpms or "",
  HW.devices.lid ~= nil and " lid=" .. HW.devices.lid or ""))
log("service starting: connector=" .. tostring(HW.devices.connector)
  .. " brightness=" .. tostring(HW.paths.bl_cur)
  .. " observations=" .. tostring(#SESSION.profile.observations))
