--!nonstrict
-- HVE v5 — Background Service (cachés JSON + dofile en hyprland.lua)

local home = noctalia.getenv("HOME") or "/home/fertxo"
local pdir = noctalia.pluginDir() or (home .. "/.config/noctalia/plugins/hyprland-visual-editor")
local cachedir = (noctalia.getenv("XDG_CACHE_HOME") or (home .. "/.cache")) .. "/noctalia/HVE"

local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- 1. Generar cachés JSON (fire-and-forget)
noctalia.runAsync("mkdir -p " .. shq(cachedir), nil, 5000)
for _, cat in ipairs({"animations", "borders", "shaders"}) do
  noctalia.runAsync("bash " .. shq(pdir .. "/assets/scripts/scan.sh") .. " " .. shq(cat) .. " > " .. shq(cachedir .. "/" .. cat .. ".json"), nil, 30000)
end

-- 2. Asegurar el dofile en hyprland.lua (idempotente, por marcador)
local hyprlandLua = home .. "/.config/hypr/hyprland.lua"
local content = noctalia.readFile(hyprlandLua)
if content and not content:find("HVE/overlay.lua", 1, true) then
  local block = "\n\n-- >>> HYPRLAND VISUAL EDITOR (HVE) <<<\n"
    .. "pcall(function() dofile(os.getenv(\"HOME\") .. \"/.cache/noctalia/HVE/overlay.lua\") end)\n"
    .. "-- <<< HYPRLAND VISUAL EDITOR (HVE) <<<\n"
  noctalia.writeFile(hyprlandLua, content .. block)
end
