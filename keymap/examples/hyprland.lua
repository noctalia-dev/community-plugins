-- Keymap example for Hyprland's native Lua configuration API.
-- This file is documentation and test data; it is not loaded automatically.

-- 1. Applications
hl.bind("SUPER + RETURN", hl.dsp.exec_cmd("foot"), { description = "Open terminal" })
hl.bind("SUPER + B", hl.dsp.exec_cmd("firefox"), { description = "Open browser" })
hl.bind("SUPER + E", hl.dsp.exec_cmd("xdg-open ."), { description = "Open files" })
hl.bind("SUPER + SPACE", hl.dsp.exec_cmd("noctalia msg panel-toggle launcher"), { description = "Open launcher" })
hl.bind("SUPER + M", hl.dsp.exec_cmd("thunderbird"), { description = "Open mail" })
hl.bind("SUPER + A", hl.dsp.exec_cmd("gnome-calculator"), { description = "Open calculator" })

-- 2. Windows
hl.bind("SUPER + Q", hl.dsp.window.close(), { description = "Close window" })
hl.bind("SUPER + F", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }), { description = "Toggle fullscreen" })
hl.bind("SUPER + SHIFT + F", hl.dsp.window.float({ action = "toggle" }), { description = "Toggle floating" })
hl.bind("SUPER + LEFT", hl.dsp.focus({ direction = "left" }), { description = "Focus left" })
hl.bind("SUPER + RIGHT", hl.dsp.focus({ direction = "right" }), { description = "Focus right" })
hl.bind("SUPER + UP", hl.dsp.focus({ direction = "up" }), { description = "Focus up" })
hl.bind("SUPER + DOWN", hl.dsp.focus({ direction = "down" }), { description = "Focus down" })
hl.bind("SUPER + SHIFT + LEFT", hl.dsp.window.move({ direction = "left" }), { description = "Move window left" })
hl.bind("SUPER + SHIFT + RIGHT", hl.dsp.window.move({ direction = "right" }), { description = "Move window right" })
hl.bind("SUPER + TAB", hl.dsp.window.cycle_next(), { description = "Focus next window" })

-- 3. Workspaces
hl.bind("SUPER + 1", hl.dsp.focus({ workspace = 1 }), { description = "Workspace 1" })
hl.bind("SUPER + 2", hl.dsp.focus({ workspace = 2 }), { description = "Workspace 2" })
hl.bind("SUPER + 3", hl.dsp.focus({ workspace = 3 }), { description = "Workspace 3" })
hl.bind("SUPER + 4", hl.dsp.focus({ workspace = 4 }), { description = "Workspace 4" })
hl.bind("SUPER + SHIFT + 1", hl.dsp.window.move({ workspace = 1, follow = false }), { description = "Move to workspace 1" })
hl.bind("SUPER + SHIFT + 2", hl.dsp.window.move({ workspace = 2, follow = false }), { description = "Move to workspace 2" })
hl.bind("SUPER + mouse_down", hl.dsp.focus({ workspace = "e+1" }), { description = "Next workspace" })
hl.bind("SUPER + mouse_up", hl.dsp.focus({ workspace = "e-1" }), { description = "Previous workspace" })

-- 4. Screenshots
hl.bind("Print", hl.dsp.exec_cmd("grimblast copy output"), { description = "Capture monitor" })
hl.bind("SHIFT + Print", hl.dsp.exec_cmd("grimblast copy area"), { description = "Capture region" })
hl.bind("CTRL + Print", hl.dsp.exec_cmd("grimblast copy active"), { description = "Capture window" })

-- 5. Noctalia
hl.bind("SUPER + K", hl.dsp.exec_cmd("noctalia msg panel-toggle blackbartblues/keymap:panel"), { description = "Open Keymap" })
hl.bind("SUPER + V", hl.dsp.exec_cmd("noctalia msg panel-toggle clipboard"), { description = "Clipboard history" })
hl.bind("SUPER + N", hl.dsp.exec_cmd("noctalia msg panel-toggle notifications"), { description = "Notifications" })
hl.bind("SUPER + P", hl.dsp.exec_cmd("noctalia msg panel-toggle session-menu"), { description = "Session menu" })

-- 6. Media
hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true, description = "Play or pause" })
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"), { locked = true, description = "Next track" })
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"), { locked = true, description = "Previous track" })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), { locked = true, description = "Mute audio" })
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true, description = "Volume up" })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"), { locked = true, repeating = true, description = "Volume down" })

-- 7. Utilities
hl.bind("SUPER + C + V", hl.dsp.exec_cmd("wl-paste | wl-copy"), { release = true, description = "Normalize clipboard" })
hl.bind("SUPER + SHIFT + C", hl.dsp.exec_cmd("hyprpicker -a"), { description = "Pick a color" })
hl.bind("SUPER + L", hl.dsp.exec_cmd("noctalia msg session lock"), { description = "Lock screen" })
