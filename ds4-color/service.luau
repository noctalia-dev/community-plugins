--!nonstrict
--!nocheck
--!nolint UnknownGlobal
-- Headless service: implements the DualShock 4 lightbar protocol in pure Lua.
-- No external binary needed — writes the HID output report to /dev/hidrawN.
local tr = noctalia.tr("ds4_color")

-- pluginDataDir() may return nil (state home unset), so resolve it lazily and
-- guard every use. Computing it at module top-level and concatenating would
-- throw on nil and kill the whole service entry (no onIpc -> IPC is a no-op).
local function persistentDir()
  local dir = noctalia.pluginDataDir()
  return dir
end

local function lastFile()
  local dir = persistentDir()
  if dir == nil then return nil end
  return dir .. "/last.json"
end

-- Sony DualShock 4 vendor / product IDs (from ps4-colors detect.c).
local SONY_VID = 0x054C
local KNOWN_PIDS = { [0x05C4] = true, [0x09CC] = true, [0x0BA0] = true }
local BUS_USB = 0x0003
local BUS_BT = 0x0005

-- Report protocol constants (from ps4-colors ds4.c / hid-playstation.c).
local DS4_USB_REPORT_ID = 0x05
local DS4_BT_REPORT_ID = 0x11
local DS4_USB_REPORT_LEN = 32
local DS4_BT_REPORT_LEN = 78
local DS4_USB_COMMON_OFFSET = 1
local DS4_BT_COMMON_OFFSET = 3
local DS4_OUTPUT_VALID_FLAG0_LED = 0x02
local DS4_BT_HW_CONTROL = 0xC4
local PS_OUTPUT_CRC32_SEED = 0xA2
local COMMON_LIGHTBAR_R = 5
local COMMON_LIGHTBAR_G = 6
local COMMON_LIGHTBAR_B = 7
local COMMON_VALID_FLAG0 = 0

-- Built-in presets. Deep crimson is the boss's favourite.
local PRESETS = {
  { name = "Crimson",  hex = "990000" },
  { name = "Red",      hex = "ff0000" },
  { name = "Green",    hex = "00ff00" },
  { name = "Blue",     hex = "0000ff" },
  { name = "Cyan",     hex = "00ffff" },
  { name = "Magenta",  hex = "ff00ff" },
  { name = "Yellow",   hex = "ffff00" },
  { name = "White",    hex = "ffffff" },
  { name = "Off",      hex = "000000" },
}

--==== bitwise helpers (math-only, Lua 5.x safe — no &/|/~/>>) ====
local function band(a, m)
  return a % (m + 1)
end
local function rshift(a, n)
  return math.floor(a / (2 ^ n))
end
local function bxor(a, b)
  local r = 0
  local pow = 1
  for _ = 1, 32 do
    local ab = a % 2
    local bb = b % 2
    if ab ~= bb then r = r + pow end -- ~= is Lua not-equal, fine
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    pow = pow * 2
  end
  return r
end
local function bnot32(a)
  return bxor(a, 0xFFFFFFFF)
end

--==== CRC32 (poly 0xEDB88320, reflected) ====
local crc32_table = nil
local function crc32_init()
  crc32_table = {}
  for i = 0, 255 do
    local crc = i
    for _ = 1, 8 do
      if band(crc, 1) ~= 0 then
        crc = bxor(rshift(crc, 1), 0xEDB88320)
      else
        crc = rshift(crc, 1)
      end
    end
    crc32_table[i] = crc
  end
end

local function crc32_le(crc, buf, len)
  if crc32_table == nil then crc32_init() end
  for i = 1, len do
    local b = string.byte(buf, i)
    crc = bxor(crc32_table[band(bxor(crc, b), 0xFF)], rshift(crc, 8))
  end
  return crc
end

--==== byte-string helpers ====
local function zeros(n)
  return string.rep("\0", n)
end

local function setbyte(s, idx, val)
  -- 1-indexed Lua string; idx is 0-based report offset
  return string.sub(s, 1, idx) .. string.char(band(val, 0xFF)) .. string.sub(s, idx + 2)
end

--==== report builders ====
local function buildUsbReport(r, g, b)
  local buf = "\5" .. zeros(DS4_USB_REPORT_LEN - 1) -- report_id 0x05, rest 0x00
  buf = setbyte(buf, DS4_USB_COMMON_OFFSET + COMMON_VALID_FLAG0, DS4_OUTPUT_VALID_FLAG0_LED)
  buf = setbyte(buf, DS4_USB_COMMON_OFFSET + COMMON_LIGHTBAR_R, r)
  buf = setbyte(buf, DS4_USB_COMMON_OFFSET + COMMON_LIGHTBAR_G, g)
  buf = setbyte(buf, DS4_USB_COMMON_OFFSET + COMMON_LIGHTBAR_B, b)
  return buf
end

