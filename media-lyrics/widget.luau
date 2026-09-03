--!nonstrict
-- Bar widget: compact now-playing indicator; click opens the lyrics panel.
--
-- Reads the snapshot published by the service (noctalia.state "media") and
-- renders glyph + truncated title. Left click toggles the panel, middle click
-- toggles play/pause, scroll switches tracks.

local glyphPlay = "player-play"
local glyphPause = "player-pause"

-- Which panel preset to open: the plugin setting panel_size selects among
-- compact (440), medium (520, default) and large (640) presets declared in
-- plugin.toml. Medium keeps the historical `panel` id for IPC compatibility.
local function panelIdForSize()
  local sz = noctalia.getConfig("panel_size")
  if sz == "compact" then return "panel-compact" end
  if sz == "large" then return "panel-large" end
  return "panel"
end

local TITLE_MAX = 26

-- UTF-8 helpers: a byte >= 0xC0 starts a character (2–4 bytes), a byte in
-- 0x80..0xBF is a continuation. charCount walks whole characters so titles
-- in any script truncate on char boundaries, never mid-sequence.
local function charCount(s)
  local i, n = 1, 0
  while i <= #s do
    local b = s:byte(i)
    if b >= 0xF0 then i = i + 4
    elseif b >= 0xE0 then i = i + 3
    elseif b >= 0xC0 then i = i + 2
    else i = i + 1 end
    n = n + 1
  end
  return n
end

local function charPrefix(s, maxChars)
  local i, n = 1, 0
  while i <= #s and n < maxChars do
    local b = s:byte(i)
    if b >= 0xF0 then i = i + 4
    elseif b >= 0xE0 then i = i + 3
    elseif b >= 0xC0 then i = i + 2
    else i = i + 1 end
    n = n + 1
  end
  return s:sub(1, i - 1)
end

local function truncate(s)
  s = tostring(s or "")
  if charCount(s) <= TITLE_MAX then return s end
  return charPrefix(s, TITLE_MAX - 1) .. "…"
end

local function media()
  local ok, v = pcall(function() return noctalia.state.get("media") end)
  if ok and type(v) == "table" then return v end
  return nil
end

local function renderFrom(m)
  if not m or not m.hasPlayer then
    -- Empty state is ALSO a render() tree: the host warns that
    -- setGlyph/setText have no visible effect once a render() tree is
    -- active (verified live), so a plain disc glyph is rendered instead.
    -- No explicit color roles — the widget instance's Color/Icon Color
    -- settings apply.
    barWidget.render(ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "disc", size = 14 }),
    }))
    return
  end
  local g = m.playing and glyphPause or glyphPlay
  local title = truncate(m.title ~= "" and m.title or noctalia.tr("common.no-title"))
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
  noctalia.togglePanel("tranzem/media-lyrics:" .. panelIdForSize())
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