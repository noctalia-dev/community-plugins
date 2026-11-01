--!nonstrict
-- Stasis — widget de barra.
--
-- Cada `interval` segundos ejecuta `stasis info --json` (de forma asíncrona,
-- fuera del hilo de UI) y traduce el campo "class" a un glifo. El color del
-- glifo es el de icono por defecto de Noctalia (respeta el color de icono
-- configurado para el widget). El tooltip es el texto que devuelve Stasis.

local function cfg(key, default)
  local value = noctalia.getConfig(key)
  if value == nil then
    return default
  end
  return value
end

local glyphs = {
  active              = cfg("glyph_active", "coffee"),
  idle_active         = cfg("glyph_active", "coffee"),
  idle_waiting        = cfg("glyph_idle_waiting", "hourglass"),
  manually_inhibited  = cfg("glyph_manually_inhibited", "hand-stop"),
  idle_inhibited      = cfg("glyph_idle_inhibited", "player-pause"),
  not_running         = cfg("glyph_not_running", "moon"),
}
local unknownGlyph = cfg("glyph_unknown", "question-mark")

local showTooltip = cfg("show_tooltip", true) == true
local busy = false

local function render(class, tooltipText)
  barWidget.setGlyph(glyphs[class] or unknownGlyph)
  -- "on_surface" en modo por defecto respeta el color de icono configurado
  -- para el widget: el color por defecto de los iconos de Noctalia.
  barWidget.setGlyphColor("on_surface")
  barWidget.setText("")
  if showTooltip and tooltipText ~= nil and tooltipText ~= "" then
    barWidget.setTooltip(tooltipText)
  else
    barWidget.clearTooltip()
  end
end

local function poll()
  if busy then
    return
  end
  busy = true
  noctalia.runAsync("stasis info --json", function(res)
    busy = false
    if res == nil or res.exitCode ~= 0 then
      render("not_running", noctalia.tr("status.not_running"))
      return
    end
    local data = noctalia.json.decode(res.stdout)
    if type(data) ~= "table" then
      render("unknown", noctalia.tr("status.unparsed"))
      return
    end
    render(data.class or "unknown", data.tooltip)
  end)
end

function update()
  noctalia.setUpdateInterval(cfg("interval", 2) * 1000)
  poll()
end

noctalia.setUpdateInterval(cfg("interval", 2) * 1000)
poll()
