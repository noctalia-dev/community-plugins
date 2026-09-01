--!nonstrict
-- Bar widget: compact now-playing indicator; click opens the lyrics panel.
--
-- Reads the snapshot published by the service (noctalia.state "media") and
-- renders glyph + truncated title. Left click toggles the panel, middle click
-- toggles play/pause, scroll switches tracks.

local glyphPlay = "player-play"
local glyphPause = "player-pause"

local TITLE_MAX = 26

local function truncate(s)
  s = tostring(s or "")
  if #s <= TITLE_MAX then return s end
  return s:sub(1, TITLE_MAX - 1) .. "…"
end

local function media()
  local ok, v = pcall(function() return noctalia.state.get("media") end)
  if ok and type(v) == "table" then return v end
  return nil
end

local function renderFrom(m)
  if not m or not m.hasPlayer then
    barWidget.setGlyph("disc")
    barWidget.setText("")
    return
  end
  local g = m.playing and glyphPause or glyphPlay
  local title = truncate(m.title ~= "" and m.title or "No title")
  -- No explicit color roles: the host applies the widget instance's Color /
  -- Icon Color settings (Default = theme role). Explicit roles here would
  -- silently ignore the user's per-widget color configuration.
  barWidget.render(ui.row({ gap = 6, align = "center" }, {
    ui.glyph({ name = g, size = 14 }),
    ui.label({ text = title, fontSize = 12 }),
  }))
end

function update()
  renderFrom(media())
end

noctalia.state.watch("media", function(value)
  renderFrom(value)
end)

noctalia.setUpdateInterval(2000)

function onClick()
  noctalia.togglePanel("tranzem/media-lyrics:panel")
end

function onMiddleClick()
  noctalia.state.set("panel_cmd", { action = "toggle" })
end

-- scroll up = next, down = previous (mirrors the built-in media widget)
function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" or startsGesture then return end
  local dir = (steps or 0) > 0 and "next" or "prev"
  noctalia.state.set("panel_cmd", { action = dir })
end