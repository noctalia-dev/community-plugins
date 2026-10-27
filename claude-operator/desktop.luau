--!nonstrict
-- Desktop widget: the switchboard on the wallpaper, for a second monitor. A large
-- nested gauge with each window's outlook beside it, then the numbered lines (click one
-- to jump to its terminal) and the most urgent thing on the board. Renders published
-- state only; no keyboard and no scrolling on a desktop widget, so it shows the first
-- five lines.
local shared = require("./shared.luau")
local kit = require("./kit.luau")
local gauge = require("./gauge.luau")

local S = {}
for _, k in ipairs({ "sessions", "accounts", "elsewhere" }) do S[k] = noctalia.state.get(k) or {} end

local MAX_LINES = 5
local LAMP = { waiting = "error", busy = "primary", idle = "on_surface_variant/0.5" }
local WORD = { waiting = "needs you", busy = "working", idle = "idle" }

local function limitsBlock()
  local limits = S.accounts[1] and S.accounts[1].limits
  local windows = gauge.pick(limits, "all")
  if #windows == 0 then return nil end
  local rings, rows = {}, {}
  for i, w in ipairs(windows) do
    local p = shared.pace(w)
    local color = shared.paceColor(p.status, "primary")
    rings[i] = { percent = w.percent, projected = p.projected, role = color }
    rows[#rows + 1] = ui.row({ gap = 6, align = "center" }, {
      ui.column({ width = 56 }, { ui.label({ text = w.label, fontSize = 11, fontWeight = "bold" }) }),
      ui.label({ text = `{shared.round(w.percent)}%`, fontSize = 13, fontWeight = "bold", color = color }),
      kit.muted(shared.paceShort(w, p), 11, { maxLines = 1 }),
    })
  end
  return ui.row({ gap = 14, align = "center", opacity = limits.stale and 0.5 or 1 }, {
    ui.image({ path = gauge.image(rings), width = 72, height = 72 }),
    ui.column({ gap = 6 }, rows),
  })
end

local function lines()
  local rows = {}
  local blinkOff = os.time() % 2 == 1
  for i, s in ipairs(S.sessions) do
    if i > MAX_LINES then
      rows[#rows + 1] = kit.muted(`+{#S.sessions - MAX_LINES} more`, 10)
      break
    end
    local d = s.d or {}
    rows[#rows + 1] = ui.row({ key = "line-" .. s.pid, gap = 8, align = "center", paddingV = 2,
      onClick = function() shared.focus(s) end }, {
      ui.column({ width = 20 }, { ui.label({ text = `L{i}`, fontSize = 10, fontWeight = "bold", color = "on_surface_variant" }) }),
      ui.box({ width = 8, height = 8, radius = 2, fill = LAMP[s.status] or LAMP.idle,
        opacity = s.status == "waiting" and blinkOff and 0.25 or 1 }),
      ui.label({ text = d.title or s.name, fontSize = 12, maxLines = 1, flexGrow = 1 }),
      kit.muted(WORD[s.status] or "idle", 10),
    })
  end
  return rows
end

local function render()
  local status, color, glyph = kit.statusLine(S, shared)
  local body = {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "headset", size = 14, color = "primary" }),
      ui.label({ text = "CLAUDE OPERATOR", fontSize = 10, fontWeight = "bold", color = "on_surface_variant" }),
    }),
  }
  local limits = limitsBlock()
  if limits then body[#body + 1] = limits end
  for _, r in ipairs(lines()) do body[#body + 1] = r end
  body[#body + 1] = ui.row({ gap = 5, align = "center" }, {
    ui.glyph({ name = glyph, size = 11, color = color }),
    ui.label({ text = status, fontSize = 11, color = color, maxLines = 1, flexGrow = 1 }),
  })
  desktopWidget.render(ui.column({ gap = 8, padding = 14, radius = 14, fill = "surface/0.85", width = 340 }, body))
end

for _, k in ipairs({ "sessions", "accounts", "elsewhere" }) do
  noctalia.state.watch(k, function(v) S[k] = v or {}; render() end)
end
-- Second ticks: the blinking lamp and the clock-driven outlooks.
desktopWidget.setWantsSecondTicks(true)
function update() render() end
render()
