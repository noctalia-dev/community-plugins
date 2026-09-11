-- Run with any Lua 5.x once installed:  lua tests/run.lua
-- Exercises config.luau (the pure patching module) against fixture text.
-- The plugin's Luau `require("./config.luau")` is a no-op here; we load the
-- module from source with the extension swapped.

local function loadModule(name)
  local script = arg and arg[0] or "run.lua"
  local path = script:gsub("tests/run%.lua$", "")
  if path == script then
    path = "./"
  end
  local file = assert(io.open(path .. name, "r"))
  local src = file:read("*a")
  file:close()
  -- strip the Luau attribute line; load the module body as a Lua chunk
  src = src:gsub("^%-%!%S+\n", "")
  return assert(load(src, name))()
end

local config = loadModule("config.luau")
local layout = loadModule("layout.luau")
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

-- trailing inline comments on the replaced line survive verbatim: the comment
-- must be re-attached with exactly one '#' (an earlier version added a second
-- one and grew it on every patch)
out = config.patchConfig(FIXTURE, "eDP-1", { mode = "800x600@60" })
local eModeLine = out:match('mode = "800x600@60"[^\n]*')
check("inline comment preserved verbatim", eModeLine == 'mode = "800x600@60" # WIDTHxHEIGHT')
check("no doubled comment", out:find("# #", 1, true) == nil)
check("commented vrr still untouched", out:find('#vrr = "fullscreen"') ~= nil)

-- regression: patching the same commented key repeatedly must not grow hashes
local repeated = config.patchConfig(FIXTURE, "eDP-1", { mode = "1280x720@60" })
repeated = config.patchConfig(repeated, "eDP-1", { mode = "800x600@60" })
repeated = config.patchConfig(repeated, "eDP-1", { mode = "1024x768@60" })
local repeatedLine = repeated:match('mode = "1024x768@60"[^\n]*')
local hashes = select(2, repeatedLine:gsub("#", "#"))
check("comment survives repeated patches", repeatedLine == 'mode = "1024x768@60" # WIDTHxHEIGHT')
check("comment hash count stays 1", hashes == 1)

-- the same for a commented position line
out = config.patchConfig(FIXTURE, "eDP-1", { x = 100, y = 200 })
local ePosLine = out:match("position = %[100, 200%][^\n]*")
check("position comment preserved verbatim", ePosLine == "position = [100, 200] # Logical top-left")

-- a '#' inside a quoted value is not a comment and must survive as a value
local quotedHash = "[output.DP-2]\nmode = \"custom#x\"\n"
out = config.patchConfig(quotedHash, "DP-2", { mode = "1024x768@60" })
check("hash inside quotes is not a comment", out:find('mode = "1024x768@60"', 1, true) ~= nil
  and out:find("custom#x", 1, true) == nil)

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

-- idempotence: patching with the same mode yields identical text, on a plain
-- key and on a comment-carrying one
local once = config.patchConfig(FIXTURE, "DP-1", { mode = "1280x720@60" })
local twice = config.patchConfig(once, "DP-1", { mode = "1280x720@60" })
check("idempotent", once == twice)

local cOnce = config.patchConfig(FIXTURE, "eDP-1", { mode = "1280x720@60" })
local cTwice = config.patchConfig(cOnce, "eDP-1", { mode = "1280x720@60" })
check("idempotent on commented key", cOnce == cTwice)

-- ── layout.luau: the arrangement map the panel draws ─────────────────────────

local function output(name, x, y, w, h, enabled, scale)
  return {
    name = name,
    enabled = enabled ~= false,
    position = { x = x, y = y },
    scale = scale or 1.0,
    modes = {
      { width = w, height = h, refresh_mhz = 143999, current = false },
      { width = w, height = h, refresh_mhz = 59940, current = true },
    },
  }
end

