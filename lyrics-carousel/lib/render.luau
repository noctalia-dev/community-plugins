--!nonstrict
-- Declarative carousel: the visible lines of a lyric, as a `ui.*` tree.
--
-- Pure Lua. The caller injects everything that is not a table: `ui` (the
-- host's control table), `model` (lib/lyrics.luau), `tr` and an optional
-- `color(role)` that resolves palette roles to hex. That is what makes
-- bin/test-render.lua able to build the tree without Noctalia.
--
-- Two entry points:
--   M.carousel(opts)  the lines only (what scrolls)
--   M.surface(opts)   carousel + header/footer, or the bar widget row, or
--                     the "nothing playing" block.

local M = {}

-- Instrumental placeholder, in the order of the `instrumental_icon` setting.
M.ICONS = { "\u{266A}", "\u{266B}", "\u{266C}", "\u{2669}" }

-- Markers, in the order of the `marker_style` setting. Text, not vector art:
-- they must work with any font the user picks.
M.MARKERS = { "\u{203A}", "\u{2022}", "|", "\u{266A}", "\u{00BB}", "\u{2014}" }

-- Longest line split into one label per character. A 300 character line would
-- mean 300 labels per frame to gain nothing: the host elides it anyway.
M.MAX_KARAOKE_CHARS = 160

-- The accent setting offers the palette roles that exist in every theme, plus
-- a custom colour. Roles stay live: the host resolves them on every repaint.
local ACCENT_ROLES = {
  primary = "primary",
  secondary = "secondary",
  tertiary = "tertiary",
  error = "error",
}

local function clamp(value, low, high)
  if value < low then
    return low
  elseif value > high then
    return high
  end
  return value
end

local function pick(list, index, fallback)
  local count = #list
  if count == 0 then
    return fallback
  end
  local position = math.floor(tonumber(index) or 0) % count
  return list[position + 1] or fallback
end

local function trOf(opts)
  return opts.tr or function(key)
    return key
  end
end

--- Seconds as `m:ss`.
function M.clock(seconds)
  local total = math.max(0, math.floor(tonumber(seconds) or 0))
  return string.format("%d:%02d", math.floor(total / 60), total % 60)
end

--- Colour of the sung text: the custom hex, or the palette role.
--
-- `color` is Noctalia's `getColor`; when it is absent (tests, or a host
-- without the API) the role token itself is returned, which `ui.label`
-- already understands.
function M.accentColor(cfg, color)
  cfg = cfg or {}
  if cfg.accent == "custom" then
    local custom = cfg.custom_color
    if type(custom) == "string" and custom ~= "" then
      return custom
    end
  end
  local role = ACCENT_ROLES[cfg.accent] or "primary"
  if color ~= nil then
    local hex = color(role)
    if type(hex) == "string" and hex ~= "" then
      return hex
    end
  end
  return role
end

--- Message of a surface with no lyrics to show.
function M.stateText(state, tr)
  if state == "loading" then
    return tr("searching_lyrics")
  elseif state == "empty" then
    return tr("no_lyrics")
  end
  return tr("nothing_playing")
end

--- One character of a line, painted by how much of it has been sung.
local function charLabel(ui, line, index, charIndex, char, amount, size, accent)
  local color = accent
  local opacity = 1
  if amount <= 0 then
    color = "on_surface"
    opacity = 0.45
  elseif amount < 1 then
    -- Half sung: the character is already the accent colour, faded. The host
    -- blends it, so the fill edge stays smooth.
    opacity = 0.3 + 0.7 * clamp(amount, 0, 1)
  end
  return ui.label({
    key = string.format("c%d-%d", index, charIndex),
    text = char,
    color = color,
    opacity = opacity,
    fontSize = size,
    maxLines = 1,
  })
end

