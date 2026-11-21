"""Declarative setting definitions: Field, section specs, and rule groupings."""


from .actions import (
    ACTION_TEMPLATES,
)


class Field:
    """Describes one setting: label, TOML path, widget kind, default, extra options and whether it is optional."""
    def __init__(self, label, path, kind, default, extra, opt):
        """Store the setting description; `path` is a dotted string like 'input.touchpad.tap'."""
        self.label, self.path, self.kind = label, tuple(path.split(".")), kind
        self.default, self.extra, self.opt = default, extra, opt


def F(label, path, kind, default=None, extra=None, opt=False):
    """Short constructor for Field. `opt=True` gives the field a 'set' checkbox (unchecked = key absent)."""
    return Field(label, path, kind, default, extra, opt)


# ---------------------------------------------------------------------- specs
CURVES = ["linear", "ease", "easeout", "snappy", "bounce", "elastic", "spring:1,900"]
ON_OFF = ["on", "negotiated", "forced", "off"]
LAYOUTS = ["scrolling", "dwindle", "master", "stacking"]
VRR = ["disabled", "always", "fullscreen"]
HDR = ["off", "on", "auto", "fullscreen"]
ACCEL = ["flat", "adaptive"]


def layout_fields(p, opt=False):
    """Fields shared by [layout] and per-workspace layout overrides (mode, gap, presets, maximize behavior)."""
    return [
        F("Mode", f"{p}.mode", "choice", "scrolling", LAYOUTS, opt),
        F("Gap", f"{p}.gap", "int", 8, (0, 500), opt),
        F("Extent presets (TOML array)", f"{p}.extent_presets", "raw", [0.333, 0.5, 0.667], None, opt),
        F("New window exits fullscreen (TOML)", f"{p}.new_exits_fullscreen", "raw", [], None, opt),
        F("Client maximize button", f"{p}.client_maximize", "choice", "column", ["column", "edges"], opt),
    ]


def struts(p, opt=False):
    """Four fields for reserved screen edges (left/right/top/bottom) under `<p>.struts`."""
    return [F(s.capitalize(), f"{p}.struts.{s}", "int", 0, (-65535, 65535), opt)
            for s in ("left", "right", "top", "bottom")]


def scrolling(p, opt=False):
    """Fields for the scrolling layout (default column width, centering behavior) under `<p>.scrolling`."""
    return [
        F("Default column width fraction", f"{p}.scrolling.default_extent_fraction", "float", 0.5, (0.1, 4.0), True),
        F("Center underfull strip", f"{p}.scrolling.center_underfull_strip", "bool", True, None, opt),
        F("Center focused", f"{p}.scrolling.center_focused", "choice", "never", ["never", "always", "on_overflow"], opt),
        F("Center column picked in overview", f"{p}.scrolling.center_on_overview_select", "bool", False, None, opt),
    ]


def master(p, opt=False):
    """Fields for the master layout (master position, width, new-window behavior) under `<p>.master`."""
    return [
        F("Position", f"{p}.master.position", "choice", "left", ["left", "right", "center"], opt),
        F("Master width fraction", f"{p}.master.default_width_fraction", "float", 0.55, (0.1, 0.9), opt),
        F("New stack windows on top", f"{p}.master.new_on_top", "bool", True, None, opt),
        F("New window becomes master", f"{p}.master.new_becomes_master", "bool", False, None, opt),
    ]


def dwindle(p, opt=False):
    """Fields for the dwindle layout (split preservation, new-window placement) under `<p>.dwindle`."""
    return [
        F("Preserve split", f"{p}.dwindle.preserve_split", "bool", False, None, opt),
        F("New window toward cursor", f"{p}.dwindle.new_toward_cursor", "bool", False, None, opt),
    ]


# Color fields that get an opacity slider (0-1, written as the color's alpha byte) under their row.
OPACITY_SLIDERS = {("colors", "title_bar", "background"), ("colors", "title_bar", "background_unfocused")}


def color_group(title, prefix, items):
    """Build a titled group of color fields from (name, default) pairs under the TOML table `prefix`."""
    return (title, [F(n.replace("_", " ").capitalize(), f"{prefix}.{n}", "color", d, None, True) for n, d in items])


def anim(name, title, curve, enabled=True, extras=(), effect=True, duration=True):
    """Build one animation event group: enabled, duration, curve, any extra fields, and an optional custom effect preset."""
    f = [F("Enabled", f"animation.{name}.enabled", "bool", enabled, None, True)]
    if duration:
        f.append(F("Duration (ms)", f"animation.{name}.duration_ms", "int", 250, (1, 10000), True))
    f.append(F("Curve", f"animation.{name}.curve", "combo", curve, CURVES, True))
    f += list(extras)
    if effect:
        f.append(F("Custom effect preset", f"animation.{name}.effect", "str", "", None, True))
    return (title, f)


def A(name, label, kind, default, extra=None):
    """Shortcut for an optional animation field at `animation.<name>`, used for event-specific extras like style or scale."""
    return F(label, f"animation.{name}", kind, default, extra, True)


# TABS maps a tab name to its groups: [(group title, [F(...), ...]), ...].
# Each F(...) is one setting: label, TOML path, widget kind, default, extra, optional.
TABS = {}

