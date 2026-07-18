--!nonstrict
--!nocheck
--!nolint UnknownGlobal
-- Headless service: owns the ps4-colors call + persists the last chosen color.
local tr = noctalia.tr("ps4_colors")
local PERSISTENT_DIR = noctalia.pluginDataDir()
local LAST_FILE = PERSISTENT_DIR .. "/last.json"

-- Built-in presets (name -> RRGGBB). Deep crimson is the boss's favourite.
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

local function loadLast()
  local raw = noctalia.readFile(LAST_FILE)
  if raw == nil or raw == "" then return "990000" end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" or type(decoded.hex) ~= "string" then return "990000" end
  return decoded.hex
end

local function saveLast(hex)
  noctalia.mkdirAll(PERSISTENT_DIR)
  local encoded = noctalia.json.encode({ hex = hex })
  if encoded ~= nil then noctalia.writeFile(LAST_FILE, encoded) end
end

-- Apply a hex color (RRGGBB, no #) to every connected DS4.
local function apply(hex)
  if hex == nil or hex == "" then return end
  if not noctalia.commandExists("ps4-colors") then
    noctalia.notifyError(tr, noctalia.tr("ps4_colors_missing"))
    return
  end
  noctalia.runAsync("ps4-colors " .. hex, function(result)
    if result.exitCode == 0 then
      saveLast(hex)
      noctalia.state.set("lastColor", hex)
      noctalia.notify(tr, noctalia.tr("applied", { color = hex }))
    elseif result.exitCode == 1 then
      noctalia.notifyError(tr, noctalia.tr("bad_color"))
    elseif result.exitCode == 2 then
      noctalia.notifyError(tr, noctalia.tr("no_controller"))
    else
      noctalia.notifyError(tr, noctalia.tr("write_error"))
    end
  end)
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
