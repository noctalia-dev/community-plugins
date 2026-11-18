--!nonstrict
-- The curated v1 options. Paths are Hyprland 0.56 Lua paths, checked against
-- /usr/share/hypr/stubs/hl.meta.lua; min/max come from `hyprctl descriptions -j`.
-- The getoption name is the path with ":" instead of ".".
--
-- unit: shown next to the value in the panel.
-- kind: int | float | bool | string | choice (fixed strings) | enum (int with
-- named values) | gaps (css gap: one number or top/right/bottom/left)

local options = {
  -- Appearance
  { page = "appearance", group = "gaps", path = "general.gaps_in", kind = "gaps", min = 0, max = 50, unit = "px" },
  { page = "appearance", group = "gaps", path = "general.gaps_out", kind = "gaps", min = 0, max = 100, unit = "px" },
  { page = "appearance", group = "gaps", path = "general.border_size", kind = "int", min = 0, max = 20, unit = "px" },
  { page = "appearance", group = "gaps", path = "general.resize_on_border", kind = "bool" },
  { page = "appearance", group = "corners", path = "decoration.rounding", kind = "int", min = 0, max = 20, unit = "px" },
  { page = "appearance", group = "corners", path = "decoration.rounding_power", kind = "float", min = 2, max = 10, step = 0.1 },
  { page = "appearance", group = "opacity", path = "decoration.active_opacity", kind = "float", min = 0, max = 1, step = 0.01 },
  { page = "appearance", group = "opacity", path = "decoration.inactive_opacity", kind = "float", min = 0, max = 1, step = 0.01 },
  { page = "appearance", group = "opacity", path = "decoration.dim_inactive", kind = "bool" },
  { page = "appearance", group = "opacity", path = "decoration.dim_strength", kind = "float", min = 0, max = 1, step = 0.01 },
  { page = "appearance", group = "blur", path = "decoration.blur.enabled", kind = "bool" },
  { page = "appearance", group = "blur", path = "decoration.blur.size", kind = "int", min = 0, max = 100, unit = "px" },
  { page = "appearance", group = "blur", path = "decoration.blur.passes", kind = "int", min = 0, max = 10 },
  { page = "appearance", group = "blur", path = "decoration.blur.vibrancy", kind = "float", min = 0, max = 1, step = 0.01 },
  { page = "appearance", group = "shadow", path = "decoration.shadow.enabled", kind = "bool" },
  { page = "appearance", group = "shadow", path = "decoration.shadow.range", kind = "int", min = 0, max = 100, unit = "px" },
  { page = "appearance", group = "shadow", path = "decoration.shadow.render_power", kind = "int", min = 1, max = 4 },
  { page = "appearance", group = "layout", path = "general.layout", kind = "choice", choices = { "dwindle", "master", "scrolling", "monocle" } },

  -- Input
  { page = "input", group = "keyboard", path = "input.kb_layout", kind = "string" },
  { page = "input", group = "keyboard", path = "input.kb_variant", kind = "string" },
  { page = "input", group = "keyboard", path = "input.kb_options", kind = "string" },
  { page = "input", group = "keyboard", path = "input.repeat_rate", kind = "int", min = 0, max = 200, unit = "/s" },
  { page = "input", group = "keyboard", path = "input.repeat_delay", kind = "int", min = 0, max = 2000, unit = "ms" },
  { page = "input", group = "keyboard", path = "input.numlock_by_default", kind = "bool" },
  { page = "input", group = "mouse", path = "input.sensitivity", kind = "float", min = -1, max = 1, step = 0.05 },
  { page = "input", group = "mouse", path = "input.accel_profile", kind = "choice", choices = { "", "adaptive", "flat" } },
  { page = "input", group = "mouse", path = "input.follow_mouse", kind = "enum", choices = { 0, 1, 2, 3 } },
  { page = "input", group = "mouse", path = "input.natural_scroll", kind = "bool" },
  { page = "input", group = "touchpad", path = "input.touchpad.natural_scroll", kind = "bool" },
  { page = "input", group = "touchpad", path = "input.touchpad.tap_to_click", kind = "bool" },
  { page = "input", group = "touchpad", path = "input.touchpad.disable_while_typing", kind = "bool" },
  { page = "input", group = "touchpad", path = "input.touchpad.scroll_factor", kind = "float", min = 0, max = 2, step = 0.05 },
  { page = "input", group = "touchpad", path = "input.touchpad.clickfinger_behavior", kind = "bool" },

  -- Animations (the preset itself lives in lib/presets/)
  { page = "animations", group = "animations", path = "animations.enabled", kind = "bool" },

  -- System
  { page = "system", group = "sync", path = "misc.vrr", kind = "enum", choices = { 0, 1, 2, 3 } },
  { page = "system", group = "focus", path = "misc.focus_on_activate", kind = "bool" },
  { page = "system", group = "focus", path = "binds.workspace_back_and_forth", kind = "bool" },
  { page = "system", group = "cursor", path = "cursor.inactive_timeout", kind = "float", min = 0, max = 20, step = 1, unit = "s" },
  { page = "system", group = "cursor", path = "cursor.hide_on_key_press", kind = "bool" },
  { page = "system", group = "cursor", path = "misc.mouse_move_enables_dpms", kind = "bool" },
  { page = "system", group = "cursor", path = "misc.key_press_enables_dpms", kind = "bool" },
  { page = "system", group = "startup", path = "misc.disable_hyprland_logo", kind = "bool" },
  { page = "system", group = "startup", path = "misc.disable_splash_rendering", kind = "bool" },
  { page = "system", group = "xwayland", path = "xwayland.enabled", kind = "bool" },
  -- Only has an effect with XWayland on; the panel hides it otherwise but keeps the value.
  { page = "system", group = "xwayland", path = "xwayland.force_zero_scaling", kind = "bool", dependsOn = "xwayland.enabled" },
}

local byPath = {}
for index, option in ipairs(options) do
  option.order = index
  option.name = (option.path:gsub("%.", ":"))
  byPath[option.path] = option
end

return {
  pages = { "appearance", "input", "system", "animations", "displays" },
  options = options,
  byPath = byPath,
}
