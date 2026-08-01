local layouts = {
	T  = { name = "tile",             label = "Tile",              glyph = "layout-sidebar" },
	S  = { name = "scroller",         label = "Scroller",          glyph = "carousel-horizontal" },
	M  = { name = "monocle",          label = "Monocle",           glyph = "square" },
	G  = { name = "grid",             label = "Grid",              glyph = "layout-grid" },
	F  = { name = "fair",             label = "Fair",              glyph = "layout-board-split" },
	D  = { name = "deck",             label = "Deck",              glyph = "layers-difference" },
	DW = { name = "dwindle",          label = "Dwindle",           glyph = "layout-2" },
	CT = { name = "center_tile",      label = "Center Tile",       glyph = "layout-distribute-vertical" },
	VT = { name = "vertical_tile",    label = "Vertical Tile",     glyph = "layout-rows" },
	RT = { name = "right_tile",       label = "Right Tile",        glyph = "layout-sidebar-right" },
	VS = { name = "vertical_scroller",label = "Vertical Scroller", glyph = "carousel-vertical" },
	VG = { name = "vertical_grid",    label = "Vertical Grid",     glyph = "grid-dots" },
	VD = { name = "vertical_deck",    label = "Vertical Deck",     glyph = "chart-funnel" },
	VF = { name = "vertical_fair",    label = "Vertical Fair",     glyph = "layout-board" },
}

local show_glyph_raw = noctalia.getConfig("show_glyph")
local show_glyph = (show_glyph_raw == true) or (show_glyph_raw == "true") or (show_glyph_raw == nil)

local show_text_raw = noctalia.getConfig("show_text")
local show_text = (show_text_raw == true) or (show_text_raw == "true")

local custom_color = noctalia.getConfig("custom_color")

function update()
  noctalia.setUpdateInterval(500)
  noctalia.runAsync(
    "mmsg get all-monitors | jq -r '.monitors[] | select(.active == true) | .layout_symbol'",
    function(result)
      if result and result.exitCode == 0 then
        local sym = result.stdout:gsub("%s+", "")
        local current = layouts[sym]
        
        if current then
            if show_glyph then 
                barWidget.setGlyph(current.glyph)
            else
                -- Remove the glyph by passing nil (or just setting text if the API prefers it)
                pcall(function() barWidget.setGlyph(nil) end)
            end
            
            if show_text then 
                barWidget.setText(current.label) 
            else 
                barWidget.setText("") 
            end
            
            if custom_color and custom_color ~= "" then 
                -- Attempt to apply the color using different possible methods in v5
                pcall(function() barWidget.setColor(custom_color) end)
                pcall(function() barWidget.setForeground(custom_color) end)
            end
        else
            if show_glyph then 
                barWidget.setGlyph("layout") 
            else 
                pcall(function() barWidget.setGlyph(nil) end)
            end
            
            if show_text then 
                barWidget.setText("Layout") 
            else 
                barWidget.setText("") 
            end
        end
      end
    end
  )
end

function onClick()
  noctalia.togglePanel("ezequiel/mango_layouts:panel")
end
