--!nonstrict
-- Shared metric descriptors for the bar widget, panel, and desktop tile.
--
-- A chip is a plain table: { id, glyph, text, tint, charging }.
-- tint is nil (normal), "active" (at or above the activity threshold),
-- or "critical" (at or above the critical threshold). Pure functions over
-- the sample and the resolved config from the plugin state.

local format = require("./format.luau")

local M = {}

local function tintLevel(thresholds, value)
  if value == nil or thresholds == nil then return nil end
  local act = thresholds.act or 50
  local crit = thresholds.crit or 90
  if value >= crit then return "critical" end
  if value >= act then return "active" end
  return nil
end

local builders = {
  cpu = function(s, c)
    if s.cpu == nil or s.cpu.usage == nil then return nil end
    local text = format.pct(s.cpu.usage)
    if c.showCpuFreq and s.cpuFreqHz then
      text = text .. " " .. format.freqCompact(s.cpuFreqHz)
    end
    return {
      glyph = c.icons.cpu or "cpu",
      text = text,
      tint = tintLevel(c.thresholds.cpu, s.cpu.usage),
    }
  end,

  ram = function(s, c)
    if s.ram == nil or s.ram.usage == nil then return nil end
    return {
      glyph = c.icons.ram or "database",
      text = format.pct(s.ram.usage),
      tint = tintLevel(c.thresholds.ram, s.ram.usage),
    }
  end,

  temp = function(s, c)
    if s.cpu == nil or s.cpu.temp == nil then return nil end
    return {
      glyph = c.icons.temp or "temperature",
      text = format.temp(s.cpu.temp, c.tempUnit, false),
      tint = tintLevel(c.thresholds.temp, s.cpu.temp),
    }
  end,

  gpu = function(s, c)
    if s.gpu == nil then return nil end
    if s.gpu.usage ~= nil then
      return {
        glyph = c.icons.gpu or "device-desktop-analytics",
        text = format.pct(s.gpu.usage),
        tint = tintLevel(c.thresholds.gpu, s.gpu.usage),
      }
    end
    if s.gpu.temp ~= nil then
      return {
        glyph = c.icons.gpu or "device-desktop-analytics",
        text = format.temp(s.gpu.temp, c.tempUnit, false),
        tint = tintLevel(c.thresholds.gpu, s.gpu.temp),
      }
    end
    return nil
  end,

  vram = function(s, c)
    if s.gpu == nil or s.gpu.vramUsed == nil or s.gpu.vramTotal == nil then return nil end
    if s.gpu.vramTotal <= 0 then return nil end
    local pct = s.gpu.vramUsed / s.gpu.vramTotal * 100
    return {
      glyph = c.icons.vram or "memory",
      text = format.ramBytes(s.gpu.vramUsed) .. " / " .. format.ramBytes(s.gpu.vramTotal),
      tint = tintLevel(c.thresholds.vram, pct),
    }
  end,

  fan = function(s, _c)
    if s.fanRpm == nil then return nil end
    return { glyph = c.icons.fan or "wind", text = format.rpm(s.fanRpm), tint = nil }
  end,

  battery = function(s, c)
    if s.battery == nil or s.battery.capacity == nil then return nil end
    local text = format.pct(s.battery.capacity)
    if c.showPowerDraw and s.battery.powerW then
      text = text .. " " .. format.watts(s.battery.powerW)
    end
    local charging = false
    if s.battery.status ~= nil and string.find(s.battery.status, "[Cc]harging") then
      charging = true
    end
    return {
      glyph = charging and "battery-charging" or "battery",
      text = text,
      tint = nil,
      charging = charging,
    }
  end,

  net = function(s, c)
    if s.net == nil or s.net.rx == nil then return nil end
    local text = "↓" .. format.netBytes(s.net.rx, c.netUnit) .. " ↑" .. format.netBytes(s.net.tx, c.netUnit)
    -- Thresholds are in MB/s.
    return {
      glyph = c.icons.net or "network",
      text = text,
      tint = tintLevel(c.thresholds.net, s.net.rx / 1000000),
    }
  end,

  disk = function(s, c)
    if s.diskIo == nil then return nil end
    local text = "↓" .. format.netBytes(s.diskIo.rx, c.netUnit) .. " ↑" .. format.netBytes(s.diskIo.tx, c.netUnit)
    if s.diskTempC then
      text = text .. " " .. format.temp(s.diskTempC, c.tempUnit, false)
    end
    return {
      glyph = c.icons.disk or "device-floppy",
      text = text,
      tint = tintLevel(c.thresholds.disk, s.diskTempC),
    }
  end,
}

