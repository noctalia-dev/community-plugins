--!nonstrict
-- Shared formatting, host lookup, and severity helpers for Beszel Desktop entries.

local M = {}

local GIB_BYTES = 1024 * 1024 * 1024

function M.clamp(val, minVal, maxVal)
  if val < minVal then
    return minVal
  end
  if val > maxVal then
    return maxVal
  end
  return val
end

function M.thresholds()
  local warn = tonumber(noctalia.getConfig("warn_threshold")) or 70
  local danger = tonumber(noctalia.getConfig("danger_threshold")) or 90
  warn = M.clamp(math.floor(warn), 10, 99)
  danger = M.clamp(math.floor(danger), warn + 1, 100)
  return warn, danger
end

function M.staleMs()
  local secs = tonumber(noctalia.getConfig("stale_seconds")) or 5
  return M.clamp(math.floor(secs), 2, 60) * 1000
end

function M.padPercent(value)
  local n = math.max(0, math.floor((tonumber(value) or 0) + 0.5))
  if n < 10 then
    return string.format("0%d%%", n)
  end
  return string.format("%d%%", n)
end

function M.formatGiB(bytes)
  return string.format("%.1f", (tonumber(bytes) or 0) / GIB_BYTES)
end

function M.severityColor(pct, normalColor, warnPct, dangerPct)
  local value = tonumber(pct) or 0
  if value >= dangerPct then
    return "error"
  end
  if value >= warnPct then
    return "tertiary"
  end
  return normalColor
end

function M.findSystem(systems, filter)
  if type(systems) ~= "table" or #systems == 0 then
    return nil
  end
  local trimmed = noctalia.string.trim(filter or "")
  if trimmed == "" then
    return systems[1]
  end
  local needle = string.lower(trimmed)
  for _, sys in ipairs(systems) do
    if sys.id == trimmed or string.lower(sys.name or "") == needle then
      return sys
    end
  end
  return nil
end

function M.findSystemById(systems, targetId)
  if type(systems) ~= "table" or not targetId or targetId == "" then
    return nil
  end
  for _, sys in ipairs(systems) do
    if sys.id == targetId then
      return sys
    end
  end
  return nil
end

function M.latestSample(data, systemId)
  if type(data) ~= "table" or type(data.historyBySystem) ~= "table" or not systemId then
    return nil
  end
  local list = data.historyBySystem[systemId]
  if type(list) ~= "table" or #list == 0 then
    return nil
  end
  return list[#list]
end

function M.effectiveState(data, system, latest, filter)
  if type(data) ~= "table" or type(data.connection) ~= "table" then
    return "disconnected"
  end
  local rawState = data.connection.state or "disconnected"
  if rawState ~= "connected" then
    return rawState
  end
  local trimmed = noctalia.string.trim(filter or "")
  if trimmed ~= "" and system == nil then
    return "not_found"
  end
  if latest ~= nil and latest.timestamp_ms ~= nil then
    local ageMs = noctalia.nowMs() - (tonumber(latest.timestamp_ms) or 0)
    if ageMs > M.staleMs() then
      return "stale"
    end
  end
  return "connected"
end

function M.stateColor(state)
  if state == "connected" then
    return "primary"
  end
  if state == "stale" or state == "connecting" or state == "reconnecting"
      or state == "paused" or state == "not_found" then
    return "tertiary"
  end
  return "error"
end

function M.stateLabel(state, filter)
  if state == "not_found" then
    return noctalia.tr("state.not_found", { host = noctalia.string.trim(filter or "") })
  end
  return noctalia.tr("state." .. (state or "disconnected"))
end

return M
