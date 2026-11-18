--!nonstrict
-- Screen Toolkit — window picker [[panel]].
--
-- Click-to-choose for Annotate Window on compositors where slurp cannot run
-- (Umbriel: no click-to-pick, same deal as Niri). The service publishes the
-- window list through the "pickList" state channel, this panel renders one
-- row per window, and choosing publishes the window id back through
-- "pickChoice", which the service snaps and captures.

local wins = {}
local hoveredIdx = nil
local focusedIndex = 0
local panelOpen = false
local render

local function tr(key, subst)
  if subst then return noctalia.tr(key, subst) end
  return noctalia.tr(key)
end

local function refresh()
  local list = noctalia.state.get("pickList")
  wins = (type(list) == "table") and list or {}
  if focusedIndex == 0 and #wins > 0 then focusedIndex = 1 end
  if focusedIndex > #wins then focusedIndex = #wins end
end

local function choose(idx)
  local w = wins[idx]
  if not w or type(w.id) ~= "string" or w.id == "" then return end
  noctalia.state.set("pickChoice", w.id)
  panel.close()
end

local function header()
  return ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = "window", size = 16, color = "primary" }),
    ui.label({ text = tr("panel.pick_title"), flexGrow = 1, fontSize = 16, fontWeight = "bold", color = "on_surface" }),
    ui.button({ glyph = "close", width = 24, height = 24, glyphSize = 12, onClick = function() panel.close() end }),
  })
end

local function row(w, idx)
  local hot = (hoveredIdx == idx) or (focusedIndex == idx)
  return ui.row({
    key = "pick-" .. idx, gap = 8, align = "center",
    paddingV = 8, paddingH = 10, radius = 10,
    fill = hot and "primary/0.12" or "surface_container/0.25",
    border = hot and "primary" or "surface_container/0.25", borderWidth = 1,
    onClick = function() choose(idx) end,
    onHover = function(state)
      if state == "true" then hoveredIdx = idx elseif hoveredIdx == idx then hoveredIdx = nil end
      render()
    end,
  }, {
    ui.glyph({ name = "app-window", size = 18, color = hot and "primary" or "on_surface_variant" }),
    ui.column({ flexGrow = 1, gap = 0 }, {
      ui.label({ text = w.app or "?", fontSize = 13, fontWeight = "bold", color = hot and "primary" or "on_surface" }),
      ui.label({ text = w.title or "", fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    (w.focused and ui.glyph({ name = "check", size = 14, color = "primary" }) or ui.spacer({ width = 14 })),
  })
end

local function body()
  if #wins == 0 then
    return ui.column({ gap = 10, minHeight = 120, align = "center", justify = "center" }, {
      ui.glyph({ name = "window", size = 30, color = "outline_variant" }),
      ui.label({ text = tr("panel.pick_empty"), fontSize = 12, color = "on_surface_variant" }),
    })
  end
  local rows = {}
  for i, w in ipairs(wins) do rows[#rows + 1] = row(w, i) end
  return ui.column({ gap = 6 }, rows)
end

render = function()
  refresh()
  panel.render(ui.column({ gap = 10 }, {
    header(),
    body(),
  }))
end

function onOpen(_context)
  panelOpen, hoveredIdx, focusedIndex = true, nil, 0
  refresh()
  render()
end

function onClose()
  panelOpen, hoveredIdx = false, nil
end

noctalia.state.watch("pickList", function(v)
  wins = (type(v) == "table") and v or {}
  if focusedIndex == 0 and #wins > 0 then focusedIndex = 1 end
  if focusedIndex > #wins then focusedIndex = #wins end
  if panelOpen then render() end
end)

function onKey(chord, pressed)
  if not pressed then return end
  local key = tostring(chord):lower()
  if chord == "Escape" then panel.close() return end
  if #wins == 0 then return end
  if focusedIndex == 0 then focusedIndex = 1; render() return end
  if key == "tab" or key == "right" or key == "down" then
    focusedIndex = (focusedIndex % #wins) + 1
  elseif key == "backtab" or key == "left" or key == "up" then
    focusedIndex = (focusedIndex - 2) % #wins + 1
  elseif key == "return" or key == "enter" or key == "space" then
    choose(focusedIndex)
    return
  else
    return
  end
  render()
end