TABS["General"] = [
    ("Session", [
        F("Autostart commands (restart)", "general.autostart", "command_list", []),
        F("Mod key", "general.mod_key", "combo", "Super", ["Super", "Alt", "Ctrl", "Shift"], True),
        F("Show keybind cheatsheet at start", "general.show_cheatsheet", "bool", True, None, True),
        F("Let activation requests focus windows", "general.focus_on_activate", "bool", False, None, True),
        F("Attach modal dialogs to parent", "general.attach_modal_dialogs", "bool", True, None, True),
        F("Honor maximize while opening", "general.honor_restored_maximize", "bool", False, None, True),
        F("NVIDIA sync workaround", "general.nvidia_sync_workaround", "bool", True, None, True),
    ]),
    ("XWayland (restart)", [
        F("Enable XWayland", "general.xwayland", "bool", True, None, True),
        F("Native resolution (sharp on scaled outputs)", "general.xwayland_native_resolution", "bool", False, None, True),
        F("Announce scale/cursor via XSETTINGS", "general.xwayland_xsettings", "bool", True, None, True),
        F("Primary output for X11 apps", "general.xwayland_primary_output", "str", "", None, True),
    ]),
    ("Lid events", [
        F("Lid close command", "events.lid_close", "str", "", None, True),
        F("Lid open command", "events.lid_open", "str", "", None, True),
    ]),
    ("Screencast", [
        F("Skip confirmation on target changes", "screencast.disable_dynamic_confirmation", "bool", False, None, True),
    ]),
    ("DRM devices (restart)", [
        F("Ignored device paths", "drm.ignored_devices", "list", [], None, True),
        F("Ignored PCI addresses", "drm.ignored_pci_addresses", "list", [], None, True),
    ]),
    ("Includes", [
        F("Required include files", "include.files", "list", [], None, True),
        F("Optional include files", "include.optional.files", "list", [], None, True),
    ]),
]

TABS["Appearance"] = [
    ("Windows", [
        F("Prefer server-side decorations", "appearance.prefer_no_csd", "bool", True, None, True),
        F("Border width", "appearance.border_width", "int", 2, (0, 100), True),
        F("Outer border width", "appearance.outer_border_width", "int", 0, (0, 100), True),
        F("Corner radius", "appearance.corner_radius", "int", 10, (0, 100), True),
        F("Opacity while dragging", "appearance.drag_opacity", "float", 0.75, (0.0, 1.0), True),
        F("Opaque fullscreen", "appearance.opaque_fullscreen", "bool", True, None, True),
    ]),
    ("Blur", [
        F("Enabled", "appearance.blur.enabled", "bool", True, None, True),
        F("Optimized (shared cache)", "appearance.blur.optimized", "bool", True, None, True),
        F("Passes", "appearance.blur.passes", "int", 2, (0, 8), True),
        F("Radius", "appearance.blur.radius", "int", 5, (0, 100), True),
        F("Noise", "appearance.blur.noise", "float", 0.02, (0.0, 1.0), True),
        F("Brightness", "appearance.blur.brightness", "float", 0.9, (0.0, 2.0), True),
        F("Contrast", "appearance.blur.contrast", "float", 0.9, (0.0, 2.0), True),
        F("Saturation", "appearance.blur.saturation", "float", 1.1, (0.0, 2.0), True),
    ]),
    ("Shadow", [
        F("Enabled", "appearance.shadow.enabled", "bool", True, None, True),
        F("Softness", "appearance.shadow.softness", "int", 10, (0, 200), True),
        F("Offset X", "appearance.shadow.offset_x", "int", 2, (-200, 200), True),
        F("Offset Y", "appearance.shadow.offset_y", "int", 2, (-200, 200), True),
    ]),
    ("Title bar", [
        F("Mode", "appearance.title_bar.mode", "choice", "off", ON_OFF, True),
        F("Height", "appearance.title_bar.height", "int", 28, (16, 128), True),
        F("Font (Pango)", "appearance.title_bar.font", "str", "sans 10", None, True),
        F("Title alignment", "appearance.title_bar.title_align", "choice", "left", ["left", "center", "right"], True),
        F("Button position", "appearance.title_bar.button_position", "choice", "right", ["left", "right"], True),
        F("Button background", "appearance.title_bar.button_background", "bool", True, None, True),
        F("Button glyph", "appearance.title_bar.button_glyph", "choice", "hover", ["always", "hover", "never"], True),
        F("Buttons (comma separated)", "appearance.title_bar.buttons", "list", ["minimize", "maximize", "close"], None, True),
        F("Button corner radius (-1 follows window)", "appearance.title_bar.button_corner_radius", "int", -1, (-1, 100), True),
        F("Button size (-1 automatic)", "appearance.title_bar.button_size", "int", -1, (-1, 128), True),
        F("Button padding (-1 automatic)", "appearance.title_bar.button_padding", "int", -1, (-1, 100), True),
        F("Button gap", "appearance.title_bar.button_gap", "int", 8, (0, 100), True),
        F("Button glyph size (-1 automatic)", "appearance.title_bar.button_glyph_size", "int", -1, (-1, 128), True),
        F("Button glyph stroke (-1 automatic)", "appearance.title_bar.button_glyph_stroke", "float", -1.0, (-1.0, 16.0), True),
    ]),
    ("Tab bar", [
        F("Style", "appearance.tab_bar.style", "choice", "titles", ["titles", "indicator"], True),
        F("Position", "appearance.tab_bar.position", "choice", "top", ["top", "bottom", "left", "right"], True),
        F("Height / thickness", "appearance.tab_bar.height", "int", 24, (2, 400), True),
        F("Font (Pango)", "appearance.tab_bar.font", "str", "sans 10", None, True),
        F("Padding", "appearance.tab_bar.padding", "int", 8, (0, 64), True),
        F("Tab gap", "appearance.tab_bar.tab_gap", "int", 2, (0, 64), True),
        F("Gap to window (-1 follows layout)", "appearance.tab_bar.gap", "int", -1, (-1, 500), True),
        F("Corner radius (-1 follows window)", "appearance.tab_bar.corner_radius", "int", -1, (-1, 100), True),
        F("Title format", "appearance.tab_bar.title_format", "str", "{title}", None, True),
        F("Title align", "appearance.tab_bar.title_align", "choice", "center", ["left", "center", "right"], True),
        F("Visible", "appearance.tab_bar.visible", "bool", True, None, True),
        F("Hide when single", "appearance.tab_bar.hide_when_single", "bool", False, None, True),
        F("Max tabs (0 = all)", "appearance.tab_bar.max_tabs", "int", 0, (0, 64), True),
        F("Overflow", "appearance.tab_bar.overflow", "choice", "scroll", ["scroll", "shrink"], True),
    ]),
]

