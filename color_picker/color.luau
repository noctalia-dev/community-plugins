--!nonstrict

local color = {}

function color.hexToRgb(hex)
  local r = tonumber(hex:sub(2, 3), 16)
  local g = tonumber(hex:sub(4, 5), 16)
  local b = tonumber(hex:sub(6, 7), 16)
  return r, g, b
end

function color.rgbToHsl(r, g, b)
  r, g, b = r / 255, g / 255, b / 255
  local max, min = math.max(r, g, b), math.min(r, g, b)
  local h, s, l = 0, 0, (max + min) / 2

  if max ~= min then
    local d = max - min
    s = (l > 0.5) and (d / (2 - max - min)) or (d / (max + min))
    if max == r then
      h = (g - b) / d + ((g < b) and 6 or 0)
    elseif max == g then
      h = (b - r) / d + 2
    else
      h = (r - g) / d + 4
    end
    h = h / 6
  end

  return math.floor(h * 360 + 0.5), math.floor(s * 100 + 0.5), math.floor(l * 100 + 0.5)
end

function color.hslToHex(h, s, l)
  local sf, lf = s / 100, l / 100

  local function hueToRgb(p, q, t)
    if t < 0 then
      t = t + 1
    end
    if t > 1 then
      t = t - 1
    end
    if t < 1 / 6 then
      return p + (q - p) * 6 * t
    end
    if t < 1 / 2 then
      return q
    end
    if t < 2 / 3 then
      return p + (q - p) * (2 / 3 - t) * 6
    end
    return p
  end

  local r, g, b
  if sf == 0 then
    r, g, b = lf, lf, lf
  else
    local q = (lf < 0.5) and (lf * (1 + sf)) or (lf + sf - lf * sf)
    local p = 2 * lf - q
    local hn = h / 360
    r = hueToRgb(p, q, hn + 1 / 3)
    g = hueToRgb(p, q, hn)
    b = hueToRgb(p, q, hn - 1 / 3)
  end

  return string.format("#%02X%02X%02X", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

function color.formatHex(hex: string, alpha: number): string
  if alpha < 1 then
    local alphaVal = math.floor(alpha * 255 + 0.5)
    if hex:match("%l") then
      return hex .. string.format("%02x", alphaVal)
    else
      return hex .. string.format("%02X", alphaVal)
    end
  end
  return hex
end

function color.formatRgb(hex, alpha)
  local r, g, b = color.hexToRgb(hex)
  if alpha < 1 then
    return string.format("rgba(%d, %d, %d, %.2f)", r, g, b, alpha)
  end
  return string.format("rgb(%d, %d, %d)", r, g, b)
end

function color.formatHsl(hex, alpha)
  local r, g, b = color.hexToRgb(hex)
  local h, s, l = color.rgbToHsl(r, g, b)
  if alpha < 1 then
    return string.format("hsla(%d, %d%%, %d%%, %.2f)", h, s, l, alpha)
  end
  return string.format("hsl(%d, %d%%, %d%%)", h, s, l)
end

function color.parsePickerOutput(output)
  output = output:gsub("%s+$", "")

  -- Tries Hex first
  local hex = output:match("#%x%x%x%x%x%x")
  if hex then
    noctalia.log("[COLOR PICKER] hex = " .. hex)
    return hex:upper()
  end

  -- Tries HSL: "H S% L%" or "H S L" (H no %, S/L optional %)
  local h, s, l = output:match("^(%d+)%s+(%d+)%%?%s+(%d+)%%?$")
  if h then
    noctalia.log("[COLOR PICKER] hsl = " .. h .. ", " .. s .. ", " .. l)
    h, s, l = tonumber(h), tonumber(s), tonumber(l)
    if h <= 360 and s <= 100 and l <= 100 then
      return color.hslToHex(h, s, l)
    end
  end

  -- Tries RGB
  local r, g, b = output:match("^(%d+)%s+(%d+)%s+(%d+)$")
  if r then
    noctalia.log("[COLOR PICKER] hsl = " .. r .. ", " .. g .. ", " .. b)
    r, g, b = tonumber(r), tonumber(g), tonumber(b)
    if r <= 255 and g <= 255 and b <= 255 then
      return string.format("#%02X%02X%02X", r, g, b)
    end
  end

  return nil
end

function color.parseHexText(text: string)
  local clean = text:match("^#?(%x+)$")
  if clean == nil then
    return nil, nil
  end

  if #clean == 6 then
    return "#" .. clean:upper(), nil
  elseif #clean == 8 then
    local hex = "#" .. clean:sub(1, 6):upper()
    local a = tonumber(clean:sub(7, 8), 16)
    return hex, a / 255
  end
  return nil, nil
end

function color.parseRgbText(text: string)
  local r, g, b, a_str = text:match("^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*[,]?%s*([%d%.]*)")
  if r == nil then
    return nil, nil
  end
  r, g, b = tonumber(r), tonumber(g), tonumber(b)
  if r > 255 or g > 255 or b > 255 then
    return nil, nil
  end

  local hex = string.format("#%02X%02X%02X", r, g, b)
  local alpha = nil
  if a_str and a_str ~= "" then
    alpha = tonumber(a_str)
    if alpha and alpha > 1 then
      alpha = alpha / 100
    end
  end
  return hex, alpha
end

function color.parseHslText(text: string)
  local h, s, l, a_str = text:match("^%s*(%d+)%s*,%s*(%d+)%%?%s*,%s*(%d+)%%?%s*[,]?%s*([%d%.]*)")
  if h == nil then
    return nil, nil
  end
  h, s, l = tonumber(h), tonumber(s), tonumber(l)

  local hex = color.hslToHex(h, s, l)

  local alpha = nil
  if a_str and a_str ~= "" then
    alpha = tonumber(a_str)
    if alpha and alpha > 1 then
      alpha = alpha / 100
    end
  end
  return hex, alpha
end

return color
