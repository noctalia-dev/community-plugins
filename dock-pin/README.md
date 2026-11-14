# Dock Pin

A bar widget that pins a bar in place. While the target bar uses smart
auto-hide, the pin glyph is dim; clicking it turns smart auto-hide off so the
bar stays always visible, and the pin lights up. Clicking again re-enables
smart auto-hide.

Useful for a bottom dock-style bar that should usually get out of the way but
sometimes needs to stay put while you arrange windows.

## Plugin

| Field | Value |
| --- | --- |
| ID | `tomaswade/dock-pin` |
| Entries | Bar widget: `pin`; service: `watcher` |

## Requirements

Install `noctalia` on `PATH` (the running shell binary itself — the plugin
calls `noctalia msg config-get` / `config-set` to read and flip the setting).

## Usage

Reference the widget by its full name in any regular bar's widget list:

```toml
[bar.default]
start = [ "launcher", "workspaces", "tomaswade/dock-pin:pin" ]
```

The pin usually lives on a regular bar (for example the top bar) and controls
another bar — by default `bar.dock.smart_auto_hide` — so you can pin your
bottom dock from wherever the pin sits. See Settings to point it at a
different bar or key.

- Dim pin: the target bar is in smart auto-hide mode.
- Lit pin (accent color): the bar is pinned and always visible.
- Click to toggle; a desktop notification confirms each change.
- The widget checks the setting every 2 seconds, so external changes (for
  example from the settings GUI) are reflected automatically.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `config_path` | `string` | `bar.dock.smart_auto_hide` | Config path of the boolean to toggle. Point it at any bar's `smart_auto_hide` or `auto_hide` key. |
| `glyph` | `glyph` | `pin-filled` | Glyph shown on the bar |
| `pin_color` | `color` | `primary` | Color of the pin while pinned |

## Notes

The toggle writes through `noctalia msg config-set`, which validates the value,
persists it to `settings.toml`, and hot-reloads — the change survives restarts.