-- One chip for a metric id, or nil when the metric is disabled or its
-- sensor is absent.
function M.chip(id, sample, config)
  if sample == nil or config == nil then return nil end
  if not config.enabled[id] then return nil end
  local builder = builders[id]
  if builder == nil then return nil end
  local chip = builder(sample, config)
  if chip == nil then return nil end
  chip.id = id
  return chip
end

-- Ordered, enabled chips for a sample. Absent sensors are skipped.
function M.chips(sample, config)
  local out = {}
  if sample == nil or config == nil then return out end
  for _, id in ipairs(config.metricOrder) do
    local chip = M.chip(id, sample, config)
    if chip then
      table.insert(out, chip)
    end
  end
  return out
end

-- Detailed tooltip rows: { key = ..., value = ... }.
function M.tooltipRows(sample, config)
  local rows = {}
  if sample == nil or config == nil then return rows end
  local function add(key, value)
    if value ~= nil and value ~= "" then
      table.insert(rows, { key = key, value = value })
    end
  end

  if sample.cpu and sample.cpu.usage ~= nil then
    local parts = { format.pct(sample.cpu.usage) }
    if sample.cpuFreqHz then table.insert(parts, format.freqHz(sample.cpuFreqHz)) end
    if sample.cpu.temp then table.insert(parts, format.temp(sample.cpu.temp, config.tempUnit, true)) end
    add("CPU", table.concat(parts, " · "))
  end

  if sample.ram then
    add("RAM", string.format("%s / %s (%s)",
      format.ramBytes(sample.ram.used), format.ramBytes(sample.ram.total), format.pct(sample.ram.usage)))
    if sample.swap and sample.swap.total and sample.swap.total > 0 then
      add("Swap", string.format("%s / %s",
        format.ramBytes(sample.swap.used), format.ramBytes(sample.swap.total)))
    end
  end

  if sample.gpu then
    local parts = {}
    if sample.gpu.usage ~= nil then table.insert(parts, format.pct(sample.gpu.usage)) end
    if sample.gpu.temp ~= nil then table.insert(parts, format.temp(sample.gpu.temp, config.tempUnit, true)) end
    if #parts > 0 then add("GPU", table.concat(parts, " · ")) end
  end

  if sample.gpu and sample.gpu.vramUsed ~= nil and sample.gpu.vramTotal ~= nil then
    add("VRAM", string.format("%s / %s (%s)",
      format.ramBytes(sample.gpu.vramUsed), format.ramBytes(sample.gpu.vramTotal),
      format.pct(sample.gpu.vramUsed / sample.gpu.vramTotal * 100)))
  end

  if sample.fanRpm then
    add("Fan", format.rpm(sample.fanRpm) .. " RPM")
  end

  if sample.battery and sample.battery.capacity ~= nil then
    local parts = { format.pct(sample.battery.capacity) }
    if sample.battery.status and sample.battery.status ~= "" then
      table.insert(parts, sample.battery.status)
    end
    if sample.battery.powerW then table.insert(parts, format.watts(sample.battery.powerW)) end
    add("Battery", table.concat(parts, " · "))
  end

  if sample.net and sample.net.rx ~= nil then
    local parts = { "↓ " .. format.netBytes(sample.net.rx, config.netUnit) .. "/s",
                    "↑ " .. format.netBytes(sample.net.tx, config.netUnit) .. "/s" }
    if config.showNetIp and sample.netIp then table.insert(parts, sample.netIp) end
    add("Network", table.concat(parts, " · "))
  end

  if sample.diskIo then
    local parts = { "↓ " .. format.netBytes(sample.diskIo.rx, config.netUnit) .. "/s",
                    "↑ " .. format.netBytes(sample.diskIo.tx, config.netUnit) .. "/s" }
    if sample.diskTempC then table.insert(parts, format.temp(sample.diskTempC, config.tempUnit, true)) end
    if sample.diskUsage and sample.diskUsage.usagePercent ~= nil then
      table.insert(parts, format.pct(sample.diskUsage.usagePercent) .. " used")
    end
    add("Disk", table.concat(parts, " · "))
  end

  if sample.load and #sample.load > 0 then
    local parts = {}
    for _, v in ipairs(sample.load) do table.insert(parts, format.load(v)) end
    add("Load", table.concat(parts, " · "))
  end

  return rows
end

return M
