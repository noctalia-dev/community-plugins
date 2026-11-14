--!nonstrict
-- MochiType bar widget: shows today's best WPM.
-- Live updates come from the panel entry over noctalia.state; on startup the
-- widget falls back to the persisted stats file in the plugin data dir.

local WIDGET_KEY = "typer.todayBest"

local function readTodayBest()
  local dir = noctalia.pluginDataDir()
  if dir == nil then return nil end
  local raw = noctalia.readFile(dir .. "/stats.json")
  if raw == nil then return nil end
  local stats = noctalia.json.decode(raw)
  if type(stats) ~= "table" or type(stats.days) ~= "table" then return nil end
  local day = stats.days[os.date("%Y-%m-%d")]
  if type(day) ~= "table" or type(day.best) ~= "table" then return nil end
  local best = 0
  for _, v in pairs(day.best) do
    if type(v) == "number" and v > best then best = v end
  end
  return best > 0 and best or nil
end

function update()
  noctalia.setUpdateInterval(30000)

  local best = noctalia.state.get(WIDGET_KEY)
  if type(best) ~= "number" or best <= 0 then
    best = readTodayBest()
  end

  barWidget.setGlyph("keyboard")
  if best ~= nil then
    barWidget.setText(best .. " wpm")
    barWidget.setTooltip({ { key = "Best WPM today", value = tostring(best) } })
  else
    barWidget.setText("")
    barWidget.setTooltip("No tests today - open MochiType (/type)")
  end
end
