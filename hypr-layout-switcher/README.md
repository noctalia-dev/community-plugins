# Hyprland Layout Switcher

A [Noctalia](https://github.com/noctalia-dev/noctalia-shell) plugin that shows the tiled
layout of the currently active Hyprland workspace in the bar, and lets you cycle through
layouts with a click or a keybinding.

**Hyprland only.** The plugin talks to `hyprctl` and relies on Hyprland's per-workspace
`layout` rule, so it does nothing on other compositors (Sway, river, Niri, X11 WMs, …).

## What it does

- A bar widget shows the active workspace's tiled layout as an icon plus its name
  (`Dwindle`, `Master`, `Monocle`, `Scrolling`).
- A background service polls `hyprctl activeworkspace -j` once per second and publishes
  the layout so the widget stays in sync when you switch workspaces or change the layout
  from elsewhere.
- Clicking the widget — or sending the plugin an IPC message — cycles to the next layout
  in the list `dwindle → master → monocle → scrolling → dwindle`.
- Switching is applied with a workspace rule scoped to the *current* workspace only, so
  different workspaces can keep different layouts. Special workspaces (scratchpads) are
  handled too, matched by name instead of id.

Note that `monocle` and `scrolling` come from Hyprland layout plugins; if you don't have
those installed, cycling onto them will be a no-op on Hyprland's side.

They look like this:

```lua
-- See https://wiki.hypr.land/Configuring/Layouts/Dwindle-Layout/ for more
hl.config({
    dwindle = {
        preserve_split = true, -- You probably want this
    },
})

-- See https://wiki.hypr.land/Configuring/Layouts/Master-Layout/ for more
hl.config({
    master = {
        new_status = "master",
    },
})

-- See https://wiki.hypr.land/Configuring/Layouts/Scrolling-Layout/ for more
hl.config({
    scrolling = {
        fullscreen_on_one_column = true,
    },
})

```

## Requirements

- Hyprland with `hyprctl` on your `PATH`
- Noctalia `5.0.0-beta.1` or newer (plugin API 3)

## Installation

Register this repository as a plugin source, then enable the plugin:

```sh
noctalia msg plugins enable maddingo/hypr-layout-switcher
```

Finally, add the widget to a bar section in the Noctalia settings — it is listed as
**Hyprland Layout Switcher → toggle**.

## Key bindings

The plugin exposes a `cycle` IPC command on its `poller` service:

```sh
noctalia msg plugin maddingo/hypr-layout-switcher:poller all cycle
```

The signature is `plugin <author/plugin:entry> <target[:bar-name]> <event>`. `poller` is a
service entry with no visible output, so the target must be `all`.

Bind that in `~/.config/hypr/hyprland.lua`:

```lua
-- Cycle the active workspace's tiled layout
bind("SUPER, Tab, exec, "
  .. "noctalia msg plugin maddingo/hypr-layout-switcher:poller all cycle")
```

Reload with `hyprctl reload`. The bar widget updates immediately, whether you cycle via
the keybinding or by clicking it.

If you would rather jump straight to a specific layout instead of cycling, bind
`hyprctl` directly — the widget picks the change up on its next poll:

```lua
bind("SUPER, D, exec, hyprctl keyword general:layout dwindle")
bind("SUPER, M, exec, hyprctl keyword general:layout master")
```

Note that `general:layout` changes the global default, whereas the plugin's `cycle`
only affects the active workspace.

## Configuration

There are no settings; to change behaviour, edit the source (fork the repo and add your
fork as the plugin source). The layout list lives at the top of `service.luau`, and the
icons at the top of `widget.luau`:

```lua
local layouts = { "dwindle", "master", "monocle", "scrolling" }
```

Trim it to the layouts you actually have installed, and keep the `glyphs` table in
`widget.luau` in sync. Reload the plugin afterwards.

## License

MIT