TABS["Colors"] = [
    color_group("General", "colors", [
        ("background", "#141419FF"), ("text_primary", "#E8E8EAFF"), ("text_muted", "#8A8A92FF"),
        ("accent_primary", "#7AA3FFFF"), ("accent_secondary", "#F5C96BFF"), ("warning", "#F5C96BFF"),
        ("error", "#FF6B6BFF"), ("insert_hint", "#7FC8FF80"), ("backdrop", "#000000FF"), ("shadow", "#0000007F")]),
    color_group("Borders", "colors.border", [
        ("focused", "#7AA3FFFF"), ("unfocused", "#292933FF"), ("outer", "#1A1A1FFF")]),
    color_group("Overview", "colors.overview", [
        ("background_tint", "#10101430"), ("workspace_background", "#00000044"), ("badge", "#7AA3FFFF")]),
    color_group("Tab bar", "colors.tab_bar", [
        ("background", "#1A1A1FFF"), ("text", "#8A8A92FF"), ("active", "#7AA3FFFF"),
        ("active_text", "#141419FF"), ("active_unfocused", "#292933FF"),
        ("active_unfocused_text", "#E8E8EAFF"), ("urgent", "#FF6B6BFF"), ("urgent_text", "#141419FF")]),
    color_group("Title bar", "colors.title_bar", [
        ("background", "#292933FF"), ("background_unfocused", "#1A1A1FFF"), ("text", "#E8E8EAFF"),
        ("text_unfocused", "#8A8A92FF"), ("close", "#FF6B6BFF"), ("maximize", "#7AA3FFFF"),
        ("minimize", "#FFD166FF"),
        ("close_glyph", "#141419FF"), ("close_glyph_hover", "#141419FF"),
        ("maximize_glyph", "#141419FF"), ("maximize_glyph_hover", "#141419FF"),
        ("minimize_glyph", "#141419FF"), ("minimize_glyph_hover", "#141419FF")]),
]

