--!nonstrict
-- Shared formatting, host lookup, and severity helpers for Beszel Desktop entries.

local M = {}

local KIB_BYTES = 1024
local MIB_BYTES = 1024 * 1024
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

function M.formatGiBCompact(usedBytes, totalBytes)
  local used = (tonumber(usedBytes) or 0) / GIB_BYTES
  local total = (tonumber(totalBytes) or 0) / GIB_BYTES
  if total >= 100 then
    return string.format("%.0f / %.0f GiB", used, total)
  end
  return string.format("%.1f / %.0f GiB", used, total)
end

function M.formatMb(mb)
  local value = math.max(0, tonumber(mb) or 0)
  if value >= 1024 then
    return string.format("%.1f GiB", value / 1024.0)
  end
  return string.format("%d MiB", math.floor(value + 0.5))
end

function M.formatRate(bps)
  local value = math.max(0, tonumber(bps) or 0)
  if value < KIB_BYTES then
    return string.format("%d B/s", math.floor(value + 0.5))
  end
  if value < MIB_BYTES then
    local kb = value / KIB_BYTES
    if kb < 10 then
      return string.format("%.1f KB/s", kb)
    end
    return string.format("%d KB/s", math.floor(kb + 0.5))
  end
  if value < GIB_BYTES then
    local mb = value / MIB_BYTES
    if mb < 10 then
      return string.format("%.1f MB/s", mb)
    end
    return string.format("%d MB/s", math.floor(mb + 0.5))
  end
  local gb = value / GIB_BYTES
  if gb < 10 then
    return string.format("%.2f GB/s", gb)
  end
  return string.format("%.1f GB/s", gb)
end

function M.formatCompactRate(bps)
  local value = math.max(0, tonumber(bps) or 0)
  if value < 1000 then
    return string.format("%dB", math.floor(value + 0.5))
  end
  if value < 1000 * KIB_BYTES then
    local kb = value / KIB_BYTES
    if kb < 10 then
      return string.format("%.1fK", kb)
    end
    return string.format("%dK", math.floor(kb + 0.5))
  end
  if value < 1000 * MIB_BYTES then
    local mb = value / MIB_BYTES
    if mb < 10 then
      return string.format("%.1fM", mb)
    end
    return string.format("%dM", math.floor(mb + 0.5))
  end
  local gb = value / GIB_BYTES
  if gb < 10 then
    return string.format("%.1fG", gb)
  end
  return string.format("%dG", math.floor(gb + 0.5))
end

function M.formatTemp(tempC)
  local value = tonumber(tempC) or 0
  return string.format("%d°C", math.floor(value + 0.5))
end

function M.tempSeverityColor(tempC, normalColor)
  local value = tonumber(tempC) or 0
  if value >= 90 then
    return "error"
  end
  if value >= 75 then
    return "tertiary"
  end
  return normalColor
end

function M.formatUptime(secs)
  local total = math.max(0, math.floor(tonumber(secs) or 0))
  local days = math.floor(total / 86400)
  local hours = math.floor((total % 86400) / 3600)
  local mins = math.floor((total % 3600) / 60)
  if days > 0 then
    return string.format("%dd %dh", days, hours)
  end
  if hours > 0 then
    return string.format("%dh %dm", hours, mins)
  end
  return string.format("%dm", math.max(1, mins))
end

function M.formatAge(ageMs)
  local secs = math.max(0, math.floor((tonumber(ageMs) or 0) / 1000))
  if secs < 60 then
    return string.format("%ds", secs)
  end
  local mins = math.floor(secs / 60)
  local remSecs = secs % 60
  if mins < 60 then
    return string.format("%dm %ds", mins, remSecs)
  end
  local hours = math.floor(mins / 60)
  local remMins = mins % 60
  return string.format("%dh %dm", hours, remMins)
end

function M.isHardOffline(state)
  return state == "disconnected" or state == "auth_error"
end

function M.isStaleState(state)
  return state == "stale" or state == "reconnecting" or state == "connecting" or state == "paused"
end

function M.cleanOsName(name)
  if type(name) ~= "string" then
    return nil
  end
  local s = noctalia.string.trim(name)
  if s == "" then
    return nil
  end
  s = string.gsub(s, "%s*%b()", "")
  s = string.gsub(s, "%s+GNU/Linux", "")
  s = string.gsub(s, "^Fedora%s+Linux%s+", "Fedora ")
  s = string.gsub(s, "%s+", " ")
  s = noctalia.string.trim(s)
  return s ~= "" and s or nil
