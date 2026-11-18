--!nonstrict

local SNAPSHOT = "fan.snapshot"
local COMMAND = "fan.command"

local snap = noctalia.state.get(SNAPSHOT) or { rpm = 0, level = "auto", temp = 0, available = false }
local reqId = 0

local function dispatch(level)
  reqId += 1
  noctalia.state.set(COMMAND, {
    action = "set_level",
    value = level,
    requestId = tostring(os.time()) .. "-" .. tostring(reqId),
  })
end

-- variant: current level highlighted; "0" (fans off) flagged as destructive.
local function levelButton(level, label, handler)
  local variant = "ghost"
  if snap.level == level then
    variant = (level == "0") and "destructive" or "primary"
  end
  return ui.button({ text = label, variant = variant, onClick = handler, flexGrow = 1 })
end

local function render()
  panel.render(ui.column({ gap = 8, padding = 10 }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "car-fan", color = "primary" }),
      ui.label({ text = noctalia.tr("panel.title"), fontWeight = "bold", flexGrow = 1 }),
      ui.label({ text = (snap.rpm or 0) .. " RPM · " .. (snap.temp or 0) .. " °C", fontSize = 12, color = "on_surface_variant" }),
    }),
    ui.row({ gap = 6 }, {
      levelButton("auto", noctalia.tr("panel.auto"), "onFanAuto"),
      levelButton("disengaged", noctalia.tr("panel.full"), "onFanFull"),
    }),
    ui.row({ gap = 6 }, {
      levelButton("0", "0", "onFan0"),
      levelButton("1", "1", "onFan1"),
      levelButton("2", "2", "onFan2"),
      levelButton("3", "3", "onFan3"),
    }),
    ui.row({ gap = 6 }, {
      levelButton("4", "4", "onFan4"),
      levelButton("5", "5", "onFan5"),
      levelButton("6", "6", "onFan6"),
      levelButton("7", "7", "onFan7"),
    }),
  }))
end

function onOpen(_context)
  snap = noctalia.state.get(SNAPSHOT) or snap
  render()
end

noctalia.state.watch(SNAPSHOT, function(value)
  if type(value) == "table" then
    snap = value
    render()
  end
end)

function onFanAuto() dispatch("auto") end
function onFanFull() dispatch("disengaged") end
function onFan0() dispatch("0") end
function onFan1() dispatch("1") end
function onFan2() dispatch("2") end
function onFan3() dispatch("3") end
function onFan4() dispatch("4") end
function onFan5() dispatch("5") end
function onFan6() dispatch("6") end
function onFan7() dispatch("7") end