TABS["Input"] = [
    ("General", [
        F("Middle-click paste", "input.middle_click_paste", "bool", True, None, True),
        F("Let apps start window drags", "input.client_window_drag", "bool", True, None, True),
        F("Other button during drag", "input.window_drag_toggle", "choice", "none", ["none", "floating", "pinned"], True),
        F("Mod+right double click", "input.mod_right_double_click", "choice", "none", ["none", "maximize"], True),
    ]),
    ("Keyboard", [
        F("Layout (e.g. us,de)", "input.keyboard.layout", "str", "", None, True),
        F("Variant", "input.keyboard.variant", "str", "", None, True),
        F("XKB options", "input.keyboard.options", "str", "", None, True),
        F("Model", "input.keyboard.model", "str", "", None, True),
        F("Repeat rate (Hz)", "input.keyboard.repeat_rate", "int", 25, (0, 1000), True),
        F("Repeat delay (ms)", "input.keyboard.repeat_delay", "int", 600, (0, 10000), True),
        F("NumLock on connect", "input.keyboard.numlock_toggle", "bool", False, None, True),
        F("Track layout", "input.keyboard.track_layout", "choice", "global", ["global", "window"], True),
    ]),
    ("Touchpad", [
        F("Enabled", "input.touchpad.enabled", "bool", True, None, True),
        F("Tap to click", "input.touchpad.tap", "bool", True, None, True),
        F("Tap and drag", "input.touchpad.tap_and_drag", "bool", False, None, True),
        F("Drag lock", "input.touchpad.drag_lock", "choice", "sticky", ["off", "timeout", "sticky"], True),
        F("Natural scroll", "input.touchpad.natural_scroll", "bool", True, None, True),
        F("Left handed", "input.touchpad.left_handed", "bool", False, None, True),
        F("Acceleration profile", "input.touchpad.accel_profile", "combo", "adaptive", ACCEL, True),
        F("Sensitivity", "input.touchpad.sensitivity", "float", 0.0, (-1.0, 1.0), True),
        F("Scroll factor (number or {horizontal,vertical})", "input.touchpad.scroll_factor", "raw", 1.0, None, True),
        F("Disable while typing", "input.touchpad.disable_while_typing", "bool", True, None, True),
        F("Disable with external mouse", "input.touchpad.disable_on_external_mouse", "bool", True, None, True),
        F("Scroll method", "input.touchpad.scroll_method", "choice", "two_finger", ["two_finger", "edge", "none"], True),
        F("Click method", "input.touchpad.click_method", "choice", "clickfinger", ["button_areas", "clickfinger"], True),
        F("Tap button map", "input.touchpad.tap_button_map", "choice", "left_middle_right",
          ["left_right_middle", "left_middle_right"], True),
    ]),
    ("Mouse", [
        F("Natural scroll", "input.mouse.natural_scroll", "bool", False, None, True),
        F("Left handed", "input.mouse.left_handed", "bool", False, None, True),
        F("Acceleration profile (or custom ...)", "input.mouse.accel_profile", "combo", "flat", ACCEL, True),
        F("Sensitivity", "input.mouse.sensitivity", "float", 0.0, (-1.0, 1.0), True),
        F("Scroll wheel step (px)", "input.mouse.scroll_wheel_step", "int", 60, (1, 1000), True),
        F("Scroll button", "input.mouse.scroll_button", "choice", "MouseBack",
          ["MouseLeft", "MouseRight", "MouseMiddle", "MouseBack", "MouseForward"], True),
        F("Scroll button lock", "input.mouse.scroll_button_lock", "bool", False, None, True),
    ]),
    ("Tablet", [
        F("Enabled", "input.tablet.enabled", "bool", True, None, True),
        F("Map to output", "input.tablet.map_to_output", "str", "", None, True),
        F("Map to focused output", "input.tablet.map_to_focused_output", "bool", False, None, True),
        F("Map to focused window", "input.tablet.map_to_focused_window", "bool", False, None, True),
        F("Left handed", "input.tablet.left_handed", "bool", False, None, True),
        F("Calibration matrix (6 numbers)", "input.tablet.calibration_matrix", "raw",
          [1.0, 0.0, 0.0, 0.0, 1.0, 0.0], None, True),
    ]),
    ("Touch", [
        F("Enabled", "input.touch.enabled", "bool", True, None, True),
        F("Map to output", "input.touch.map_to_output", "str", "", None, True),
    ]),
    ("Cursor", [
        F("Theme", "input.cursor.theme", "combo", "", None, True),
        F("Size", "input.cursor.size", "int", 24, (1, 512), True),
        F("Hardware cursor", "input.cursor.hardware_cursor", "bool", True, None, True),
        F("Follows keyboard focus", "input.cursor.follows_focus", "bool", False, None, True),
        F("Hide when typing", "input.cursor.hide_when_typing", "bool", False, None, True),
        F("Hide after inactivity (ms, 0 = never)", "input.cursor.hide_timeout_ms", "int", 0, (0, 3600000), True),
    ]),
    ("Drag edge scroll", [
        F("Enabled", "input.drag_edge_scroll.enabled", "bool", True, None, True),
        F("Trigger zone (px)", "input.drag_edge_scroll.trigger_zone", "int", 30, (1, 1000), True),
        F("Delay (ms)", "input.drag_edge_scroll.delay_ms", "int", 100, (0, 10000), True),
        F("Max speed (px/s)", "input.drag_edge_scroll.max_speed", "float", 1500.0, (1.0, 100000.0), True),
    ]),
    ("Focus", [
        F("Focus follows mouse", "input.focus.follows_mouse", "bool", False, None, True),
        F("Max scroll to reveal (viewports)", "input.focus.follows_mouse_max_scroll", "float", 0.5, (0.0, 100.0), True),
        F("Hover raises window", "input.focus.hover_raises", "bool", True, None, True),
    ]),
]

TABS["Layout"] = [
    ("Shared", layout_fields("layout", True) + struts("layout", True)),
    ("Scrolling", scrolling("layout", True)),
    ("Dwindle", dwindle("layout", True)),
    ("Master", master("layout", True)),
    ("Stacking", [
        F("Drop zones (pointer snapping)", "layout.stacking.drop_zones", "bool", True, None, True),
    ]),
    ("Tab groups", [
        F("Default display", "layout.tabs.default_display", "choice", "normal", ["normal", "tabbed"], True),
        F("New tab position", "layout.tabs.new_tab_position", "choice", "end", ["end", "after_active"], True),
        F("Wrap focus", "layout.tabs.wrap_focus", "bool", True, None, True),
        F("Wheel switches tabs", "layout.tabs.scroll_switches_tabs", "bool", True, None, True),
        F("Middle click closes tab", "layout.tabs.middle_click_closes", "bool", False, None, True),
    ]),
]

TABS["Workspaces"] = [
    ("Global", [
        F("Back and forth", "workspaces.back_and_forth", "bool", False, None, True),
        F("Empty workspace above", "workspaces.empty_above", "bool", False, None, True),
    ]),
    ("Overview", [
        F("Zoom", "overview.zoom", "float", 0.5, (0.1, 0.75), True),
        F("Scroll factor horizontal", "overview.scroll_factor_horizontal", "float", 1.0, (0.1, 10.0), True),
        F("Scroll factor vertical", "overview.scroll_factor_vertical", "float", 1.0, (0.1, 10.0), True),
        F("Background blur", "overview.background_blur", "bool", True, None, True),
        F("Workspace wallpaper", "overview.workspace_wallpaper", "bool", True, None, True),
        F("Shortcut badges", "overview.shortcuts", "bool", True, None, True),
        F("Shortcut keys", "overview.shortcut_keys", "str", "1234567890", None, True),
    ]),
]

