--!nonstrict
local dir = noctalia.pluginDir() or "."
local fontAnurati = noctalia.loadFont("fonts/Anurati.otf")
  or (noctalia.pluginDir() and noctalia.loadFont(noctalia.pluginDir() .. "/fonts/Anurati.otf"))
  or "Anurati"

local fontPoppins = noctalia.loadFont("fonts/Poppins.ttf")
  or (noctalia.pluginDir() and noctalia.loadFont(noctalia.pluginDir() .. "/fonts/Poppins.ttf"))
  or "Poppins"

desktopWidget.setWantsSecondTicks(true)

-- Converts Qt-style date format (from KDE ModernClock) to std::chrono/strftime format
local function normalizeFormat(fmt: string): string
  if string.find(fmt, "%%") then
    return fmt
  end
  local map = {
    ["yyyy"] = "%Y",
    ["yy"] = "%y",
    ["MMMM"] = "%B",
    ["MMM"] = "%b",
    ["MM"] = "%m",
    ["dddd"] = "%A",
    ["ddd"] = "%a",
    ["dd"] = "%d",
    ["hh"] = "%H",
    ["mm"] = "%M",
    ["ss"] = "%S",
    ["AP"] = "%p",
    ["ap"] = "%p",
  }
  local res = fmt
  for k, v in pairs(map) do
    res = string.gsub(res, k, v)
  end
  return res
end

local function applySpacing(text: string, spaces: number): string
  if spaces <= 0 then
    return text
  end
  local sep = string.rep(" ", spaces)
  local chars = {}
  local ok = pcall(function()
    for _, code in utf8.codes(text) do
      table.insert(chars, utf8.char(code))
    end
  end)
  if not ok or #chars <= 1 then
    if #text <= 1 then return text end
    chars = {}
    for i = 1, #text do
      table.insert(chars, string.sub(text, i, i))
    end
  end
  if #chars <= 1 then
    return text
  end
  return table.concat(chars, sep)
end

function update()
  local show_day = noctalia.getConfig("show_day")
  if show_day == nil then show_day = true end
  local day_font_size = noctalia.getConfig("day_font_size") or 72
  local day_font_color = noctalia.getConfig("day_font_color") or "#FFFFFF"
  local day_letter_spacing = noctalia.getConfig("day_letter_spacing") or 2

  local show_date = noctalia.getConfig("show_date")
  if show_date == nil then show_date = true end
  local date_font_size = noctalia.getConfig("date_font_size") or 19
  local date_font_color = noctalia.getConfig("date_font_color") or "#FFFFFF"
  local date_letter_spacing = noctalia.getConfig("date_letter_spacing") or 1
  local raw_date_format = noctalia.getConfig("date_format") or "%d %b %Y"
  local date_format = normalizeFormat(raw_date_format)

  local show_time = noctalia.getConfig("show_time")
  if show_time == nil then show_time = true end
  local time_font_size = noctalia.getConfig("time_font_size") or 19
  local time_font_color = noctalia.getConfig("time_font_color") or "#FFFFFF"
  local time_letter_spacing = noctalia.getConfig("time_letter_spacing") or 1
  local use_24_hour_format = noctalia.getConfig("use_24_hour_format")
  if use_24_hour_format == nil then use_24_hour_format = false end
  local time_character = noctalia.getConfig("time_character") or "-"

  local items = {}

  if show_day then
    local day_str = string.upper(noctalia.formatTime("%A"))
    if day_letter_spacing > 0 then
      day_str = applySpacing(day_str, day_letter_spacing)
    end
    table.insert(items, ui.label({
      text = day_str,
      fontFamily = fontAnurati,
      fontSize = day_font_size,
      color = day_font_color,
      textAlign = "center",
      baseline = "text"
    }))
  end

  if show_date then
    local date_str = string.upper(noctalia.formatTime(date_format))
    if date_letter_spacing > 0 then
      date_str = applySpacing(date_str, date_letter_spacing)
    end
    table.insert(items, ui.label({
      text = date_str,
      fontFamily = fontPoppins,
      fontSize = date_font_size,
      color = date_font_color,
      textAlign = "center",
      baseline = "text"
    }))
  end

  if show_time then
    local fmt = use_24_hour_format and "%H:%M" or "%I:%M %p"
    local raw_time = noctalia.formatTime(fmt)
    local time_str = string.upper(time_character .. " " .. raw_time .. " " .. time_character)
    if time_letter_spacing > 0 then
      time_str = applySpacing(time_str, time_letter_spacing)
    end
    table.insert(items, ui.label({
      text = time_str,
      fontFamily = fontPoppins,
      fontSize = time_font_size,
      color = time_font_color,
      textAlign = "center",
      baseline = "text"
    }))
  end

  desktopWidget.render(ui.column({
    gap = 5,
    align = "center",
    justify = "center"
  }, items))
end

update()


