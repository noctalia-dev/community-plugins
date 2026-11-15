--!nonstrict
-- Helpers shared by the widget and the panel (loaded with require).

local shared = {}

-- Commands carry a nonce so that the service runs each one once. Every entry
-- is its own VM, so a per-entry counter would collide: time plus a random
-- part is unique across them.
function shared.sendCmd(action, extra)
  local cmd = { n = `{noctalia.nowMs()}-{math.random(1, 1000000000)}`, action = action }
  if extra then
    for key, value in extra do
      cmd[key] = value
    end
  end
  noctalia.state.set("usbm.cmd", noctalia.json.encode(cmd))
end

function shared.snapshot()
  local encoded = noctalia.state.get("usbm.snapshot")
  return encoded and noctalia.json.decode(encoded) or nil
end

-- Decimal units, as drives are sold and as file managers show them.
function shared.formatBytes(bytes)
  bytes = tonumber(bytes) or 0
  local units = { "B", "kB", "MB", "GB", "TB", "PB" }
  local index = 1
  while bytes >= 1000 and index < #units do
    bytes /= 1000
    index += 1
  end
  if index == 1 then
    return `{math.floor(bytes)} B`
  end
  local digits = bytes < 10 and 1 or 0
  return string.format(`%.{digits}f %s`, bytes, units[index])
end

-- USB link speed in Mbit/s as the kernel reports it, to a marketing name.
function shared.usbSpeed(usb)
  if usb == nil or (usb.speed or 0) == 0 then
    return nil
  end
  local speed = usb.speed
  if speed >= 20000 then
    return "USB 3.2 · 20 Gbps"
  elseif speed >= 10000 then
    return "USB 3.2 · 10 Gbps"
  elseif speed >= 5000 then
    return "USB 3 · 5 Gbps"
  elseif speed >= 480 then
    return "USB 2 · 480 Mbps"
  end
  return `USB 1 · {speed} Mbps`
end

function shared.driveGlyph(drive)
  if drive.bus == "sd" then
    return "device-sd-card"
  elseif drive.bus == "optical" then
    return "disc"
  end
  return "usb"
end

function shared.volumeName(volume)
  local label = volume.label ~= "" and volume.label or (volume.clear and volume.clear.label or "")
  if label ~= "" then
    return label
  end
  return nil
end

function shared.mountedCount(drives)
  local mounted = 0
  for _, drive in drives do
    for _, volume in drive.volumes do
      if volume.mountPoint then
        mounted += 1
      end
    end
  end
  return mounted
end

return shared
