-- providers/capability.luau — environment detection + provider selection.
--
-- Phase 1 portability: being a Noctalia user must not require being a
-- Hyprland user. This module detects the running compositor from the
-- session's environment (the same variables the compositors themselves set:
-- HYPRLAND_INSTANCE_SIGNATURE, NIRI_SOCKET, SWAYSOCK), verifies that the
-- selected provider's required executable actually exists, and picks the
-- provider — falling back to a no-op, dependency-free provider that reports
-- "unavailable" instead of pretending to track.
--
-- Detection is evidence-based, in two steps (§1 of the portability brief):
--   1. environment: a compositor sets its own session variables; presence is
--      a cheap, unambiguous first signal (NIRI_SOCKET/SWAYSOCK are literal
--      socket paths set by the processes themselves).
--   2. verification: the environment variable alone proves which compositor
--      runs, not that THIS plugin can query it — the provider's required
--      command is checked with noctalia.commandExists() before selection, so
--      a Hyprland session without a usable hyprctl degrades the same way an
--      unsupported compositor does (undercount, never fabricate).
--
-- Phase 1 deliberately knows exactly one concrete provider (hyprland). Niri
-- and Sway are follow-up phases: their sockets are recognized here, but with
-- no provider implemented for them the plugin degrades to the fallback and
-- says so — honest, not broken.
--
-- The fallback provider has the same interface as every real provider:
--   newProvider(opts) -> { name, available, idleAfterSeconds,
--                          activeWindow(cb), start(onEvent), stop() }
-- It spawns nothing, polls nothing and never fabricates activity: the
-- tracker only ever sees nil samples, so history is untouched and no
-- unobserved time is credited to anyone.

local M = {}

-- ── detection ────────────────────────────────────────────────────────────────

-- detect(getenv, commandExists) -> "hyprland" | "niri" | "sway" | "none"
--
-- Pure decision over injected host functions (unit-testable). getenv is the
-- noctalia.getenv signature (name -> value | nil); commandExists mirrors
-- noctalia.commandExists. Neither is stored: detection is a pure function of
-- the environment at call time.
--
-- Order matters only for exotic setups where two variables leak into one
-- session (nested shells): Hyprland first — the phase-1 reference provider —
-- then the recognized-but-unimplemented ones. Sway and Niri sockets are only
-- reported when their compositor actually runs; nothing else maps to them.
function M.detect(getenv, commandExists)
  getenv = getenv or function() return nil end
  commandExists = commandExists or function() return false end

  if getenv("HYPRLAND_INSTANCE_SIGNATURE") ~= nil then
    -- hyprctl is the provider's only channel to the compositor; without it
    -- the provider cannot answer a single poll, so the environment is not
    -- usable even though Hyprland itself runs.
    if commandExists("hyprctl") then
      return "hyprland"
    end
    return "none"
  end
  -- Recognized, deliberately NOT implemented in phase 1: they select the
  -- fallback rather than a provider that cannot exist yet.
  if getenv("NIRI_SOCKET") ~= nil then
    return "niri"
  end
  if getenv("SWAYSOCK") ~= nil then
    return "sway"
  end
  return "none"
end

-- ── selection ────────────────────────────────────────────────────────────────

-- newSelector(opts) -> select(opts2) -> provider
--
-- opts.resolve(name) -> provider | nil maps a detected name to a concrete
-- provider module (injected so tests can substitute fakes; production wires
-- only "hyprland" -> providers/hyprland.luau). opts.getenv / opts.commandExists
-- override the host functions for tests. Everything falls back to the
-- built-in fallback provider — selection can never fail into a crash.
function M.newSelector(opts)
  opts = opts or {}
  local getenv = opts.getenv
    or (type(noctalia) == "table" and type(noctalia.getenv) == "function" and noctalia.getenv)
    or function() return nil end
  local commandExists = opts.commandExists
    or (type(noctalia) == "table" and type(noctalia.commandExists) == "function" and noctalia.commandExists)
    or function() return false end
  local resolve = opts.resolve or function() return nil end
  local log = opts.log
    or (type(noctalia) == "table" and type(noctalia.log) == "function" and noctalia.log)
    or function() end

  return {
    select = function(selectOpts)
      selectOpts = selectOpts or {}
      local detected = M.detect(getenv, commandExists)
      local provider = resolve(detected)

      if provider == nil then
        if detected == "hyprland" then
          -- Hyprland runs but its provider module failed to load (host quirk,
          -- broken install): degrade instead of crashing the service entry.
          log("what-did-i-do: hyprland detected but its provider is unavailable; tracking disabled")
        elseif detected == "none" then
          log("what-did-i-do: no supported compositor detected; tracking unavailable (history stays accessible)")
        else
          log("what-did-i-do: " .. detected .. " detected; provider not implemented yet, tracking unavailable")
        end
        return M.newFallbackProvider(selectOpts), detected
      end

      log("what-did-i-do: compositor '" .. detected .. "' -> provider '" .. tostring(provider.name) .. "'")
      return provider, detected
    end,
  }
end

-- ── fallback provider ────────────────────────────────────────────────────────

-- newFallbackProvider(opts) -> provider (interface-compatible, zero side effects)
--
-- available = false is the honest signal consumed by the service and the UI.
-- activeWindow always reports "no trackable application" (cb(nil)) — exactly
-- what the real provider reports for layer-shell/no-focus moments, so the
-- tracker's existing "unknown state closes the session, nothing is credited"
-- path handles it with no tracker changes.
function M.newFallbackProvider(opts)
  opts = opts or {}
  local self = {
    name = "none",
    available = false,
    idleAfterSeconds = opts.idleAfterSeconds or 120,
  }

  function self.activeWindow(cb)
    if type(cb) == "function" then
      cb(nil)
    end
  end

  function self.start(_onEvent)
    -- No-op by design: no subprocesses, no streams, no state that could
    -- leak. There is nothing to clean up because nothing was created.
  end

  function self.stop()
  end

  return self
end

return M