for _c in ("top_left", "top_right", "bottom_left", "bottom_right"):
    TABS["Workspaces"].append((f"Hot corner: {_c.replace('_', ' ')}", [
        F("Enabled", f"hot_corners.{_c}.enabled", "bool", False, None, True),
        F("Delay (ms)", f"hot_corners.{_c}.delay_ms", "int", 500, (0, 10000), True),
        F("Action (pick or type)", f"hot_corners.{_c}.action", "combo", "", ACTION_TEMPLATES, True),
    ]))

TABS["Animation"] = [
    ("Defaults", [
        F("Enabled", "animation.enabled", "bool", True, None, True),
        F("Duration (ms)", "animation.duration_ms", "int", 250, (1, 10000), True),
        F("Curve", "animation.curve", "combo", "easeout", CURVES, True),
    ]),
    anim("windows_in", "Windows opening", "spring:1,900", extras=[
        A("windows_in.style", "Style", "choice", "popin", ["popin", "zoom", "slide", "fade", "none"]),
        A("windows_in.scale", "Scale (popin)", "float", 0.5, (0.1, 1.0))]),
    anim("windows_out", "Windows closing", "spring:1,1400", extras=[
        A("windows_out.style", "Style", "choice", "popin", ["fade", "slide", "popin", "zoom"]),
        A("windows_out.scale", "Scale (popin)", "float", 0.8, (0.1, 1.0))]),
    anim("windows_move", "Windows moving", "spring:1,800"),
    anim("windows_resize", "Windows resizing", "spring:1,900", effect=False, extras=[
        A("windows_resize.wait_for_redraw", "Wait for redraw", "bool", False)]),
    anim("windows_opacity", "Window opacity and blur", "spring:1,900", effect=False),
    anim("workspaces", "Workspace switching", "spring:1,800", extras=[
        A("workspaces.style", "Style", "choice", "slide", ["slide", "reveal"])]),
    anim("overview", "Overview", "spring:1,800", extras=[
        A("overview.workspace_curve", "Filmstrip curve", "combo", "spring:1,1000", CURVES)]),
    anim("scratchpad", "Scratchpad", "spring:1,800", extras=[
        A("scratchpad.dim", "Backdrop dim", "float", 0.8, (0.0, 1.0)),
        A("scratchpad.blur", "Blur backdrop", "bool", False)]),
    anim("dialogs", "Modal dialogs", "easeout", effect=False, extras=[
        A("dialogs.dim", "Parent dim", "float", 0.3, (0.0, 1.0))]),
    anim("border", "Focus border", "spring:1,900"),
    anim("dim_unfocused", "Dim unfocused windows", "easeout", enabled=False, extras=[
        A("dim_unfocused.dim", "Dim", "float", 0.0, (0.0, 1.0))]),
    anim("layers", "Layer-shell surfaces", "easeout", enabled=False),
    ("Drag physics", [
        F("Enabled", "animation.windows_drag.physics", "bool", False, None, True),
        F("Stiffness", "animation.windows_drag.stiffness", "float", 36.0, (1.0, 10000.0), True),
        F("Damping", "animation.windows_drag.damping", "float", 6.5, (1.0, 100.0), True),
        F("Coupling", "animation.windows_drag.coupling", "float", 100.0, (0.0, 10000.0), True),
        F("Pointer response", "animation.windows_drag.pointer_response", "float", 2.0, (0.0, 10.0), True),
        F("Max displacement (px)", "animation.windows_drag.max_displacement_px", "float", 200.0, (1.0, 4000.0), True),
        F("Settle after pause (s)", "animation.windows_drag.settle_after_pause_s", "float", 0.25, (0.1, 5.0), True),
    ]),
    ("Selected effects ([effects] table)", [
        F("Border effect", "effects.border", "str", "", None, True),
        F("Border effect on unfocused windows", "effects.border_unfocused", "bool", False, None, True),
        F("Window effect", "effects.window", "str", "", None, True),
        F("Screen effect", "effects.screen", "str", "", None, True),
        F("Effect while screen sharing", "effects.screen_cast", "str", "", None, True),
        F("Cursor effect", "effects.cursor", "str", "", None, True),
        F("Draw effects in screen captures", "effects.in_capture", "bool", False, None, True),
        F("Effect frame rate cap (0 = none)", "effects.max_fps", "int", 0, (0, 240), True),
    ]),
]

MATCH_BOOLS = [("focused", "is_focused"), ("floating", "is_floating"), ("maximized to edges", "is_maximized_to_edges"),
               ("pinned", "is_pinned"), ("in scratchpad", "is_scratchpad"), ("only tiled window", "is_alone"),
               ("only window on workspace", "is_only_window"), ("is dialog", "is_dialog"),
               ("is cast target", "is_cast_target"), ("at startup (first 60 s)", "at_startup")]

