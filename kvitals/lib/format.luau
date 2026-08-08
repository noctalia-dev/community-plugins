--!nonstrict
-- Number and unit formatting helpers (KVitals-style, unit-aware).
-- Pure functions; no host calls beyond what is passed in.

local M = {}

-- Bytes with automatic decimal scaling. Returns "512B", "340K", "1.2M".
function M.autoBytes(bytes)
  if bytes == nil then return "-" end
  local b = bytes
  if b < 1000 then return string.format("%dB", math.floor(b + 0.5)) end
  b = b / 1000
  if b < 1000 then return string.format("%.1fK", b) end
  b = b / 1000
  if b < 1000 then return string.format("%.1fM", b) end
  b = b / 1000
  return string.format("%.2fG", b)
end

-- Bytes per second with a fixed unit from the net_unit setting.
-- unit is "auto", "kb", or "mb".
function M.netBytes(bytes, unit)
  if bytes == nil then return "-" end
  if unit == "kb" then return string.format("%.0fK", bytes / 1000) end
  if unit == "mb" then return string.format("%.1fM", bytes / 1000000) end
  return M.autoBytes(bytes)
end

-- RAM bytes with binary scaling. Returns "6.1G", "512M".
function M.ramBytes(bytes)
  if bytes == nil then return "-" end
  local b = bytes
  if b < 1024 then return string.format("%dB", math.floor(b + 0.5)) end
  b = b / 1024
  if b < 1024 then return string.format("%.0fK", b) end
  b = b / 1024
  if b < 1024 then return string.format("%.1fM", b) end
  b = b / 1024
  return string.format("%.2fG", b)
end

-- Percent value. Returns "45%".
function M.pct(value)
  if value == nil then return "-" end
  return string.format("%.0f%%", value)
end

-- Temperature. unit is "c" or "f"; suffix true appends the unit letter.
-- Returns "52°", "52°C", or "52°F".
function M.temp(celsius, unit, suffix)
  if celsius == nil then return "-" end
  local value = celsius
  if unit == "f" then value = celsius * 9 / 5 + 32 end
  local text = string.format("%.0f°", value)
  if suffix then
    text = text .. (unit == "f" and "F" or "C")
  end
  return text
end

-- CPU frequency, compact. Returns "3.20G" or "850M".
function M.freqCompact(hz)
  if hz == nil then return "-" end
  if hz >= 1e9 then return string.format("%.2fG", hz / 1e9) end
  if hz >= 1e6 then return string.format("%.0fM", hz / 1e6) end
  return string.format("%.0fK", hz / 1e3)
end

-- CPU frequency, full. Returns "3.20 GHz" or "850 MHz".
function M.freqHz(hz)
  if hz == nil then return "-" end
  if hz >= 1e9 then return string.format("%.2f GHz", hz / 1e9) end
  if hz >= 1e6 then return string.format("%.0f MHz", hz / 1e6) end
  return string.format("%.0f kHz", hz / 1e3)
end

-- Fan speed in RPM. Returns "1200".
function M.rpm(value)
  if value == nil then return "-" end
  return string.format("%d", value)
end

-- Power draw in watts. Returns "12W" or "12.3W".
function M.watts(w)
  if w == nil then return "-" end
  if w >= 100 then return string.format("%.0fW", w) end
  return string.format("%.1fW", w)
end

-- Load average. Returns "1.2".
function M.load(value)
  if value == nil then return "-" end
  return string.format("%.2f", value)
end

-- Add an alpha channel to a color for translucent rendering.
-- Role token "primary" -> "primary/0.65"; hex "#8f9bff" -> "#8f9bffa6".
function M.withAlpha(color, alpha)
  if color == nil then return nil end
  if string.sub(color, 1, 1) == "#" then
    local a = string.format("%02x", math.floor(alpha * 255 + 0.5))
    return color .. a
  end
  return color .. "/" .. tostring(alpha)
end

return M
