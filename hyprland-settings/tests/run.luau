-- luau tests/run.luau
local catalog = require("../lib/catalog")
local writer = require("../lib/writer")
local monitors = require("../lib/monitors")
local hyprctl = require("../lib/hyprctl")
local futurista = require("../lib/presets/futurista")
local decode = require("./json")
local sample = require("./sample_state")
local draftlib = require("../lib/draft")

local failures = 0
local function check(name, condition)
  if condition then
    print("ok   " .. name)
  else
    print("FAIL " .. name)
    failures += 1
  end
end
local function has(text, needle) return text ~= nil and text:find(needle, 1, true) ~= nil end

-- catalog + reading: every option is known to Hyprland 0.56
local values = hyprctl.parseRead(catalog, require("./fixtures/getoption_batch"), decode)
local missing = {}
for _, option in ipairs(catalog.options) do
  if values[option.path] == nil then table.insert(missing, option.path) end
end
check("every catalog option reads back (" .. #catalog.options .. ")", #missing == 0)
if #missing > 0 then print("     missing: " .. table.concat(missing, ", ")) end
check("kb_layout is the real value, not descriptions' 'us'", values["input.kb_layout"] == "de")
check("gaps_out collapses equal sides", values["general.gaps_out"] == 20)
check("float option", values["decoration.active_opacity"] == 1)
check("bool option", values["decoration.blur.enabled"] == true)
check("argv is one hyprctl call", #hyprctl.readArgv(catalog) == 3)
local seen = {}
local unique = true
for _, option in ipairs(catalog.options) do
  if seen[option.path] then unique = false end
  seen[option.path] = true
end
check("paths are unique", unique)

-- writer
local presets = { futurista = futurista }
local text, err = writer.render(sample, catalog, presets)
check("sample renders", text ~= nil)
if text == nil then print("     " .. tostring(err)) end
check("nested config", has(text, "    general = {\n        gaps_in = 5,"))
check("why comment above value", has(text, "            -- why: size times passes is the GPU cost on the iGPU\n            size = 4,"))
check("float literal", writer.literal(catalog.byPath["decoration.rounding_power"], 2.5) == "2.5")
check("string literal", has(text, 'kb_layout = "de",'))
check("monitor by desc", has(text, 'output   = "desc:AOC 24G1WG4",'))
check("monitor scale 1.6", has(text, "scale    = 1.6,"))
check("curves before animations", (text :: string):find("hl.curve", 1, true) < (text :: string):find("hl.animation", 1, true))
check("namespaced curve", has(text, 'hl.curve("hs_holo"'))
check("disabled leaf kept", has(text, 'hl.animation({ leaf = "fadeIn", enabled = false })'))

local asym = writer.literal(catalog.byPath["general.gaps_out"], { top = 10, right = 20, bottom = 10, left = 20 })
check("asymmetric gaps stay four sides", asym == "{ top = 10, right = 20, bottom = 10, left = 20 }")
check("equal gap sides collapse", writer.literal(catalog.byPath["general.gaps_out"], { top = 5, right = 5, bottom = 5, left = 5 }) == "5")

local evil = writer.render({ options = { ["general.border_size"] = { value = 2, why = 'x\nos.execute("rm -rf ~")\r\n' } } }, catalog, presets)
check("newline in why cannot become code", evil ~= nil and not has(evil, "\nos.execute") and has(evil, '-- why: x os.execute("rm -rf ~")'))
check("string escaping", writer.literal(catalog.byPath["input.kb_options"], 'a"b\\c\nd') == '"a\\"b\\\\c\\nd"')

local function rejects(state) return writer.render(state, catalog, presets) == nil end
check("rejects out of range", rejects({ options = { ["general.border_size"] = { value = 99 } } }))
check("rejects non-integer int", rejects({ options = { ["general.border_size"] = { value = 2.5 } } }))
check("rejects NaN", rejects({ options = { ["decoration.active_opacity"] = { value = 0 / 0 } } }))
check("rejects wrong type", rejects({ options = { ["decoration.blur.enabled"] = { value = "yes" } } }))
check("rejects unknown choice", rejects({ options = { ["general.layout"] = { value = "spiral" } } }))
check("rejects unknown option", rejects({ options = { ["general.nope"] = { value = 1 } } }))
check("rejects unknown preset", rejects({ preset = { name = "nope" } }))
check("rejects zero scale", rejects({ monitors = { { output = "eDP-1", mode = "preferred", position = "0x0", scale = 0 } } }))
check("empty state is a valid header-only file", writer.render({}, catalog, presets) ~= nil)

-- monitors
local connected = decode(require("./fixtures/monitors"))
local laptop, aoc = connected[1], connected[2]
local lw, lh = monitors.logicalSize("2560x1440@60", 1.6, 0)
check("laptop at 1.6 is 1600x900", lw == 1600 and lh == 900)
local rw, rh = monitors.logicalSize("1920x1080@144", 1, 1)
check("90 degrees swaps axes", rw == 1080 and rh == 1920)
check("scale must give whole pixels", monitors.logicalSize("2560x1440@60", 1.7, 0) == nil)
check("scale must be positive", monitors.logicalSize("2560x1440@60", -1, 0) == nil)

local positions = monitors.layout({
  { mode = "2560x1440@60", scale = 1.6 },
  { mode = "1920x1080@144", scale = 1 },
})
check("AOC lands at x=1600", positions ~= nil and positions[1] == "0x0" and positions[2] == "1600x0")
local skip = monitors.layout({
  { mode = "1920x1080@144", scale = 1, disabled = true },
  { mode = "2560x1440@60", scale = 1.6 },
})
check("disabled screen takes no space", skip ~= nil and skip[1] == nil and skip[2] == "0x0")

check("rule by full description", monitors.ruleOutput(aoc, connected) == "desc:AOC 24G1WG4 0x00000000")
local twins = { { name = "DP-1", description = "Same" }, { name = "DP-2", description = "Same" } }
check("duplicate description falls back to connector", monitors.ruleOutput(twins[1], twins) == "DP-1")
check("empty description falls back to connector", monitors.ruleOutput({ name = "X", description = "" }, { }) == "X")
check("old short desc rule still matches", monitors.matches("desc:AOC 24G1WG4", aoc))
check("TV rule does not match AOC", not monitors.matches("desc:United Microelectr Corporation UMC SHARP", aoc))

check("current rules are valid", (monitors.validate(sample.monitors, connected)))
local off = {
  { output = "eDP-1", mode = "preferred", position = "0x0", scale = 1.6, disabled = true },
  { output = "desc:AOC 24G1WG4", mode = "1920x1080@144", position = "1600x0", scale = 1, disabled = true },
}
check("last screen cannot be switched off", not monitors.validate(off, connected))
local bad = { { output = "desc:AOC 24G1WG4", mode = "1920x1080@75", position = "1600x0", scale = 1 } }
check("unsupported mode is refused", not monitors.validate(bad, connected))
local later = {
  { output = "desc:AOC 24G1WG4", mode = "1920x1080@144", position = "1600x0", scale = 1 },
  { output = "HDMI-A-1", mode = "1920x1080@60", position = "1600x0", scale = 1, disabled = true },
}
check("later rule wins, like in Hyprland", monitors.ruleFor(later, aoc) == later[2])
check("laptop still counts as on", (monitors.validate(later, connected)))
check("laptop fixture present", laptop.name == "eDP-1")

-- exact numbers, monitor rule shape, mode keywords
check("tiny float keeps its value", tonumber(writer.literal(catalog.byPath["decoration.dim_strength"], 0.00001)) == 0.00001)
check("float text reads back exactly", tonumber(writer.literal(catalog.byPath["decoration.dim_strength"], 0.1696)) == 0.1696)
check("writer rejects transform 99", rejects({ monitors = { { output = "eDP-1", mode = "preferred", position = "0x0", scale = 1, transform = 99 } } }))
check("rule: garbage position", not monitors.checkRule({ output = "eDP-1", mode = "preferred", position = "garbage", scale = 1 }))
check("rule: empty desc", not monitors.checkRule({ output = "desc:", mode = "preferred", position = "0x0", scale = 1 }))
check("rule: mode text", not monitors.checkRule({ output = "eDP-1", mode = "fast", position = "0x0", scale = 1 }))
check("rule: auto position ok", (monitors.checkRule({ output = "eDP-1", mode = "highrr", position = "auto-right", scale = 1 })))
check("preferred resolves to the first mode", monitors.resolveMode("preferred", aoc) == "1920x1080@60.00")
check("highrr picks 144", monitors.resolveMode("highrr", aoc) == "1920x1080@144.00")
check("an unknown concrete mode does not resolve", monitors.resolveMode("1920x1080@75", aoc) == nil)

check("revision marker for the reload proof", has(writer.render({}, catalog, presets, "1791362658276"), 'HYPRLAND_SETTINGS_REVISION = "1791362658276"'))
check("revision must be a plain id", writer.render({}, catalog, presets, 'x"; os.exit()') == nil)
check("rule: half a mode", not monitors.checkRule({ output = "eDP-1", mode = "1920x1080@1..", position = "0x0", scale = 1 }))
check("rule: autogarbage", not monitors.checkRule({ output = "eDP-1", mode = "preferred", position = "autogarbage", scale = 1 }))
local kw = monitors.layout({ { mode = "preferred", scale = 1.6, monitor = laptop }, { mode = "highrr", scale = 1, monitor = aoc } })
check("layout resolves mode keywords", kw ~= nil and kw[2] == "1600x0")

-- draft (panel logic)
local live = { values = values, monitors = connected }
local d = draftlib.copy(sample)
check("draft value comes from the draft", draftlib.value(d, live, "general.border_size") == 2)
check("unmanaged value comes from Hyprland", draftlib.value(d, live, "input.repeat_rate") == values["input.repeat_rate"])
draftlib.setOption(d, "decoration.blur.size", 6)
check("setOption keeps the reason", d.options["decoration.blur.size"].why ~= nil and d.options["decoration.blur.size"].value == 6)
check("draft differs from saved after a change", not draftlib.equal(d, sample))
local r = draftlib.copy(sample)
draftlib.setOption(r, "general.border_size", 5)
draftlib.revertOption(r, sample, "general.border_size")
check("undo restores the saved entry", draftlib.equal(r, sample))
draftlib.setOption(r, "input.repeat_rate", 30)
draftlib.revertOption(r, sample, "input.repeat_rate")
check("undo of a new entry unmanages it", r.options["input.repeat_rate"] == nil)
draftlib.unmanage(d, "decoration.blur.size")
check("unmanage removes the entry", d.options["decoration.blur.size"] == nil)
check("snap to step and range", draftlib.snap(catalog.byPath["decoration.active_opacity"], "0.873") == 0.87
  and draftlib.snap(catalog.byPath["general.border_size"], "99") == 20)

local rows = draftlib.monitorRows(monitors, { monitors = {} }, live)
check("rows from live, left to right", #rows == 2 and rows[1].monitor.name == "eDP-1" and not rows[1].managed)
check("live rule of the AOC", rows[2].rule.output == "desc:AOC 24G1WG4 0x00000000" and rows[2].rule.mode == "1920x1080@144.00")
check("current setup is a row", draftlib.isRow(rows))
local e = { monitors = draftlib.copy(sample.monitors) }
check("AOC to 60 Hz keeps the row", draftlib.changeMonitor(monitors, e, live, "HDMI-A-1", { mode = "1920x1080@60.00" }))
local aocRule = monitors.ruleFor(e.monitors, aoc)
check("rule updated in place (desc rule)", aocRule.mode == "1920x1080@60.00" and aocRule.output == "desc:AOC 24G1WG4")
check("TV rule kept", #draftlib.offlineRules(monitors, e, live) == 1)
check("move AOC left", draftlib.changeMonitor(monitors, e, live, "HDMI-A-1", { move = -1 }))
check("AOC at 0, laptop at 1920", monitors.ruleFor(e.monitors, aoc).position == "0x0" and monitors.ruleFor(e.monitors, laptop).position == "1920x0")
check("laptop scale 2 shifts nothing left of it", draftlib.changeMonitor(monitors, e, live, "eDP-1", { scale = 2 })
  and monitors.ruleFor(e.monitors, laptop).position == "1920x0")
check("disable AOC moves laptop to 0", draftlib.changeMonitor(monitors, e, live, "HDMI-A-1", { disabled = true })
  and monitors.ruleFor(e.monitors, laptop).position == "0x0")
check("cannot move a disabled screen", draftlib.changeMonitor(monitors, e, live, "HDMI-A-1", { move = 1 }) == nil)
check("result still validates", (monitors.validate(e.monitors, connected)))
local sc = draftlib.scales(monitors, "2560x1440@60", 1.6)
check("valid scales include 1, 1.25, 1.6, 2", table.find(sc, 1) and table.find(sc, 1.25) and table.find(sc, 1.6) and table.find(sc, 2))
check("no invalid scale offered", not table.find(sc, 1.7))

print(failures .. " failure(s)")
if failures > 0 then error("tests failed") end
