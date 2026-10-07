--!nonstrict
-- "Futurista" from Hyprland Visual Editor (11_futurista.conf), MIT,
-- XimoCP, Hermy & linux-fertxo. Kept as HVE applies it: every leaf is reset
-- to disabled first, then the preset enables its own. Curves are prefixed
-- "hs_" so they cannot clash with curves defined elsewhere.

return {
  name = "futurista",
  curves = {
    { name = "hs_holo", points = { { 0.23, 1 }, { 0.32, 1 } } },
    { name = "hs_data", points = { { 0.16, 1 }, { 0.3, 1 } } },
  },
  reset = {
    "windowsIn", "windowsOut", "windowsMove", "fade", "fadeIn", "fadeOut",
    "fadeLayersIn", "fadeLayersOut", "layers", "layersIn", "layersOut",
    "workspaces", "specialWorkspace", "borderangle", "border", "global",
  },
  animations = {
    { leaf = "windowsIn", speed = 5, bezier = "hs_holo", style = "slide" },
    { leaf = "windowsOut", speed = 4, bezier = "hs_holo", style = "popin 100%" },
    { leaf = "windowsMove", speed = 5, bezier = "hs_holo", style = "slide" },
    { leaf = "fade", speed = 5, bezier = "hs_data" },
    { leaf = "layers", speed = 5, bezier = "hs_holo", style = "fade" },
    { leaf = "workspaces", speed = 6, bezier = "hs_holo", style = "slide" },
    { leaf = "specialWorkspace", speed = 6, bezier = "hs_holo", style = "slide" },
  },
}
