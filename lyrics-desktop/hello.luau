--!nonstrict
-- Minimal reference plugin entry: a bar widget that shows a configurable label
-- and glyph, counts clicks, and accepts IPC to change its text at runtime.
--
-- Demonstrates the capability surface:
--   barWidget.*          presentation (text / glyph / tooltip)
--   noctalia.getConfig   settings (seeded from the manifest; single-arg, no fallback)
--   noctalia.tr / trp    translation against this plugin's translations/<lang>.json
--   noctalia.readFile    filesystem, resolved relative to the plugin's own dir
--   noctalia.http        async HTTP (off-thread; response delivered back as a callback)
--   noctalia.state.*     shared data published by this plugin's [[service]] (ticker.luau)
--   noctalia.notify      host notification
--   onIpc                shell-triggered events
--
-- Drive it from the shell:
--   noctalia msg plugin noctalia/example:hello focused set "Hi there"
--   noctalia msg plugin noctalia/example:hello focused fetch "https://example.com"

local label = noctalia.getConfig("label")
local glyph = noctalia.getConfig("glyph")
local showGlyph = noctalia.getConfig("show_glyph")

local clicks = 0
local dataNote = noctalia.readFile("data.txt") or "(no data file)"
local tick = noctalia.state.get("tick") or 0

local function render()
  if showGlyph then
    barWidget.setGlyph(glyph)
  end
  barWidget.setText(label)
  barWidget.setTooltip(`{noctalia.trp("clicks", clicks)} - {dataNote} - service tick {tick}`)
end

-- Live updates from the plugin's background service (ticker.luau).
noctalia.state.watch("tick", function(value)
  tick = value
  render()
end)

-- Called on the widget's update interval. Static here, so slow the ticks right down.
function update()
  noctalia.setUpdateInterval(1000)
  render()
end

function onClick()
  clicks += 1
  noctalia.notify(noctalia.tr("title"), noctalia.trp("clicks", clicks))
  render()
end

function onIpc(event, payload)
  if event == "set" then
    label = payload
    render()
  elseif event == "fetch" then
    -- Async: the request runs off-thread and the callback fires when it lands.
    noctalia.http({ url = payload }, function(res)
      if res.ok then
        noctalia.notify(noctalia.tr("title"), `HTTP {res.status} - {#res.body} bytes`)
      else
        noctalia.notify(noctalia.tr("title"), "HTTP request failed")
      end
    end)
  end
end
