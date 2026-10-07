--!nonstrict
-- "Futurista" (11_futurista.conf) from Hyprland Visual Editor by XimoCP,
-- https://github.com/XimoCP/hyprland-visual-editor, ported to Luau for
-- Noctalia v5 by Hermy and linux-fertxo. The curves and timings below are
-- taken from it unchanged; this plugin only renamed the curves with an "hs_"
-- prefix and writes them through hl.curve/hl.animation. Kept as HVE applies
-- it: every leaf is reset to disabled first, then the preset enables its own.
--
-- MIT License
--
-- Copyright (c) 2026 XimoCP
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

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
