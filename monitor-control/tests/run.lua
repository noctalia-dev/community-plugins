-- Run with any Lua 5.x once installed:  lua tests/run.lua
-- Exercises config.luau (the pure patching module) against fixture text.
-- The plugin's Luau `require("./config.luau")` is a no-op here; we load the
-- module from source with the extension swapped.

local function loadModule()
  local path = (arg and arg[0] or "run.lua"):gsub("tests/run%.lua$", "")
  if path == (arg and arg[0] or "run.lua") then
    path = "./"
  end
  local file = assert(io.open(path .. "config.luau", "r"))
  local src = file:read("*a")
  file:close()
  -- strip the Luau attribute line; load the module body as a Lua chunk
  src = src:gsub("^%-%!%S+\n", "")
  return assert(load(src, "config.luau"))()
end

local config = loadModule()
local passed, failed = 0, 0

local function check(name, cond)
  if cond then
    passed = passed + 1
    print("ok    " .. name)
  else
    failed = failed + 1
    print("FAIL  " .. name)
  end
end

local FIXTURE = table.concat({
  "[general]",
  'mod_key = "Super"',
  "",
  "[output.eDP-1]",
  "enabled = true",
  'mode = "1920x1080@120"                        # WIDTHxHEIGHT',
  "position = [0, 0]                             # Logical top-left",
  "scale = 1.0",
  "",
  "[output.DP-1]",
  "enabled = true                                # False removes the output",
  'mode = "2560x1440@144"',
  "position = [-2560, 0]",
  "scale = 1.0",
  "#vrr = \"fullscreen\"",
  "",
  "[output.DP-1.layout.scrolling]",
  "default_width_fraction = 0.4",
  "",
  '[output."AOC CQ32G4 0x1F"]',
  'mode = "1920x1080@60"',
  "",
  "[layout.master]",
  'position = "left"',
  "",
}, "\n")

-- mode replacement keeps comments and touches only the target section
local out = config.patchConfig(FIXTURE, "DP-1", { mode = "1920x1080@120" })
check("mode replaced", out:find('mode = "1920x1080@120"', 1, true) ~= nil)
check("old mode gone from DP-1", out:find('mode = "2560x1440@144"') == nil)
local hits = 0
for _ in out:gmatch('mode = "1920x1080@120"') do hits = hits + 1 end
check("both eDP-1 and DP-1 now hold 120@1080", hits == 2)
check("layout.master position untouched", out:find('position = "left"') ~= nil)
check("trailing comment survives", out:find("# WIDTHxHEIGHT") ~= nil)
check("commented vrr untouched", out:find('#vrr = "fullscreen"') ~= nil)

-- position replacement lands inside the right section, not a later one
out = config.patchConfig(FIXTURE, "DP-1", { x = 1920, y = 0 })
local dpBlock = out:match("%[output%.DP%-1%](.-)%[output%.DP%-1%.")
check("position in DP-1", dpBlock ~= nil and dpBlock:find("position = %[1920, 0%]") ~= nil)
check("no stray position at EOF", not out:sub(-80):find("1920, 0"))

-- stop boundary: the nested [output.DP-1.layout.scrolling] header ends the
-- base section, so keys must not be appended below it; and exactly one
-- position line may be injected.
out = config.patchConfig(FIXTURE, "DP-1", { x = 5, y = 6 })
local injected = "position = %[5, 6%]"
local occurrences = 0
for _ in out:gmatch(injected) do occurrences = occurrences + 1 end
local at = out:find(injected)
local nested = out:find("%[output%.DP%-1%.layout%.scrolling%]")
check("append stays inside section", at ~= nil and nested ~= nil and at < nested)
check("exactly one position injected", occurrences == 1)

-- trailing inline comments on the replaced line survive
out = config.patchConfig(FIXTURE, "eDP-1", { mode = "800x600@60" })
local modeAt = out:find('mode = "800x600@60"')
local commentAt = out:find("# WIDTHxHEIGHT")
check("inline comment preserved", modeAt ~= nil and commentAt ~= nil and modeAt < commentAt)
check("commented vrr still untouched", out:find('#vrr = "fullscreen"') ~= nil)

-- quoted monitor-name header, case-insensitive like Umbriel
out = config.patchConfig(FIXTURE, "aoc cq32g4 0x1f", { mode = "640x480@60" })
check("quoted header matched", out:find('mode = "640x480@60"', 1, true) ~= nil)

-- missing section is appended as a fresh [output.X] at end of file
out = config.patchConfig(FIXTURE, "HDMI-A-1", { mode = "3840x2160@60" })
check("fresh section appended", out:find("%[output%.HDMI%-A%-1%]%s*mode = \"3840x2160@60\"") ~= nil)

-- hzText: snap-to-int and fraction formats
check("hz 143999 -> 144", config.hzText(143999) == "144")
check("hz 120213 -> 120.21", config.hzText(120213) == "120.21")
check("hz 59940 -> 59.94", config.hzText(59940) == "59.94")
check("hz 60000 -> 60", config.hzText(60000) == "60")

-- empty name rejected before touching text
local bad, reason = config.patchConfig(FIXTURE, "", { mode = "x" })
check("empty name rejected", bad == nil and reason ~= nil)

-- idempotence: patching with the same mode yields identical text
local once = config.patchConfig(FIXTURE, "DP-1", { mode = "1280x720@60" })
local twice = config.patchConfig(once, "DP-1", { mode = "1280x720@60" })
check("idempotent", once == twice)

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
