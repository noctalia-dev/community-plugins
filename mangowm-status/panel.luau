--!nonstrict
-- Mangowm Status — Layout Picker Panel
-- Shows all available tiling layouts; click one to switch immediately.

-- Layout manifest: glyph + letter + name (same as widget.luau)
local layoutConfig = {
  T  = { glyph = "columns",   letter = "T", name = "tile" },
  S  = { glyph = "menu",      letter = "S", name = "scroller" },
  G  = { glyph = "dashboard", letter = "G", name = "grid" },
  M  = { glyph = "window",    letter = "M", name = "monocle" },
  K  = { glyph = "cards",     letter = "K", name = "deck" },
  CT = { glyph = "layout",    letter = "C", name = "center_tile" },
  RT = { glyph = "columns",   letter = "R", name = "right_tile" },
  VS = { glyph = "menu",      letter = "V", name = "vertical_scroller" },
  VT = { glyph = "columns",   letter = "V", name = "vertical_tile" },
  VG = { glyph = "dashboard", letter = "G", name = "vertical_grid" },
  VK = { glyph = "cards",     letter = "K", name = "vertical_deck" },
  DW = { glyph = "columns",   letter = "D", name = "dwindle" },
  F  = { glyph = "layout",    letter = "F", name = "fair" },
  VF = { glyph = "layout",    letter = "F", name = "vertical_fair" },
}

-- Layout codes in display order
local layoutOrder = { "T", "S", "G", "M", "K", "CT", "RT", "DW", "F", "VS", "VT", "VG", "VK", "VF" }

local currentLayoutCode = "T"
local switching = false

-- Forward-declared so setLayout's failure path can re-render the panel
-- (doRender is defined after setLayout below).
local doRender

-- Helper to switch layout and close panel
local function setLayout(code)
  if switching or code == currentLayoutCode then return end
  switching = true

  local cfg = layoutConfig[code]
  local name = cfg and cfg.name or "tile"
  noctalia.runAsync("mmsg dispatch setlayout," .. name, function(result)
    switching = false
    if result.exitCode == 0 then
      currentLayoutCode = code
      panel.close()
    else
      noctalia.notifyError("Mangowm Status", "Failed to set layout: " .. (result.stderr or "unknown error"))
      doRender()
    end
  end)
end

-- Named global functions for each layout button (onClick doesn't pass arguments)
function onLayoutT()  setLayout("T")  end
function onLayoutS()  setLayout("S")  end
function onLayoutG()  setLayout("G")  end
function onLayoutM()  setLayout("M")  end
function onLayoutK()  setLayout("K")  end
function onLayoutCT() setLayout("CT") end
function onLayoutRT() setLayout("RT") end
function onLayoutDW() setLayout("DW") end
function onLayoutF()  setLayout("F")  end
function onLayoutVS() setLayout("VS") end
function onLayoutVT() setLayout("VT") end
function onLayoutVG() setLayout("VG") end
function onLayoutVK() setLayout("VK") end
function onLayoutVF() setLayout("VF") end

function doRender()
  -- Map layout code -> onClick handler name
  local onClickHandler = {
    T  = "onLayoutT",  S  = "onLayoutS",  G  = "onLayoutG",
    M  = "onLayoutM",  K  = "onLayoutK",  CT = "onLayoutCT",
    RT = "onLayoutRT", DW = "onLayoutDW", F  = "onLayoutF",
    VS = "onLayoutVS", VT = "onLayoutVT", VG = "onLayoutVG",
    VK = "onLayoutVK", VF = "onLayoutVF",
  }

  -- Current layout indicator (compact, shown at top)
  local currentCfg = layoutConfig[currentLayoutCode] or layoutConfig["T"]
  local currentBadge = ui.row({ gap = 6, align = "center", fill = "primary/0.12", radius = 6, paddingH = 10, paddingV = 5 }, {
    ui.label({ text = "Now:", color = "on_surface_variant", fontSize = 11 }),
    ui.glyph({ name = currentCfg.glyph, size = 12, color = "primary" }),
    ui.label({ text = currentCfg.letter .. " — " .. currentCfg.name, color = "primary", fontWeight = "bold", fontSize = 11 }),
  })

  -- Build layout buttons
  local buttons = {}
  for _, code in ipairs(layoutOrder) do
    local cfg = layoutConfig[code]
    if cfg then
      local isActive = code == currentLayoutCode
      table.insert(buttons, ui.button({
        key = "layout-" .. code,
        glyph = cfg.glyph,
        glyphSize = 14,
        text = " " .. cfg.letter .. "  —  " .. cfg.name,
        contentAlign = "start",
        variant = isActive and "primary" or "ghost",
        controlSize = "sm",
        onClick = onClickHandler[code],
      }))
    end
  end

  panel.render(ui.column({ flexGrow = 1, gap = 2, padding = 8 }, {
    currentBadge,
    ui.separator({ thickness = 1, color = "outline/0.15", spacing = 3 }),
    ui.scroll({ flexGrow = 1, gap = 2 }, buttons),
  }))
end

-- Fetch current layout from mmsg, then render
local function refreshCurrentLayout()
  noctalia.runAsync("mmsg get all-tags", function(result)
    if result.exitCode == 0 and result.stdout then
      local ok, data = pcall(noctalia.json.decode, result.stdout)
      if ok and data and data.all_tags then
        for _, monitorEntry in ipairs(data.all_tags) do
          if type(monitorEntry) == "table" and monitorEntry.tags then
            for _, tag in ipairs(monitorEntry.tags) do
              if type(tag) == "table" and tag.is_active and tag.layout then
                currentLayoutCode = tag.layout
                doRender()
                return
              end
            end
          end
        end
      end
    end
    -- Render even if fetch failed (uses fallback currentLayoutCode)
    doRender()
  end)
end

function onOpen(_context)
  -- Fetch current layout first, then render (avoids flash of wrong layout)
  refreshCurrentLayout()
end
