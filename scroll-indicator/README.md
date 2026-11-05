# Scroll Indicator

Hyprland's scrolling layout has no built-in position indicator: you can't tell how many windows are
off-screen or where you are in the row. This bar widget adds one: one dot per column, **●** for the
focused column and **○** for the rest. It hides itself on workspaces that don't use the scrolling layout.

```
○ ● ○ ○      ← 4 columns, the 2nd is focused
```

Further down there's also optional Hyprland config for **visual cues**, which work even if you never
look at the bar: a small **bump** when you hit the first/last column
([Example keybinds](#example-keybinds)), and a vertical **drawer bounce** when you enter the scrolling
workspace ([Drawer bounce](#optional-a-drawer-bounce-when-entering-the-scrolling-workspace)).

## Plugin

| Field | Value |
| --- | --- |
| ID | `83raiders/scroll-indicator` |
| Entries | Bar widget: `dots` |

## Requirements

- Hyprland **0.56 or newer** (reads `tiledLayout` and workspace names from `hyprctl -j`).
- `hyprctl` on `PATH` (ships with Hyprland).
- `socat` on `PATH`, for live updates from Hyprland's event socket. Without it the widget falls back
  to polling every 0.4 s.

## Usage

1. Enable the plugin in **Settings → Plugins**, or run
   `noctalia msg plugins enable 83raiders/scroll-indicator`.
2. Add the `dots` widget to a bar section, for example in `settings.toml`:

   ```toml
   [bar.default]
   center = [ "workspaces", "scroll", "clock" ]

   [widget.scroll]
   type = "83raiders/scroll-indicator:dots"
   ```

3. Switch to a workspace that uses the scrolling layout. The dots update as you move between columns,
   open or close windows. Hover the widget for "Scrolling: column 2 of 4". Windows stacked in the same
   column count as one dot; floating windows are not counted.

### Example setup

Built for one scrolling workspace with **2/3-width columns** on a large (4K) screen, used as a parking
spot for apps you want to keep open but don't need to look at often (Hyprland has no minimize). Each
window keeps plenty of room, and a slice of the next column stays visible.

```lua
-- Hyprland Lua config: workspace 10 (the ALT+0 key) uses the scrolling layout
hl.workspace_rule({ workspace = "10", layout = "scrolling", persistent = true })

hl.config({
  scrolling = {
    column_width = 2/3,
    follow_focus = true,
  },
})
```

The widget works with any column width and on any workspace using the scrolling layout.

### Example keybinds

Optional, but they make a scrolling workspace pleasant to use next to normal tiling. The same keys do
the right thing for each layout.

> **This is the author's setup**, tuned for mostly tiling with one scrolling "drawer" workspace for apps
> kept open in the background. It makes workspace switching the easiest key, and scrolling columns
> `SHIFT + arrows`. Plain focus moves and column swaps exist but get used less. The author uses `ALT` as
> the modifier; set `mod` to whatever you use. If you live *in* the scrolling layout, you'll probably
> prefer plain arrows for columns, Niri-style. Adapt freely.

| Keys | On a scrolling workspace | On other layouts |
| --- | --- | --- |
| `SUPER + SHIFT + Left/Right` | move to the previous/next column (a small "bump" at the first/last one) | move the window |
| `SUPER + M` / `SUPER + N` | swap the column left/right | swap split / toggle split |
| `SUPER + Left/Right` | previous/next workspace; `Right` on the last workspace (10) wraps to 1 | previous/next workspace |

Add to your Hyprland Lua config (change `mod` if you use another modifier, for example `"ALT"`):

```lua
local mod = "SUPER"
local COLUMN_WIDTH = 2/3   -- keep in sync with scrolling.column_width

-- Run a different action depending on the focused workspace's layout.
-- Each action is a dispatcher (hl.dsp.*) or a function.
local function per_layout(actions)
    return function()
        local ws = hl.get_active_special_workspace() or hl.get_active_workspace()
        local action = ws and actions[ws.tiled_layout]
        if type(action) == "function" then
            action()
        elseif action then
            hl.dispatch(action)
        end
    end
end

-- Focus the next column; if focus didn't move (first/last column), briefly widen it as a "bump".
local function column_or_bump(dir)
    return function()
        local before = hl.get_active_window()
        hl.dispatch(hl.dsp.focus({ direction = dir }))
        local after = hl.get_active_window()
        if before and after and before.address == after.address then
            hl.dispatch(hl.dsp.layout(string.format("colresize %.6f", COLUMN_WIDTH + 0.07)))
            hl.timer(function()
                hl.dispatch(hl.dsp.layout(string.format("colresize %.6f", COLUMN_WIDTH)))
            end, { timeout = 180, type = "oneshot" })
        end
    end
end

hl.bind(mod .. " + SHIFT + Left", per_layout({
    scrolling = column_or_bump("l"),
    dwindle   = hl.dsp.window.move({ direction = "l" }),
    master    = hl.dsp.window.move({ direction = "l" }),
}))
hl.bind(mod .. " + SHIFT + Right", per_layout({
    scrolling = column_or_bump("r"),
    dwindle   = hl.dsp.window.move({ direction = "r" }),
    master    = hl.dsp.window.move({ direction = "r" }),
}))

hl.bind(mod .. " + M", per_layout({
    scrolling = hl.dsp.layout("swapcol l"),
    dwindle   = hl.dsp.layout("swapsplit"),
}))
hl.bind(mod .. " + N", per_layout({
    scrolling = hl.dsp.layout("swapcol r"),
    dwindle   = hl.dsp.layout("togglesplit"),
}))

hl.bind(mod .. " + Left",  hl.dsp.focus({ workspace = "r-1" }))

-- Next workspace; from the last one (10, e.g. the scrolling "drawer") wrap back to 1
local LAST_WS = 10
hl.bind(mod .. " + Right", function()
    local ws = hl.get_active_workspace()
    if ws and ws.id and ws.id >= LAST_WS then
        hl.dispatch(hl.dsp.focus({ workspace = 1 }))
    else
        hl.dispatch(hl.dsp.focus({ workspace = "r+1" }))
    end
end)
```

The "bump" uses `colresize`, because Hyprland's scrolling layout won't nudge the row by pixels. If your
columns aren't all the same width, drop the bump and use `hl.dsp.focus({ direction = "l" })` directly.

Floating windows on a scrolling workspace aren't columns: while one is focused, no dot is filled. To
keep an app in the row, give it a `tile = true` window rule.

### Optional: a "drawer" bounce when entering the scrolling workspace

Makes the scrolling workspace feel like a drawer: switching to it slides in **vertically** and
**overshoots slightly before settling** (a bounce), while every other workspace keeps a normal sideways
slide. Hyprland's workspace rules can't set an animation per workspace, so the keybinds swap the
`workspaces` animation just before switching.

```lua
local mod = "SUPER"
local SCROLL_WS = 10   -- your scrolling workspace

-- Overshoots past the end and settles back. Raise 1.56 for a bigger bounce; 1.0 = no bounce.
hl.curve("drawer", { type = "bezier", points = { {0.34, 1.56}, {0.64, 1} } })
hl.curve("smooth", { type = "bezier", points = { {0.16, 1}, {0.3, 1} } })

local function goto_ws(target, move)
    if target == SCROLL_WS then
        hl.animation({ leaf = "workspaces", enabled = true, speed = 7, bezier = "drawer", style = "slidefadevert 25%" })
    else
        hl.animation({ leaf = "workspaces", enabled = true, speed = 6, bezier = "smooth", style = "slidefade 10%" })
    end
    if move then
        hl.dispatch(hl.dsp.window.move({ workspace = target, follow = true }))
    else
        hl.dispatch(hl.dsp.focus({ workspace = target }))
    end
end

for i = 1, 10 do
    local key = i % 10   -- workspace 10 is the 0 key
    hl.bind(mod .. " + " .. key, function() goto_ws(i) end)
    hl.bind(mod .. " + SHIFT + " .. key, function() goto_ws(i, true) end)
end
```

This replaces your existing `mod + 1–0` and `mod + SHIFT + 1–0` workspace binds. Switching another
way (clicking a workspace on the bar, `r+1`/`r-1` binds) uses whichever animation was set last; route
those through `goto_ws` too if you want them consistent.

### Pairs well with: a scroll overview

Hyprland's scrolling layout ships without two things that make it easy to live with: a **position
indicator** (this widget) and an **overview** of the whole row. For the overview, the
[hyprland-scroll-overview](https://github.com/yayuuu/hyprland-scroll-overview) plugin by yayuuu shows
every workspace and column zoomed out, Niri-style, and lets you jump around with the arrow keys:

```sh
hyprpm add https://github.com/yayuuu/hyprland-scroll-overview.git
hyprpm update
hyprpm enable scrolloverview
```

Bind it (and its arrow keys) as its README describes, for example a toggle on `mod + TAB`. Define its
`scrolloverview` submap **once**: defining it in two config files binds every key twice, so each press
fires twice.

Some versions of the overview stop responding to Left/Right when a **floating** window is selected on
a scrolling workspace. If you hit that, update the plugin, or give apps you park there a
`tile = true` window rule.

The layout-aware binding style is inspired by the CachyOS and JaKooLit Hyprland configs.

## Notes

Everything the plugin runs:

| Process | When | Why |
| --- | --- | --- |
| `sh -c "hyprctl -j activeworkspace; hyprctl -j activewindow; hyprctl -j clients"` | on each relevant Hyprland event, plus every 2 s as a safety net (every 0.4 s without `socat`) | read the workspace layout, the focused window and window positions |
| `socat -U - UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock` | once, while the widget is loaded | listen to Hyprland's read-only event socket so the dots update instantly |

No network access and no file writes. Hyprland only; other compositors are not supported.

Source and issues: https://github.com/83raiders/hypr-scroll-indicator

Idea from [jtams/waybar-hyprland-scroll-indicator](https://github.com/jtams/waybar-hyprland-scroll-indicator)
(a Go module for Waybar). This is an independent Luau implementation for Noctalia.