WINDOW_RULE = (
    [F("app_id (regex or [array])", "match.app_id", "strorlist", "", None, True),
     F("title (regex or [array])", "match.title", "strorlist", "", None, True),
     F("xdg_tag (regex or [array])", "match.xdg_tag", "strorlist", "", None, True),
     F("content_type", "match.content_type", "choice", "none", ["none", "photo", "video", "game"], True),
     F("layout (name or [array])", "match.layout", "strorlist", "", None, True)]
    + [F("Match " + lbl, "match." + k, "bool", True, None, True) for lbl, k in MATCH_BOOLS]
    + [F("Open on output", "default_output", "str", "", None, True),
       F("Open on workspace (2 or \"NAME\")", "default_workspace", "raw", 1, None, True),
       F("Open in scratchpad", "default_scratchpad", "str", "", None, True),
       F("Open fullscreen", "default_fullscreen", "bool", True, None, True),
       F("Open floating", "default_floating", "bool", True, None, True),
       F("Open maximized", "default_maximize", "bool", True, None, True),
       F("Open maximized to edges", "default_maximize_to_edges", "bool", True, None, True),
       F("Takes focus", "default_focused", "bool", True, None, True),
       F("Open pinned", "default_pinned", "bool", True, None, True),
       F("Named scrolling column", "default_scrolling_column", "str", "", None, True),
       F("Column order", "default_scrolling_column_order", "int", 0, (-2147483648, 2147483647), True),
       F("Column display", "default_column_display", "choice", "normal", ["normal", "tabbed"], True),
       F("Attach modal dialogs to parent", "attach_to_parent", "bool", True, None, True),
       F("Floating size px", "default_floating_size_px", "table", {"width": 800, "height": 600}, ("width", "height"), True),
       F("Floating size fraction", "default_floating_size", "table", {"width": 0.5, "height": 0.5}, ("width", "height"), True),
       F("Scrolling extent px", "default_scrolling_extent_px", "int", 800, (1, 100000), True),
       F("Scrolling extent fraction", "default_scrolling_extent", "float", 0.5, (0.1, 4.0), True),
       F("Floating position", "default_position", "table", {"x": 0, "y": 0, "anchor": "center"}, ("x", "y", "anchor"), True),
       F("Opacity", "opacity", "float", 1.0, (0.0, 1.0), True),
       F("Dim behind", "dim_behind", "float", 0.0, (0.0, 1.0), True),
       F("Blur", "blur", "bool", True, None, True),
       F("Blur popups", "blur_popups", "bool", True, None, True),
       F("Blur ignore alpha", "blur_ignore_alpha", "float", 0.5, (0.0, 1.0), True),
       F("Blur optimized", "blur_optimized", "bool", True, None, True),
       F("Confine pointer", "confine_pointer", "bool", False, None, True),
       F("Touchpad scroll factor", "touchpad_scroll_factor", "float", 1.0, (0.1, 10.0), True),
       F("Block screen capture", "block_capture", "bool", True, None, True),
       F("Allow shortcuts inhibit", "allow_shortcuts_inhibit", "bool", True, None, True),
       F("Background render", "background_render", "bool", False, None, True),
       F("Focus on activate", "focus_on_activate", "bool", False, None, True),
       F("VRR", "vrr", "choice", "always", VRR, True),
       F("Tearing", "tearing", "bool", True, None, True),
       F("HDR", "hdr", "choice", "auto", HDR, True),
       F("Border color focused", "border_color_focused", "color", "#7AA3FFFF", None, True),
       F("Border color unfocused", "border_color_unfocused", "color", "#292933FF", None, True),
       F("Border color outer", "border_color_outer", "color", "#1A1A1FFF", None, True),
       F("Border width", "border_width", "int", 2, (0, 100), True),
       F("Outer border width", "outer_border_width", "int", 0, (0, 100), True),
       F("Title bar", "title_bar", "choice", "on", ON_OFF, True),
       F("Title bar buttons (TOML array)", "title_bar_buttons", "raw", ["close"], None, True),
       F("Corner radius", "corner_radius", "int", 10, (0, 100), True),
       F("Shadow", "shadow", "bool", True, None, True),
       F("Border effect", "border_effect", "str", "", None, True),
       F("Window effect", "window_effect", "str", "", None, True)])

LAYER_RULE = [
    F("namespace (regex or [array])", "match.namespace", "strorlist", "", None, True),
    F("layer", "match.layer", "choice", "top", ["background", "bottom", "top", "overlay"], True),
    F("Match at startup (first 60 s)", "match.at_startup", "bool", True, None, True),
    F("Blur", "blur", "bool", True, None, True),
    F("Blur popups", "blur_popups", "bool", True, None, True),
    F("Blur ignore alpha", "blur_ignore_alpha", "float", 0.5, (0.0, 1.0), True),
    F("Blur optimized", "blur_optimized", "bool", True, None, True),
    F("Dim behind", "dim_behind", "float", 0.0, (0.0, 1.0), True),
]

WORKSPACE_RULE = (
    [F("Name", "name", "str", "", None, True), F("Index (1-64)", "index", "int", 1, (1, 64), True),
     F("Output", "output", "str", "", None, True)]
    + layout_fields("layout", True) + struts("layout", True)
    + scrolling("layout", True) + master("layout", True) + dwindle("layout", True)
    + [F("Stacking drop zones", "layout.stacking.drop_zones", "bool", True, None, True),
       F("Tab default display", "layout.tabs.default_display", "choice", "normal", ["normal", "tabbed"], True),
       F("Tab new position", "layout.tabs.new_tab_position", "choice", "end", ["end", "after_active"], True),
       F("Tab wrap focus", "layout.tabs.wrap_focus", "bool", True, None, True),
       F("Tab wheel switches tabs", "layout.tabs.scroll_switches_tabs", "bool", True, None, True),
       F("Tab middle click closes", "layout.tabs.middle_click_closes", "bool", False, None, True)])

