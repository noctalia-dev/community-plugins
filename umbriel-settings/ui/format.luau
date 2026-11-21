--!nonstrict
-- How values look in the UI: locale numbers (typing accepts both separators) and readable field values.
local M = {}

-- Numbers follow the system's numeric locale (LC_ALL > LC_NUMERIC > LANG): "0,75" in German.
-- The config file always stores a dot; only display and typing change.
local COMMA_LANGUAGES = {
  de = true, fr = true, es = true, it = true, nl = true, pt = true, ru = true, pl = true, cs = true, sk = true,
  sv = true, da = true, nb = true, nn = true, no = true, fi = true, tr = true, uk = true, hu = true, ro = true,
  hr = true, sl = true, el = true, bg = true, lt = true, lv = true, et = true, id = true, vi = true, be = true,
}
local decimalPoint = nil
local function getDecimalPoint()
  if decimalPoint == nil then
    local value = ""
    for _, name in ipairs({ "LC_ALL", "LC_NUMERIC", "LANG" }) do
      local found = noctalia.getenv(name)
      if found and found ~= "" then value = found; break end
    end
    decimalPoint = COMMA_LANGUAGES[string.lower(string.match(value, "^(%a+)") or "")] and "," or "."
  end
  return decimalPoint
end

-- A number as text with the locale's decimal separator.
function M.number(value)
  if type(value) ~= "number" then return tostring(value) end
  local text
  if value == math.floor(value) and math.abs(value) < 1e15 then text = string.format("%d", math.floor(value))
  else text = string.format("%.15g", value) end
  if getDecimalPoint() ~= "." then text = (string.gsub(text, "%.", getDecimalPoint())) end
  return text
end

-- An opacity 0..1 as the alpha byte of a #RRGGBBAA color ("80").
function M.alphaByte(opacity) return string.format("%02X", math.floor(opacity * 255 + 0.5)) end

-- Parse typed text; both "0,75" and "0.75" are accepted.
function M.parseNumber(text)
  text = noctalia.string.trim(text or "")
  if text == "" then return nil end
  return tonumber((string.gsub(text, ",", ".")))
end

-- A value as the UI shows it (choice labels, locale numbers, "not set").
function M.value(field, value)
  if value == nil then return "not set" end
  local kind = field.kind
  if kind == "bool" then return value and "On" or "Off" end
  if type(value) == "number" and field.special and value == field.special.value then
    return string.lower(field.special.label)
  end
  if type(value) == "number" then return M.number(value) end
  if type(value) == "table" then
    if kind == "table" then
      local parts = {}
      for _, key in ipairs(field.keys or {}) do
        if value[key] ~= nil then table.insert(parts, key .. " " .. M.number(value[key])) end
      end
      return table.concat(parts, ", ")
    end
    local parts = {}
    for _, item in ipairs(value) do table.insert(parts, tostring(item)) end
    return #parts > 0 and table.concat(parts, ", ") or "empty"
  end
  local text = tostring(value)
  if text == "" then return "empty" end
  if field.choice_labels then
    for i, choice in ipairs(field.choices or {}) do
      if choice == text then return field.choice_labels[i] or text end
    end
  end
  return text
end

local function readablePattern(text)
  text = tostring(text)
  if string.sub(text, 1, 1) == "^" then text = string.sub(text, 2) end
  if string.sub(text, -1) == "$" and string.sub(text, -2) ~= "\\$" then text = string.sub(text, 1, -2) end
  return (string.gsub(text, "\\%.", "."))
end

-- A rule's match as a title: anchors and escapes dropped, an app id's last part, the kind in brackets.
function M.readableMatch(key, value)
  local patterns = type(value) == "table" and value or { value }
  local names = {}
  for _, pattern in ipairs(patterns) do
    local text = readablePattern(pattern)
    if key == "app_id" then
      local last = string.match(text, "^[%w_-]+%.[%w_-]+%.[%w_.-]*%.([%w_-]+)$")
        or string.match(text, "^[%w_-]+%.[%w_-]+%.([%w_-]+)$")
      if last then text = last end
    end
    table.insert(names, text)
  end
  local kind = key == "app_id" and "app id" or key == "namespace" and "layer" or key
  return table.concat(names, ", ") .. " (" .. kind .. ")"
end

return M
