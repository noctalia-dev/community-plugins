local function section(title, control)
  return ui.column({ gap = 8 }, {
    ui.label({ text = title, fontWeight = "medium", color = "on_surface_variant" }),
    control,
  })
end



local used_vm = panel.getConfig("vm")
local Transform_order_string = panel.getConfig("transform-order")
local Transform_order = {}
local index = 0
for i in string.gmatch(Transform_order_string, "%d+") do
   -- print the substring
   Transform_order[index] = i
   index += 1
end


local function render()
  -- The panel surface already insets its content (Style::panelPadding), so this
  -- adds gaps between rows, not its own outer padding.
  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    -- Header: title on the left, close button pinned to the top right —
    -- matching the built-in panels (no divider rule).
    ui.row({ align = "center", justify = "space_between", gap = 12 }, {
      ui.label({ text = "iio-lock", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    }),

    -- Body: a scrollable stack of settings.
    section("", ui.column({ gap = 12, align = "center" }, {
        ui.button({width = 60 , height=100, onClick = "onUp",glyph="arrow-big-up-filled",glyphSize=50}),
        section("", ui.row({ gap = 12, align = "center" }, {
            ui.button({width = 100 , height=60, onClick = "onLeft",glyph="arrow-big-left-filled",glyphSize=50}),
            ui.button({width = 100 , height=60, onClick = "onLock",glyph="lock",glyphSize=50}),
             ui.button({width = 100 , height=60, onClick = "onRight",glyph="arrow-big-right-filled",glyphSize=50})
        })),
        ui.button({width = 60 , height=100, onClick = "onDown",glyph="arrow-big-down-filled",glyphSize=50}),

    })),


  }))
end

function onOpen(_context)
  render()
end

function onLock()
    locked = noctalia.state.get("iio-state")
    noctalia.state.set("iio-state",not locked)
      panel.close()
end

function hl(value,screen)

    if not screen then
        screen = "eDP-1"
    end
    local cmd = string.format([[hyprctl eval 'hl.monitor({ output = "%s", transform = %d })']], screen, value)
    noctalia.runAsync(cmd, function(result)
    end)
    cmd = string.format([[hyprctl eval 'hl.config({input = {touchdevice = { transform = %d },tablet= { transform = %d }}})']],value,value)
    noctalia.runAsync(cmd, function(result)
    end)
    cmd = string.format([[hyprctl eval 'hl.workspace_rule({workspace = "m[%s]"})']],screen)
    noctalia.runAsync(cmd, function(result)
    end)
end

function sw(value,screen)
if not screen then
        screen = "eDP-1"
    end
    local cmd = string.format("swaymsg \"output %s transform %d\"",screen,value)
    noctalia.runAsync(cmd, function(result)
end)
end

wm = {
    hyprland = hl,
    sway = sw,
}

function onLeft()
    wm[used_vm](Transform_order[1])
    noctalia.state.set("iio-state",true)
    panel.close()
end
function onRight()
    wm[used_vm](Transform_order[3])
    noctalia.state.set("iio-state",true)
    panel.close()
end
function onUp()
    wm[used_vm](Transform_order[0])
    noctalia.state.set("iio-state",true)
    panel.close()
end
function onDown()
    wm[used_vm](Transform_order[2])
    noctalia.state.set("iio-state",true)
    panel.close()
end

function onCloseClicked()
  panel.close()
end