SECURITY_RULE = [
    F("app_id (regex or [array])", "match.app_id", "strorlist", "", None, True),
    F("sandbox_engine (regex or [array])", "match.sandbox_engine", "strorlist", "", None, True),
    F("Allowed protocol globals (comma separated)", "allow_globals", "list", [], None, True),
]

OUTPUT = [
    F("Enabled", "enabled", "bool", True, None, True),
    F("Focus cursor here at startup", "focus_at_startup", "bool", False, None, True),
    F("Mode (e.g. 2560x1440@144)", "mode", "str", "", None, True),
    F("Position", "position", "table", [0, 0], ("x", "y"), True),
    F("Scale", "scale", "float", 1.0, (0.25, 4.0), True),
    F("Transform", "transform", "choice", "normal",
      ["normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270"], True),
    F("VRR", "vrr", "choice", "disabled", VRR, True),
    F("Tearing", "tearing", "bool", False, None, True),
    F("Direct scanout", "direct_scanout", "bool", True, None, True),
    F("HDR", "hdr", "choice", "off", HDR, True),
    F("SDR white (cd/m2)", "sdr_white", "float", 203.0, (80.0, 1000.0), True),
    F("SDR transfer", "sdr_transfer", "choice", "gamma22", ["gamma22", "srgb"], True),
    F("SDR gamut", "sdr_gamut", "choice", "native", ["srgb", "native"], True),
    F("Color profile (none, edid or ICC path)", "color_profile", "combo", "none", ["none", "edid"], True),
    F("Bit depth", "bit_depth", "int", 8, (8, 10), True),
    F("Screen-cast effect", "screen_cast_effect", "str", "", None, True),
    F("Workspaces (\"dynamic\", 5 or [\"A\",\"B\"])", "workspaces", "raw", "dynamic", None, True),
    F("Min workspaces", "min_workspaces", "int", 1, (1, 64), True),
    F("Cyclic workspaces", "cyclic_workspaces", "bool", False, None, True),
    F("Workspace axis", "workspace_axis", "choice", "vertical", ["vertical", "horizontal"], True),
    F("Layout mode", "layout.mode", "choice", "scrolling", LAYOUTS, True),
    F("Scrolling default width fraction", "layout.scrolling.default_extent_fraction", "float", 0.5, (0.1, 4.0), True),
    F("Screen effect", "screen_effect", "str", "", None, True),
]

INPUT_DEVICE = [
    F("Device name (exact, from libinput list-devices)", "name", "str", "", None, True),
    F("Enabled", "enabled", "bool", True, None, True),
    F("Keyboard layout", "layout", "str", "", None, True),
    F("Keyboard variant", "variant", "str", "", None, True),
    F("Keyboard model", "model", "str", "", None, True),
    F("Repeat rate", "repeat_rate", "int", 25, (0, 1000), True),
    F("Repeat delay", "repeat_delay", "int", 600, (0, 10000), True),
    F("XKB options", "options", "str", "", None, True),
    F("Tap to click", "tap", "bool", True, None, True),
    F("Tap and drag", "tap_and_drag", "bool", False, None, True),
    F("Drag lock", "drag_lock", "choice", "off", ["off", "timeout", "sticky"], True),
    F("Tap button map", "tap_button_map", "choice", "left_right_middle", ["left_right_middle", "left_middle_right"], True),
    F("Disable while typing", "disable_while_typing", "bool", True, None, True),
    F("Scroll button lock", "scroll_button_lock", "bool", False, None, True),
    F("Natural scroll", "natural_scroll", "bool", False, None, True),
    F("Left handed", "left_handed", "bool", False, None, True),
    F("Acceleration profile", "accel_profile", "combo", "flat", ACCEL, True),
    F("Sensitivity", "sensitivity", "float", 0.0, (-1.0, 1.0), True),
    F("Scroll method", "scroll_method", "choice", "two_finger", ["two_finger", "edge", "none"], True),
    F("Click method", "click_method", "choice", "clickfinger", ["button_areas", "clickfinger"], True),
    F("Scroll button", "scroll_button", "choice", "MouseBack",
      ["MouseLeft", "MouseRight", "MouseMiddle", "MouseBack", "MouseForward"], True),
]

SCRATCHPAD = [F("Name", "name", "str", "", None, True),
              F("Spawn when empty (command)", "spawn_when_empty", "str", "", None, True),
              F("Keep window size proportional across monitors", "proportional_size", "bool", False, None, True),
              F("Hide when empty", "hide_when_empty", "bool", False, None, True)]

EFFECT_KINDS = ["animation", "border", "window", "screen", "cursor"]
EFFECT_PRESET_GROUPS = [
    ("Preset", [
        F("Kind", "kind", "choice", "window", EFFECT_KINDS),
        F("Shader file (relative to this config)", "shader", "str", "", None, True),
        F("Enable palette uniforms", "palette", "bool", False, None, True),
    ]),
    ("Border-only settings", [
        F("Padding (px)", "padding", "int", 0, (0, 1024), True),
        F("Speed", "speed", "float", 1.0, (0.0, 10.0), True),
        F("Animated", "animated", "bool", True, None, True),
        F("Window overlay preset", "overlay", "str", "", None, True),
        F("Light spread (px)", "light.spread", "int", 80, (1, 256), True),
        F("Light intensity", "light.intensity", "float", 1.0, (0.0, 4.0), True),
        F("Light threshold", "light.threshold", "float", 0.5, (0.0, 1.0), True),
    ]),
    ("Cursor-only settings", [
        F("Radius (px; 0 covers the output)", "radius", "int", 0, (0, 4096), True),
    ]),
]
EFFECT_POOL_GROUPS = [
    ("Pool", [
        F("Kind", "kind", "choice", "window", ["border", "window", "screen", "cursor"]),
        F("Preset names (TOML array)", "choose", "raw", [], None),
        F("Selection policy", "selection", "choice", "unused_first",
          ["unused_first", "round_robin", "random"], True),
    ]),
]


