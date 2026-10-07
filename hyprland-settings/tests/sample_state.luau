-- A saved state shaped like a real laptop + external monitor setup, with the
-- Futurista preset and a rule for a TV that is not plugged in.
return {
  options = {
    ["general.border_size"] = { value = 2 },
    ["general.gaps_in"] = { value = 5 },
    ["general.gaps_out"] = { value = 20 },
    ["decoration.rounding"] = { value = 10 },
    ["decoration.active_opacity"] = { value = 1 },
    ["decoration.inactive_opacity"] = { value = 1 },
    ["decoration.blur.enabled"] = { value = true },
    ["decoration.blur.size"] = { value = 4, why = "size times passes is the GPU cost on the iGPU" },
    ["decoration.blur.passes"] = { value = 2 },
    ["decoration.shadow.enabled"] = { value = true },
    ["decoration.shadow.range"] = { value = 4 },
    ["decoration.shadow.render_power"] = { value = 3 },
    ["animations.enabled"] = { value = true },
    ["xwayland.force_zero_scaling"] = { value = true },
    ["input.kb_layout"] = { value = "de" },
    ["input.follow_mouse"] = { value = 1 },
    ["input.touchpad.natural_scroll"] = { value = false },
  },
  preset = { name = "futurista" },
  monitors = {
    { output = "eDP-1", mode = "preferred", position = "0x0", scale = 1.6 },
    { output = "desc:AOC 24G1WG4", mode = "1920x1080@144", position = "1600x0", scale = 1,
      why = "can do 144 Hz, Hyprland picks 60 without a rule" },
    { output = "desc:United Microelectr Corporation UMC SHARP", mode = "3840x2160@60", position = "1600x0", scale = 2,
      why = "4K@30 without a rule; by device, not port: the AOC uses the same HDMI-A-1" },
  },
}
