--!nonstrict
-- The running compositor's IPC module (lib/umbriel.luau or lib/niri.luau), or false.
--
-- Decided by the socket variable, in the order of Noctalia's own detection
-- (src/compositors/compositor_detect.cpp): only a running session of that compositor sets
-- it, while both CLIs may be installed side by side.

local function isSet(name)
  local value = noctalia.getenv(name)
  return value ~= nil and value ~= ""
end

if isSet("UMBRIEL_SOCKET") then
  return require("./umbriel.luau")
end
if isSet("NIRI_SOCKET") then
  return require("./niri.luau")
end
return false
