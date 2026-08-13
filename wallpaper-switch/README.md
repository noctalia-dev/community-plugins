# Wallpaper Switch

Cycle, step, or randomize the wallpaper from a bar widget. Left click moves to
the next image in your wallpaper folder, right click goes back, middle click
picks a random one, and scrolling steps through them. The widget shows the
current wallpaper in its tooltip.

## Plugin

| Field | Value |
| --- | --- |
| ID | `kavya-nama/wallpaper-switch` |
| Entries | Bar widget: `cycle` |

## Usage

Add the widget to a bar in **Settings → Bar**, or in `config.toml`:

```toml
[widget.wallpaper-switch]
type = "kavya-nama/wallpaper-switch:cycle"
```

and include `wallpaper-switch` in the bar's `order` list.

The widget cycles through the images in the wallpaper folder configured for
the current theme mode. Gestures:

| Gesture | Action |
| --- | --- |
| Left click | Next wallpaper |
| Right click | Previous wallpaper |
| Middle click | Random wallpaper |
| Scroll up / down | Previous / next wallpaper |

All gestures are rebindable per widget instance in the widget's settings.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `glyph` | `string` | `photo` | Bar glyph shown for the widget. |
| `notify_on_switch` | `bool` | `true` | Show a notification with the new wallpaper name after switching. |
| `show_name` | `bool` | `false` | Display the current wallpaper file name next to the glyph. |

## IPC

The widget also accepts the same actions over IPC, which is useful for
keybinds or testing:

```sh
noctalia msg plugin kavya-nama/wallpaper-switch:cycle all next
noctalia msg plugin kavya-nama/wallpaper-switch:cycle all previous
noctalia msg plugin kavya-nama/wallpaper-switch:cycle all random
```

## Notes

- The widget reads the wallpaper folder for the current theme mode
  (`noctalia.wallpaperDirectory()`). If no folder is configured, switching
  shows an error notification.
- To keep its tooltip in sync with wallpaper changes made outside the widget
  (the built-in picker, other plugins), it runs `noctalia msg wallpaper-get`
  once per 30-second update interval. No other processes are spawned and no
  files are written.
- Supported image formats: jpg, jpeg, png, webp, bmp, gif, avif.