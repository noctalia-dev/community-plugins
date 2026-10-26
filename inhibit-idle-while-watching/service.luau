--!nonstrict
-- inhibit-idle-while-watching service: the Noctalia side of the handshake.
--
-- Noctalia's idle behaviour fires `noctalia msg plugin <id>:<entry> all
-- idle-begin` (configured by the user; the README ships the exact snippet).
-- That is this plugin's ONLY trigger -- the plugin API exposes no idle hook.
-- On a trigger we spawn one `face-watch gate` (python helper): it captures,
-- detects, and on a face restarts the idle countdown (one synthetic Shift
-- tap via wtype). Stateless: nothing is held and no process outlives the check.
--
-- This file stays thin on purpose: spawn policy lives in policy.luau (pure,
-- tested), everything IO-heavy lives in the helper (tested without hardware).
-- The service owns: settings reads, the status-file overlap check, spawn argv.

-- Require resolution differs between the host (".luau" suffix) and bare luau
-- (no suffix); same shim as the sibling plugins.
local function import(name)
  local ok, mod = pcall(require, "./" .. name .. ".luau")
  if not ok then
    mod = require("./" .. name)
  end
  return mod
end

local policy = import("policy")

local PLUGIN_DIR = noctalia.pluginDir()
local DATA_DIR = noctalia.pluginDataDir()
local HELPER = PLUGIN_DIR .. "/face-watch"
local STATUS_PATH = DATA_DIR .. "/face-watch-status.json"
local LOG_PATH = DATA_DIR .. "/face-watch.log"

local STATE = { last_start_ms = nil }

local function log(line)
  noctalia.log("[inhibit-idle-while-watching] " .. line)
end

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
  return fallback
end

--- Is a check already running? The helper writes state="checking" while it
--- works and "idle" when done; anything else (absent, garbage) means no.
--- A "checking" state is trusted only while fresh: a crashed check must not
--- gate out every future run.
local function episode_running()
  local text = noctalia.readFile(STATUS_PATH)
  if text == nil or text == "" then return false end
  local ok, decoded = pcall(noctalia.json.decode, text)
  if not ok or type(decoded) ~= "table" then return false end
  if decoded.state ~= "checking" then return false end
  local updated = tonumber(decoded.updated_at)
  if updated == nil then return true end
  return (noctalia.nowMs() / 1000) - updated < 60
end

local function helper_argv()
  local argv = {
    "python3", HELPER, "gate",
    "--camera-path", setting_string("camera_path", ""),
    "--camera-mode", setting_string("camera_mode", "robust"),
    "--ir-threshold-lux", tostring(setting_number("ir_threshold_lux", 10)),
    "--detector", setting_string("detector", "haar"),
    "--sensitivity", tostring(setting_number("sensitivity", 5)),
    "--capture-width", tostring(setting_number("capture_width", 640)),
    "--status-file", STATUS_PATH,
  }
  -- The helper log is opt-in: it records camera/detector details and every
  -- verdict, which is more than a default install should persist.
  if setting_bool("debug_log", false) then
    argv[#argv + 1] = "--log-file"
    argv[#argv + 1] = LOG_PATH
  end
  return argv
end

-- ── IPC contract ────────────────────────────────────────────────────────────
--   idle-begin   the idle chain is about to act: run the presence gate
--   status       append the status file to the log ring (debug)
function onIpc(event, payload)
  if event == "idle-begin" then
    -- Fail closed (security review 2026-10-22): only an explicit `locked: false`
    -- may spawn; an unknown lock state (status failure, schema drift) refuses
    -- capture. The helper re-gates before every capture anyway.
    local locked = true
    noctalia.runAsync({ "noctalia", "msg", "status" }, function(result)
      if result ~= nil and result.exitCode == 0 then
        local ok, decoded = pcall(noctalia.json.decode, result.stdout or "")
        if ok and type(decoded) == "table" and decoded.locked == false then
          locked = false
        end
      end
      local ok, reason = policy.decide(STATE, {
        enabled = setting_bool("enabled", policy.DEFAULTS.enabled),
        cooldown_s = setting_number("cooldown_s", policy.DEFAULTS.cooldown_s),
      }, {
        locked = locked,
        episode_running = episode_running(),
        now_ms = noctalia.nowMs(),
      })
      if not ok then
        log("idle-begin skipped: " .. reason)
        return
      end
      -- Detached on purpose: the gate owns its process lifetime (capture and
      -- detector timeouts can stack to tens of seconds).
      noctalia.runAsync(helper_argv(), nil)
      log("gate started")
    end, 4000)
  elseif event == "status" then
    local text = noctalia.readFile(STATUS_PATH)
    log("status: " .. (text or "(none)"))
  end
end

function onConfigChanged()
  log("settings changed")
end

function onExit(signal, reason)
  -- Nothing to tear down: the gate is stateless and holds no inhibitors, so a
  -- crash or exit mid-check cannot leave the session pinned awake.
end