end

function M.cleanCpuModel(model)
  if type(model) ~= "string" then
    return nil
  end
  local s = noctalia.string.trim(model)
  if s == "" then
    return nil
  end
  s = string.gsub(s, "%([RrTt][Mm]?%)", "")
  s = string.gsub(s, "%([Cc]%)", "")
  s = string.gsub(s, "®", "")
  s = string.gsub(s, "™", "")
  s = string.gsub(s, "%s*@%s*[%d%.]+%s*[GMK]?Hz.*$", "")
  s = string.gsub(s, "%s+[Ww]/%s+Radeon.*$", "")
  s = string.gsub(s, "%s+[Ww]ith%s+Radeon.*$", "")
  s = string.gsub(s, "^%d+[a-z][a-z]%s+Gen%s+", "")
  s = string.gsub(s, "%s+%d+%-Core", "")
  s = string.gsub(s, "%s+Processor", "")
  s = string.gsub(s, "%s+CPU%s+", " ")
  s = string.gsub(s, "%s+CPU$", "")
  s = string.gsub(s, "%s+", " ")
  s = noctalia.string.trim(s)
  return s ~= "" and s or nil
end

function M.primaryGpu(sample)
  if type(sample) ~= "table" or type(sample.gpus) ~= "table" or #sample.gpus == 0 then
    return nil
  end
  return sample.gpus[1]
end

function M.hasNetwork(sample)
  return type(sample) == "table" and (sample.net_recv_bps ~= nil or sample.net_sent_bps ~= nil)
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

function M.alertsForSystem(data, systemId)
  if type(data) ~= "table" or type(data.alertsBySystem) ~= "table" or not systemId then
    return {}
  end
  local list = data.alertsBySystem[systemId]
  if type(list) ~= "table" then
    return {}
  end
  return list
end

local function formatAlertNumber(val)
  local n = tonumber(val) or 0
  if math.floor(n) == n then
    return string.format("%d", n)
  end
  return string.format("%.1f", n)
end

local ALERT_SPEC = {
  Status = { label = "Host down", noVal = true },
  CPU = { label = "CPU", op = "≥", unit = "%" },
  CPUIOWait = { label = "CPU I/O wait", op = "≥", unit = "%" },
  CPUSteal = { label = "CPU steal", op = "≥", unit = "%" },
  Memory = { label = "Memory", op = "≥", unit = "%" },
  Disk = { label = "Disk", op = "≥", unit = "%" },
  Bandwidth = { label = "Bandwidth", op = "≥", unit = " MB/s" },
  GPU = { label = "GPU", op = "≥", unit = "%" },
  Temperature = { label = "Temperature", op = "≥", unit = "°C" },
  Battery = { label = "Battery", op = "≤", unit = "%" },
  LoadAvg1 = { label = "Load (1m)", op = "≥", unit = "" },
  LoadAvg5 = { label = "Load (5m)", op = "≥", unit = "" },
  LoadAvg15 = { label = "Load (15m)", op = "≥", unit = "" },
  NetworkMonitorLoss = { label = "Packet loss", op = "≥", unit = "%" },
  NetworkMonitorCert = { label = "TLS cert expiring", op = "≤", unit = "d" },
  ContainerHealth = { label = "Unhealthy container", noVal = true },
  SystemdFailed = { label = "Failed systemd service", noVal = true },
}

function M.formatAlert(alert)
  if type(alert) ~= "table" then
    return ""
  end
  local name = tostring(alert.name or "Alert")
  local spec = ALERT_SPEC[name]
  local text
  if spec ~= nil then
    if spec.noVal or alert.value == nil then
      text = spec.label
    else
      text = string.format("%s %s %s%s", spec.label, spec.op, formatAlertNumber(alert.value), spec.unit)
    end
  elseif alert.value ~= nil then
    text = string.format("%s (%s)", name, formatAlertNumber(alert.value))
  else
    text = name
  end
  local mins = tonumber(alert.min) or 0
  if mins > 0 then
    text = string.format("%s (%dm)", text, math.floor(mins))
  end
  return text
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