def regroup(fields, rules):
    """Split a flat field list into titled groups; the first matching rule wins.

    `rules` is [(title, predicate(path) -> bool), ...]. Empty groups are dropped.
    """
    out = {t: [] for t, _ in rules}
    for f in fields:
        for t, pred in rules:
            if pred(f.path):
                out[t].append(f)
                break
    return [(t, fs) for t, fs in out.items() if fs]


LOOK_KEYS = ("opacity", "dim_behind", "corner_radius", "shadow", "outer_border_width", "window_effect")
WINDOW_RULE_GROUPS = regroup(WINDOW_RULE, [
    ("Match (which windows)", lambda p: p[0] == "match"),
    ("Open placement", lambda p: p[0].startswith("default_") or p[0] == "attach_to_parent"),
    ("Look (opacity, blur, borders, title bar)",
     lambda p: p[0] in LOOK_KEYS or p[0].startswith(("blur", "border", "title_bar"))),
    ("Behavior (pointer, VRR, HDR, ...)", lambda p: True),
])
WORKSPACE_RULE_GROUPS = regroup(WORKSPACE_RULE, [
    ("Identity", lambda p: p[0] in ("name", "index", "output")),
    ("Struts", lambda p: "struts" in p),
    ("Scrolling layout", lambda p: "scrolling" in p),
    ("Master layout", lambda p: "master" in p),
    ("Dwindle layout", lambda p: "dwindle" in p),
    ("Stacking layout", lambda p: "stacking" in p),
    ("Tab groups", lambda p: "tabs" in p),
    ("Layout", lambda p: True),
])
OUTPUT_GROUPS = regroup(OUTPUT, [
    ("Basics", lambda p: p[0] in ("enabled", "focus_at_startup", "mode", "position", "scale", "transform")),
    ("Display features (VRR, HDR, ...)",
     lambda p: p[0] in ("vrr", "tearing", "direct_scanout", "hdr", "sdr_white", "sdr_transfer",
                       "sdr_gamut", "color_profile", "bit_depth", "screen_cast_effect")),
    ("Workspaces and layout", lambda p: True),
])


# Navigation order shared by the app sidebar and the plugin home page.
NAV_SECTIONS = [
    ("Desktop", ["User folders", "Default apps"]),
    ("Basics", ["General"]),
    ("Look", ["Appearance", "Colors", "Animation", "Animation curves", "Effects"]),
    ("Behavior", ["Input", "Layout", "Workspaces"]),
    ("Bindings", ["Keybinds"]),
    ("Rules and devices", ["Window rules", "Layer rules", "Workspace rules", "Outputs",
                           "Scratchpads", "Input devices", "Security rules", "Environment"]),
]

# Entry editors and key/value maps (plain data here, so schema checks need no tomlkit; entry_ops edits them).
# id: (page, title, TOML path, mode, groups, collapsible)
ENTRY_EDITORS = {
    "output": ("Outputs", "Outputs (connector or monitor)", "output", "map", OUTPUT_GROUPS, True),
    "window_rule": ("Window rules", "[[window_rule]]", "window_rule", "aot", WINDOW_RULE_GROUPS, True),
    "layer_rule": ("Layer rules", "[[layer_rule]]", "layer_rule", "aot", [("Layer rule", LAYER_RULE)], False),
    "workspace": ("Workspace rules", "[[workspace]]", "workspace", "aot", WORKSPACE_RULE_GROUPS, True),
    "security_context_rule": ("Security rules", "[[security_context_rule]]", "security_context_rule", "aot",
                              [("Security context rule", SECURITY_RULE)], False),
    "scratchpad": ("Scratchpads", "[[scratchpad]]", "scratchpad", "aot", [("Scratchpad", SCRATCHPAD)], False),
    "input_device": ("Input devices", "[[input.device]]", "input.device", "aot",
                     [("Device override", INPUT_DEVICE)], False),
    "effect_preset": ("Effects", "Effect presets", "effects.preset", "map", EFFECT_PRESET_GROUPS, True),
    "effect_pool": ("Effects", "Effect pools", "effects.pool", "map", EFFECT_POOL_GROUPS, True),
}

# id: (page, title, TOML path, value kind: "string" | "array" | "table")
MAP_EDITORS = {
    "environment": ("Environment", "Environment variables", "environment", "string"),
    "beziers": ("Animation curves", "Named Bézier curves", "animation.beziers", "array"),
    "springs": ("Animation curves", "Named spring curves", "animation.springs", "table"),
}


def schema_prefix(editor_id):
    """Schema path prefix of an entry editor's fields, e.g. 'window_rule[]' or 'output.<name>'."""
    _, _, path, mode, _, _ = ENTRY_EDITORS[editor_id]
    return path + (".<name>" if mode == "map" else "[]")