-- stacked: DP-1 above, eDP-1 below - the live setup on the target machine
local stacked = { output("DP-1", 0, -1440, 2560, 1440), output("eDP-1", 0, 0, 1920, 1080) }
local rects = layout.rects(stacked)
check("one rect per enabled output", #rects == 2)
check("logical size comes from the current mode", rects[1].w == 2560 and rects[1].h == 1440)
check("negative y kept", rects[1].y == -1440)
local minX, minY, maxX, maxY = layout.bounds(rects)
check("bounds cover the stack", minX == 0 and minY == -1440 and maxX == 2560 and maxY == 1080)

check("disabled outputs are not drawn", #layout.rects({ output("DP-1", 0, 0, 100, 100, false) }) == 0)
check("no usable mode, no rect", #layout.rects({ { name = "X", enabled = true, modes = {} } }) == 0)
check("scale divides the mode", (function()
  local scaled = layout.rects({ output("DP-1", 0, 0, 2560, 1440, true, 2.0) })[1]
  return scaled.w == 1280 and scaled.h == 720
end)())

local map = layout.map(rects, 400, 150)
check("stacked arrangement is two bands", #map.bands == 2)
check("upper band holds the monitor above", map.bands[1].items[1].name == "DP-1")
check("lower band holds the monitor below", map.bands[2].items[1].name == "eDP-1")
check("above draws smaller y than below", map.bands[1].items[1].y < map.bands[2].items[1].y)
check("map keeps the arrangement inside the canvas", (function()
  for _, item in ipairs(map.items) do
    if item.x < 0 or item.y < 0 or item.x + item.w > 400 or item.y + item.h > 150 then
      return false
    end
  end
  return true
end)())
check("aspect ratio preserved (height is the constraint)",
  math.abs(map.scale - math.min(400 / 2560, 150 / 2520)) < 1e-9)

-- side by side: one band, ordered left to right
local side = layout.rects({ output("DP-1", 0, 0, 2560, 1440), output("eDP-1", 2560, 0, 1920, 1080) })
local sideMap = layout.map(side, 400, 150)
check("side-by-side arrangement is one band", #sideMap.bands == 1)
check("items ordered left to right", sideMap.bands[1].items[1].name == "DP-1"
  and sideMap.bands[1].items[2].name == "eDP-1")
check("second monitor starts where the first ends",
  sideMap.bands[1].items[2].x >= sideMap.bands[1].items[1].x + sideMap.bands[1].items[1].w - 1)

-- a single monitor is centred, and a tiny one still gets a drawable box
local alone = layout.map(layout.rects({ output("eDP-1", 0, 0, 1920, 1080) }), 400, 150)
check("single monitor centred", math.abs(alone.items[1].x - (400 - alone.items[1].w) / 2) <= 1)
check("single monitor fills the height", alone.items[1].h == 150)
local tiny = layout.map(layout.rects({ output("TINY", 0, 0, 1920, 1080), output("MICRO", 1920, 0, 1, 1) }), 400, 150)
check("tiny monitor keeps a drawable box", tiny.items[2].w >= layout.MIN_PX and tiny.items[2].h >= layout.MIN_PX)
check("empty arrangement draws nothing", #layout.map({}, 400, 150).bands == 0)

-- the drawing plan: offsets that a flex layout turns back into absolute
-- positions. Every offset must be non-negative, and replaying them must land
-- each monitor exactly where the map put it.
local function replayPlan(plan)
  local ok = true
  local cursorY = 0
  for _, row in ipairs(plan.rows) do
    if row.offsetY < 0 then
      ok = false
    end
    cursorY = cursorY + row.offsetY
    local cursorX = 0
    for _, item in ipairs(row.items) do
      if item.offsetX < 0 or item.offsetY < 0 or item.offsetY + item.h > row.height then
        ok = false
      end
      cursorX = cursorX + item.offsetX
      if cursorX ~= item.x or cursorY + item.offsetY ~= item.y then
        ok = false
      end
      cursorX = cursorX + item.w
    end
    cursorY = cursorY + row.height
  end
  return ok, cursorY
end

local stackedPlan = layout.plan(map)
check("stacked plan replays to the map positions", replayPlan(stackedPlan))
check("stacked plan fills the canvas height", select(2, replayPlan(stackedPlan)) == 150)
check("one plan row per band", #stackedPlan.rows == #map.bands)
check("upper row starts at the canvas top", stackedPlan.rows[1].offsetY == 0)
check("lower row starts where the upper one ends", stackedPlan.rows[2].offsetY == 0)
-- the two live monitors sit at x = 0, so they must share a left edge: this is
-- the alignment the panel reproduces with a non-flexible spacer
check("stacked monitors at the same x share a left edge", map.items[1].x == map.items[2].x)

local sidePlan = layout.plan(sideMap)
check("side-by-side plan replays to the map positions", replayPlan(sidePlan))
check("side-by-side plan is one row", #sidePlan.rows == 1)
check("first monitor sits at the row start", sidePlan.rows[1].items[1].offsetX == sidePlan.rows[1].items[1].x)
check("second monitor offsets past the first", sidePlan.rows[1].items[2].offsetX == 0)

-- two monitors with empty space between them: the gap has to survive as a
-- spacer, otherwise the map would draw them edge to edge
local gapped = layout.rects({ output("A", 0, 0, 1000, 1000), output("B", 1500, 0, 1000, 1000) })
local gappedPlan = layout.plan(layout.map(gapped, 1000, 100))
check("a gap between monitors becomes a spacer", gappedPlan.rows[1].items[2].offsetX == 50)
check("gapped plan replays to the map positions", replayPlan(gappedPlan))

-- ── typed coordinates: only whole numbers ever reach the config ──────────────

check("coordinate accepts an integer", layout.coordinate("1440") == 1440)
check("coordinate accepts a signed integer", layout.coordinate("-1440") == -1440)
check("coordinate accepts an explicit plus", layout.coordinate("+15") == 15)
check("coordinate trims spaces", layout.coordinate("  -2560  ") == -2560)
check("coordinate accepts zero", layout.coordinate("0") == 0)
check("coordinate accepts a number from state", layout.coordinate(-2560) == -2560)
check("coordinate rejects empty", (select(1, layout.coordinate(""))) == nil)
check("coordinate rejects whitespace", (select(1, layout.coordinate("   "))) == nil)
check("coordinate rejects words", (select(1, layout.coordinate("left"))) == nil)
check("coordinate rejects fractions", (select(1, layout.coordinate("12.5"))) == nil)
check("coordinate rejects exponents", (select(1, layout.coordinate("1e3"))) == nil)
check("coordinate rejects trailing junk", (select(1, layout.coordinate("12px"))) == nil)
check("coordinate rejects out of range", (select(1, layout.coordinate("100001"))) == nil)
check("coordinate rejects a fractional number", (select(1, layout.coordinate(12.5))) == nil)
check("coordinate reasons are returned", (select(2, layout.coordinate("left"))) ~= nil)
check("coordinateText canonicalises a value", layout.coordinateText(15) == "15")
check("coordinateText normalises negative zero", layout.coordinateText("-0") == "0")
check("coordinateText falls back to 0", layout.coordinateText("nonsense") == "0")

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
