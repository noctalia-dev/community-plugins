local published = {}
local toggled = {}

noctalia = {
  tr = function(key)
    return ({
      ["launcher.open"] = "Open Audio Switcher",
      ["launcher.description"] = "Switch the default audio input (microphone) or output.",
    })[key]
  end,
  string = {
    trim = function(value) return value:match("^%s*(.-)%s*$") end,
  },
  fuzzyScore = function(pattern, text)
    if text:lower():find(pattern:lower(), 1, true) then return 42 end
    return nil
  end,
  togglePanel = function(id) table.insert(toggled, id) end,
}

launcher = {
  setResults = function(query, results) published[query] = results end,
}

dofile("launcher.luau")

onQuery("")
assert(#published[""] == 1)
assert(published[""][1].id == "open-panel")
assert(published[""][1].score == 0)

onQuery("microphone")
assert(#published.microphone == 1)
assert(published.microphone[1].score == 42)

onQuery("wallpaper")
assert(#published.wallpaper == 0)

onActivate("ignored")
assert(#toggled == 0)

onActivate("open-panel")
assert(#toggled == 1)
assert(toggled[1] == "blackbartblues/audio-switcher:audio-switcher")

print("audio-switcher launcher tests: ok")