local function buildBtReport(r, g, b)
  local buf = "\17\196\0" .. zeros(DS4_BT_REPORT_LEN - 3) -- 0x11, 0xC4, 0x00, rest 0x00
  buf = setbyte(buf, DS4_BT_COMMON_OFFSET + COMMON_VALID_FLAG0, DS4_OUTPUT_VALID_FLAG0_LED)
  buf = setbyte(buf, DS4_BT_COMMON_OFFSET + COMMON_LIGHTBAR_R, r)
  buf = setbyte(buf, DS4_BT_COMMON_OFFSET + COMMON_LIGHTBAR_G, g)
  buf = setbyte(buf, DS4_BT_COMMON_OFFSET + COMMON_LIGHTBAR_B, b)
  -- CRC32 over bytes 0..73 with seed 0xA2, stored at 74..77 (little-endian).
  local crc = crc32_le(0xFFFFFFFF, string.char(PS_OUTPUT_CRC32_SEED), 1)
  crc = band(bnot32(crc32_le(crc, buf, DS4_BT_REPORT_LEN - 4)), 0xFFFFFFFF)
  buf = setbyte(buf, 74, band(crc, 0xFF))
  buf = setbyte(buf, 75, band(rshift(crc, 8), 0xFF))
  buf = setbyte(buf, 76, band(rshift(crc, 16), 0xFF))
  buf = setbyte(buf, 77, band(rshift(crc, 24), 0xFF))
  return buf
end

--==== device detection (port of detect.c) ====
local function parseHidId(line)
  -- HID_ID=BBBB:VVVVVVVV:PPPPPPPP
  local bus, vendor, product = line:match("HID_ID=(%x+):(%x+):(%x+)")
  if bus == nil then return nil end
  return tonumber(bus, 16), band(tonumber(vendor, 16), 0xFFFF), band(tonumber(product, 16), 0xFFFF)
end

local function detectControllers()
  local out = {}
  local hidrawDir = noctalia.listDir("/sys/class/hidraw")
  if hidrawDir == nil then return out end
  for _, name in ipairs(hidrawDir) do
    if name:sub(1, 6) == "hidraw" then
      local ueventPath = "/sys/class/hidraw/" .. name .. "/device/uevent"
      local content = noctalia.readFile(ueventPath)
      if content ~= nil then
        local bus, vendor, product
        for line in content:gmatch("[^\n]+") do
          if line:sub(1, 7) == "HID_ID=" then
            bus, vendor, product = parseHidId(line)
            break
          end
        end
        if vendor == SONY_VID and KNOWN_PIDS[product] then
          table.insert(out, { path = "/dev/" .. name, bus_type = bus })
        end
      end
    end
  end
  return out
end

-- Write the report to the hidraw node. Noctalia's writeFile is file-oriented and
-- may not open a char device O_WRONLY. If the direct write fails we fall back to
-- python3 (declared in dependencies) which does a true binary O_WRONLY write.
local function setLightbar(dev, r, g, b)
  local report = (dev.bus_type == BUS_BT)
    and buildBtReport(r, g, b)
    or buildUsbReport(r, g, b)
  local hex = ""
  for i = 1, #report do
    hex = hex .. string.format("%02x", string.byte(report, i))
  end
  local ok, err = noctalia.writeFile(dev.path, report)
  if ok then return true, nil end
  -- Fallback: raw binary write via python3 (open(path,'wb').write(...)).
  local py = string.format(
    "python3 -c \"import sys; open('%s','wb').write(bytes.fromhex('%s'))\"",
    dev.path, hex)
  local done = noctalia.runAsync(py, function(res)
    if res == nil or res.exitCode ~= 0 then
      noctalia.notifyError(tr, noctalia.tr("write_error") .. " (" .. dev.path .. ")")
    end
  end)
  return done, err
end

local function loadLast()
  local path = lastFile()
  if path == nil then return "990000" end
  local raw = noctalia.readFile(path)
  if raw == nil or raw == "" then return "990000" end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" or type(decoded.hex) ~= "string" then return "990000" end
  return decoded.hex
end

local function saveLast(hex)
  local path = lastFile()
  if path == nil then return end
  noctalia.mkdirAll(persistentDir())
  local encoded = noctalia.json.encode({ hex = hex })
  if encoded ~= nil then noctalia.writeFile(path, encoded) end
end

local function hexToRgb(hex)
  return tonumber(hex:sub(1, 2), 16) or 0,
         tonumber(hex:sub(3, 4), 16) or 0,
         tonumber(hex:sub(5, 6), 16) or 0
end

-- Apply a hex color to every connected DS4.
local function apply(hex)
  if hex == nil or hex == "" then return end
  local r, g, b = hexToRgb(hex)
  local devs = detectControllers()
  if #devs == 0 then
    noctalia.notifyError(tr, noctalia.tr("no_controller"))
    return
  end
  local ok = 0
  for _, dev in ipairs(devs) do
    local good, err = setLightbar(dev, r, g, b)
    if good then
      ok = ok + 1
    else
      noctalia.notifyError(tr, noctalia.tr("write_error") .. " (" .. dev.path .. ")")
    end
  end
  if ok > 0 then
    saveLast(hex)
    noctalia.state.set("lastColor", hex)
    noctalia.notify(tr, noctalia.tr("applied", { color = hex }))
  end
end

-- Persist the chosen color WITHOUT touching the controller.
local function save(hex)
  if hex == nil or hex == "" then return end
  saveLast(hex)
  noctalia.state.set("lastColor", hex)
  noctalia.notify(tr, noctalia.tr("saved", { color = hex }))
end

function onIpc(event, payload)
  if event == "apply" and payload ~= nil then
    apply(payload:match("^#?(%x%x%x%x%x%x)$") or payload:match("^0x(%x%x%x%x%x%x)$") or "")
  elseif event == "save" and payload ~= nil then
    save(payload:match("^#?(%x%x%x%x%x%x)$") or payload:match("^0x(%x%x%x%x%x%x)$") or "")
  elseif event == "get-presets" then
    noctalia.state.set("presets", PRESETS)
  end
end

function load()
  noctalia.state.set("lastColor", loadLast())
  noctalia.state.set("presets", PRESETS)
end

load()