--- One line of the carousel: marker (active only) + text or characters.
local function lineRow(opts, lineIndex, isActive, accent)
  local ui = opts.ui
  local cfg = opts.cfg or {}
  local model = opts.model
  local line = (opts.lines or {})[lineIndex]
  if line == nil then
    return nil
  end
  local position = tonumber(opts.position) or 0
  local size = tonumber(cfg.font_size) or 22
  if isActive then
    size = size * (tonumber(cfg.active_scale) or 1.35)
  end
  local children = {}

  if isActive and cfg.marker then
    children[#children + 1] = ui.label({
      key = "marker",
      text = pick(M.MARKERS, cfg.marker_style, M.MARKERS[1]),
      color = accent,
      fontSize = size,
      maxLines = 1,
    })
  end

  local characters = model.characters(line.text)
  local perChar = isActive
    and cfg.karaoke ~= false
    and #characters > 0
    and #characters <= M.MAX_KARAOKE_CHARS
    and type(line.chars) == "table"
    and #line.chars >= #characters

  if perChar then
    local amounts = model.charAmounts(line, position)
    for charIndex, char in ipairs(characters) do
      children[#children + 1] =
        charLabel(ui, line, lineIndex, charIndex, char, amounts[charIndex] or 0, size, accent)
    end
  elseif line.text ~= "" then
    children[#children + 1] = ui.label({
      key = "text",
      text = line.text,
      color = isActive and accent or "on_surface",
      fontSize = size,
      maxLines = 1,
    })
  end

  local opacity = 1
  if not isActive and cfg.ghost ~= false then
    opacity = 0.55
  end
  return ui.row({
    key = "row-" .. tostring(lineIndex),
    gap = 0,
    align = "center",
    justify = "center",
    opacity = opacity,
  }, children)
end
M.lineRow = lineRow

--- The instrumental placeholder: the notes glyph, or the custom text.
local function instrumentalRow(opts, accent)
  local ui = opts.ui
  local cfg = opts.cfg or {}
  local text = tostring(cfg.instrumental_text or "")
  if text == "" then
    text = pick(M.ICONS, cfg.instrumental_icon, M.ICONS[1])
  end
  local size = tonumber(cfg.font_size) or 22
  return ui.row({
    key = "instrumental",
    gap = 0,
    align = "center",
    justify = "center",
  }, {
    ui.label({
      key = "instrumental-text",
      text = text,
      color = accent,
      opacity = 0.85,
      fontSize = size * 1.1,
      maxLines = 1,
    }),
  })
end

--- True if the player is in a stretch with nothing to sing.
local function isInstrumental(opts)
  local cfg = opts.cfg or {}
  if cfg.instrumental == false then
    return false
  end
  local lines = opts.lines or {}
  if #lines == 0 then
    return false
  end
  return opts.model.instrumental(
    lines,
    tonumber(opts.position) or 0,
    tonumber(opts.duration) or 0,
    cfg.silence_threshold
  )
end

