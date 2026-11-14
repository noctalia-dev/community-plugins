-- Regression tests for lib/state.luau, runnable with Lua 5.4.
--
-- Usage: lua5.4 bin/test-state.lua lib/state.luau

local statePath = arg[1] or "lib/state.luau"

local checks = 0
local failures = 0

local function check(condition, message)
  checks = checks + 1
  if not condition then
    failures = failures + 1
    io.stderr:write("FAIL: " .. message .. "\n")
  end
end

local function eq(current, expected, message)
  check(
    current == expected,
    string.format("%s (got %s, expected %s)", message, tostring(current), tostring(expected))
  )
end

local state = dofile(statePath)

-- Settings ----------------------------------------------------------------

local asked = {}
local host = {
  getConfig = function(key)
    asked[#asked + 1] = key
    if key == "font_size" then
      return 22
    elseif key == "marker" then
      return true
    end
    return nil
  end,
}

local values = state.read(host)
eq(values.font_size, 22, "state: the setting is read")
eq(values.marker, true, "state: a boolean setting is kept")
eq(#asked, #state.SETTING_KEYS, "state: every declared key is read once")
eq(asked[1], "font_size", "state: the keys keep their order")

-- Position ----------------------------------------------------------------

eq(state.position(nil, 5000), 0, "state: without a track the position is zero")
eq(
  state.position({ positionMs = 1500, positionAtMs = 5000, playing = true }, 7000),
  3.5,
  "state: a playing track moves forward"
)
eq(
  state.position({ positionMs = 1500, positionAtMs = 5000, playing = false }, 7000),
  1.5,
  "state: a paused track stays put"
)
eq(
  state.position({ positionMs = 1500, playing = true }, 7000),
  1.5,
  "state: without the read moment it stays put"
)
eq(
  state.position({ positionMs = 5000, positionAtMs = 9000, playing = true }, 7000),
  5,
  "state: a clock that goes backwards does not rewind the lyric"
)

-- States ------------------------------------------------------------------

eq(state.stateOf(nil, nil, true), "idle", "state: no track is idle even while loading")
eq(state.stateOf({}, { lines = {} }, false), "lyrics", "state: lyrics win over any flag")
eq(state.stateOf({}, nil, true), "loading", "state: without lyrics it may be loading")
eq(state.stateOf({}, nil, false), "empty", "state: without lyrics and not loading it is empty")

-- The per-track break ------------------------------------------------------

local cfg = { karaoke = true, font_size = 22 }
eq(state.karaoke(cfg, true), cfg, "state: with the break on, the settings are reused")
eq(state.karaoke(cfg, nil), cfg, "state: a missing flag counts as on")
local broken = state.karaoke(cfg, false)
eq(broken.karaoke, false, "state: the break turns the fill off")
eq(cfg.karaoke, true, "state: the caller settings are not mutated")
eq(broken.font_size, 22, "state: the other settings survive the break")
eq(state.karaoke({ karaoke = false }, false).karaoke, false, "state: an off setting stays off")

-- Labels ------------------------------------------------------------------

eq(state.label(nil), "", "state: no track has no label")
eq(state.label({ title = "Song" }), "Song", "state: a track without artist shows the title")
eq(state.label({ title = "Song", artist = "Band" }), "Song — Band", "state: the label joins both")
eq(state.label({ title = "", artist = "Band" }), "Band", "state: an empty title keeps the artist")

eq(state.tooltip(nil, function(key) return key end), "nothing_playing", "state: idle tooltip")
eq(state.tooltip({ title = "Song" }, function(key) return key end), "Song", "state: playing tooltip")

-- Result ------------------------------------------------------------------

if failures > 0 then
  io.stderr:write(string.format("%d of %d checks failed\n", failures, checks))
  os.exit(1)
end
print(string.format("%d checks passed", checks))
