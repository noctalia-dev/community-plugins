--!nonstrict
-- Service headless: memoriza la geometría MANUAL de las ventanas del plugin.
-- Solo escribe `brainGeometry` en store.json; el interruptor lo escribe el panel.
--
-- La consulta a hyprctl sigue la misma convención que el resto del plugin
-- (`lib/windows.luau`): `noctalia.runAsync` entrega al callback un único
-- `result` con `{ exitCode, stdout, stderr }`.
local storeLib = require("./lib/store.luau")
local outputLib = require("./lib/output.luau")
local brain = require("./lib/brain.luau")

local polling = false
local pending = {}

-- Los dos ajustes que necesita el service, leídos por clave como hace el panel
-- (`noctalia.getConfig` no tiene forma sin clave): el margen y el output son la
-- misma fuente de verdad que usa panel.luau, así que un desplazamiento guardado
-- por el service se reconstruye igual que uno guardado por el panel.
local function settings()
  return {
    margin = tonumber(noctalia.getConfig("margin")) or 0,
    output = tostring(noctalia.getConfig("output") or ""),
  }
end

local function imposedMap()
  local state = noctalia.state
  if state == nil then return {} end
  local ok, value = pcall(state.get, "imposed")
  if ok and type(value) == "table" then return value end
  return {}
end

function update()
  if polling then return end
  local stored = storeLib.loadBrain()
  if stored.brain ~= true then return end   -- cerebro OFF: cero trabajo, cero hyprctl
  polling = true
  local started = noctalia.runAsync({ "hyprctl", "clients", "-j" }, function(result)
    polling = false
    if result.exitCode ~= 0 or type(result.stdout) ~= "string" or result.stdout == "" then
      return
    end
    local decoded, clients = pcall(noctalia.json.decode, result.stdout)
    if not decoded or type(clients) ~= "table" then return end
    local cfg = settings()
    local box = outputLib.outputBox(cfg)
    local capture = brain.capture(clients, box, cfg.margin, stored.brainGeometry, imposedMap(), pending)
    pending = capture.pending
    if capture.changed then
      storeLib.saveBrainGeometry(capture.memory)
    end
  end)
  if not started then
    polling = false
  end
end

noctalia.setUpdateInterval(1000)