--- The scrolling lines: a column of rows, or the single instrumental row.
function M.carousel(opts)
  local ui = opts.ui
  local cfg = opts.cfg or {}
  local model = opts.model
  local lines = opts.lines or {}
  local spacing = tonumber(cfg.spacing) or 2
  local accent = M.accentColor(cfg, opts.color)

  if isInstrumental(opts) then
    return ui.column({ key = "carousel", gap = spacing, align = "center" }, {
      instrumentalRow(opts, accent),
    })
  end

  local index = model.activeIndex(lines, tonumber(opts.position) or 0)
  local above = math.max(0, math.floor(tonumber(cfg.visible_above) or 0))
  local below = math.max(0, math.floor(tonumber(cfg.visible_below) or 0))

  local first, last
  if index == 0 then
    -- Intro: nothing is active yet, so show the lines that are about to be.
    first = 1
    last = math.min(#lines, below + 1)
  else
    first = math.max(1, index - above)
    last = math.min(#lines, index + below)
  end

  local rows = {}
  if cfg.direction == "up" then
    for lineIndex = last, first, -1 do
      rows[#rows + 1] = lineRow(opts, lineIndex, lineIndex == index, accent)
    end
  else
    for lineIndex = first, last do
      rows[#rows + 1] = lineRow(opts, lineIndex, lineIndex == index, accent)
    end
  end

  return ui.column({ key = "carousel", gap = spacing, align = "center" }, rows)
end

--- Title, artist and the rule under them.
local function header(opts, accent)
  local ui = opts.ui
  local cfg = opts.cfg or {}
  local tr = trOf(opts)
  local size = tonumber(cfg.font_size) or 22
  local title = opts.title
  if title == nil or title == "" then
    title = tr("nothing_playing")
  end
  local artist = tostring(opts.artist or "")
  local children = {
    ui.label({
      key = "title",
      text = title,
      color = "on_surface",
      fontSize = size * 0.95,
      fontWeight = "bold",
      maxLines = 1,
    }),
  }
  if artist ~= "" then
    children[#children + 1] = ui.label({
      key = "artist",
      text = "\u{2014} " .. artist,
      color = "on_surface",
      opacity = 0.6,
      fontSize = size * 0.8,
      maxLines = 1,
    })
  end
  children[#children + 1] = ui.box({
    key = "rule",
    height = 1,
    flexGrow = 1,
    fill = accent .. "/0.35",
  })
  return ui.column({ key = "header", gap = 0, align = "stretch" }, children)
end

--- Elapsed time and a progress bar.
local function footer(opts, accent)
  local ui = opts.ui
  local cfg = opts.cfg or {}
  local size = tonumber(cfg.font_size) or 22
  local position = tonumber(opts.position) or 0
  local duration = tonumber(opts.duration) or 0
  local progress = 0
  if duration > 0 then
    progress = clamp(position / duration, 0, 1)
  end
  local played = math.max(progress, 0.001)
  return ui.row({ key = "footer", gap = 8, align = "center" }, {
    ui.label({
      key = "time",
      text = M.clock(position) .. " / " .. M.clock(duration),
      color = "on_surface",
      opacity = 0.6,
      fontSize = size * 0.62,
      maxLines = 1,
    }),
    ui.row({ key = "bar", gap = 0, flexGrow = 1, align = "center" }, {
      ui.box({ key = "played", height = 2, flexGrow = played, fill = accent }),
      ui.box({ key = "left", height = 2, flexGrow = 1 - played + 0.001, fill = "on_surface/0.25" }),
    }),
  })
end

--- The whole surface of the panel or the desktop widget.
function M.surface(opts)
  local ui = opts.ui
  local cfg = opts.cfg or {}
  -- The "offset" setting shifts the whole lyric earlier or later. It is
  -- applied here, once, so the widget, the panel and the desktop widget can
  -- never disagree about which line is the current one.
  local shifted = {}
  for key, value in pairs(opts) do
    shifted[key] = value
  end
  shifted.position = (tonumber(opts.position) or 0) + (tonumber(cfg.offset_ms) or 0) / 1000
  opts = shifted
  local mode = opts.mode or "panel"
  local state = opts.state or "lyrics"
  local tr = trOf(opts)
  local spacing = tonumber(cfg.spacing) or 2
  local accent = M.accentColor(cfg, opts.color)
  local lines = opts.lines or {}

  if mode == "widget" then
    if state ~= "lyrics" or #lines == 0 then
      return ui.row({ key = "widget", gap = 0, align = "center" }, {
        ui.label({
          key = "widget-state",
          text = M.stateText(state, tr),
          color = "on_surface",
          fontSize = tonumber(cfg.font_size) or 22,
          maxLines = 1,
        }),
      })
    end
    if isInstrumental(opts) then
      return instrumentalRow(opts, accent)
    end
    local index = opts.model.activeIndex(lines, tonumber(opts.position) or 0)
    if index == 0 then
      index = 1
    end
    return lineRow(opts, index, true, accent)
  end

  local children = {}
  if cfg.header then
    children[#children + 1] = header(opts, accent)
  end
  if state == "lyrics" and #lines > 0 then
    children[#children + 1] = M.carousel(opts)
  else
    children[#children + 1] = ui.column({ key = "state", gap = 0, align = "center", flexGrow = 1 }, {
      ui.label({ key = "state-text", text = M.stateText(state, tr), color = "on_surface", maxLines = 2 }),
    })
  end
  if cfg.footer then
    children[#children + 1] = footer(opts, accent)
  end
  return ui.column({ key = "surface", gap = spacing, align = "stretch" }, children)
end

return M
