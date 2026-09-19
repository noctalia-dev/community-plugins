# Hyprland Layout Switcher

![Hyprland Layout Switcher thumbnail](thumbnail.webp)

**Hyprland Layout Switcher** is a bar widget for [Noctalia](https://docs.noctalia.dev) that shows the tiled layout of the currently active Hyprland workspace and cycles to the next layout on click or via a keybinding. Switching is scoped to the current workspace with a workspace rule, so each workspace keeps its own layout instead of changing the global default.

## Plugin

| Field | Value |
| --- | --- |
| ID | `maddingo/hypr-layout-switcher` |
| Entries | Bar widget: `toggle`; service: `poller` |

## Requirements

Hyprland, with `hyprctl` on `PATH` — the plugin declares `hyprland` as a dependency. It reads `hyprctl activeworkspace -j` and applies layouts through `hyprctl eval`, so it does nothing on other compositors (Sway, river, Niri, X11 WMs, …).

The `monocle` and `scrolling` layouts come from Hyprland layout plugins. If you do not have them installed, cycling onto them is a no-op on Hyprland's side.

## Usage

Enable the plugin, then add the widget to a bar section:

```sh
noctalia msg plugins enable maddingo/hypr-layout-switcher
```

In Settings → Bar, add **Hyprland Layout Switcher → toggle** to the section you want. The widget shows an icon plus the layout name (`Dwindle`, `Master`, `Monocle`, `Scrolling`).

The `poller` service runs `hyprctl activeworkspace -j` once per second and publishes the layout, so the widget stays in sync when you switch workspaces or change the layout from elsewhere.

Clicking the widget cycles to the next layout in `dwindle → master → monocle → scrolling → dwindle`. Special workspaces (scratchpads) are handled too, matched by name instead of id.

## IPC

The `poller` service accepts a `cycle` event, which does the same thing as clicking the widget:

```sh
noctalia msg plugin maddingo/hypr-layout-switcher:poller all cycle
```

The signature is `plugin <author/plugin:entry> <target[:bar-name]> <event>`. `poller` is a service entry with no visible output, so the target must be `all`.

Bind it in `~/.config/hypr/hyprland.lua`:

```lua
-- Cycle the active workspace's tiled layout
bind("SUPER, Tab, exec, "
  .. "noctalia msg plugin maddingo/hypr-layout-switcher:poller all cycle")
```

Reload with `hyprctl reload`. The widget updates immediately, whether you cycle via the keybinding or by clicking.

To jump straight to a specific layout instead of cycling, bind `hyprctl` directly — the widget picks the change up on its next poll:

```lua
bind("SUPER, D, exec, hyprctl keyword general:layout dwindle")
bind("SUPER, M, exec, hyprctl keyword general:layout master")
```

Note that `general:layout` changes the global default, whereas the plugin's `cycle` only affects the active workspace.

## Notes

- **Commands spawned:** `hyprctl activeworkspace -j` every second while the plugin is enabled, and `hyprctl eval '…'` on each cycle. No network access, no files written.
- **No settings.** To change behaviour, fork the repo and add your fork as the plugin source. The layout list lives at the top of `service.luau`:

  ```lua
  local layouts = { "dwindle", "master", "monocle", "scrolling" }
  ```

  Trim it to the layouts you actually have installed, and keep the `glyphs` table at the top of `widget.luau` in sync. Reload the plugin afterwards.
- The plugin only sets the layout; per-layout options stay in your Hyprland config, for example:

  ```lua
  -- See https://wiki.hypr.land/Configuring/Layouts/Dwindle-Layout/ for more
  hl.config({ dwindle = { preserve_split = true } })

  -- See https://wiki.hypr.land/Configuring/Layouts/Master-Layout/ for more
  hl.config({ master = { new_status = "master" } })

  -- See https://wiki.hypr.land/Configuring/Layouts/Scrolling-Layout/ for more
  hl.config({ scrolling = { fullscreen_on_one_column = true } })
  ```

## Known issues

### Layouts do not survive `hyprctl reload`

The plugin applies layouts with `hl.workspace_rule(…)` through `hyprctl eval`. Those rules
live only in the running Hyprland instance — nothing is written to your config. `hyprctl
reload` re-reads the config from scratch and discards them, so every workspace silently
falls back to the global `general:layout`.

You can see it directly:

```sh
noctalia msg plugin maddingo/hypr-layout-switcher:poller all cycle
hyprctl -j workspacerules   # [{ "workspaceString": "1", "enabled": true }]
hyprctl activeworkspace -j | grep tiledLayout   # "master"

hyprctl reload
hyprctl -j workspacerules   # []
hyprctl activeworkspace -j | grep tiledLayout   # back to "dwindle"
```

The widget follows along on its next poll, so the bar stays truthful — but the layout you
picked is gone, and nothing announced it.

### Noctalia's wallpaper rotation triggers that reload

This is the usual way the above is hit, and it is confusing because nothing the user does
is involved. It applies when the colour scheme is derived from the wallpaper *and* the
Hyprland theme template is enabled:

```toml
[theme]
source = "wallpaper"

    [theme.templates]
    builtin_ids = [ "alacritty", "hyprland" ]
```

Every wallpaper change recomputes the palette and regenerates the Hyprland template. That
generated file is pulled in from `hyprland.lua` with something like
`require("noctalia").apply_theme()`, which only runs at config load — so the new colours
reach Hyprland through a reload, and the reload takes the layout rules with it.

With automatic wallpaper rotation enabled, the layout therefore resets **once per rotation
interval**, on the clock. A user rotating hourly sees every workspace snap back to
`dwindle` once an hour, at the same minute past the hour, with no input of their own. The
Noctalia log dates the ticks if you want to confirm the correlation:

```sh
grep "automation set all outputs" ~/.cache/noctalia/noctalia.log
stat -c '%y' ~/.config/hypr/noctalia.lua   # written a fraction of a second later
```

Monitor hotplug can trigger the same thing out of band: an external display that drops the
link when it power-saves makes Noctalia re-apply the wallpaper for that output, which
regenerates the template again.

### Workarounds

None of these are fixes in the plugin — pick whichever costs you least:

- **Drop `"hyprland"` from `builtin_ids`.** Wallpaper rotation and the Alacritty template
  keep working; you lose wallpaper-derived window border colours, and the reloads stop.
- **Set `source` to a fixed palette** (`builtin`, `community`, or `custom`) instead of
  `"wallpaper"`, so rotating the wallpaper no longer recomputes the theme.
- **Turn off wallpaper automation**, if you only ever change wallpapers deliberately.
- **Declare the layouts in your Hyprland config** so a reload re-applies them:

  ```lua
  hl.workspace_rule({ workspace = "2", layout = "master" })
  ```

  Layouts then survive reloads, but a cycled layout still only lasts until the next
  reload, which returns the workspace to whatever the config declares rather than to
  `general:layout`.

A real fix would mean persisting the per-workspace layouts outside Hyprland's runtime
state and re-applying them after a reload — the plugin currently has no settings storage
and writes no files, so this is left open deliberately.
