# XWayland Indicator

Indicator showing whether the active window is using XWayland in Umbriel.

## Plugin

| Field | Value |
| --- | --- |
| ID | `tordex/xwayland` |
| Entries | Bar widget: `widget`; service: `service` |

- `bar` - bar widget. Shows the focused window type glyph (XWayland or Wayland).
- `service` - the only entry that talks to the compositor. It holds `umbriel subscribe workspaces,windows` open,
  republishes every pushed line as the snapshot each UI entry reads.

## Requirements

- Noctalia plugin API 28 or newer.
- `umbriel` on `PATH`, inside a running Umbriel session, with the `workspaces` and `windows` subscription families.
  Every other compositor gets a hidden widget.

## Usage

Add the **XWayland Indicator** widget to a bar from Settings → Bar.

## Settings

### Bar Widget

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `xwayland_glyph` | `glyph` | `letter-x` | Glyph for **XWayland** windows |
| `wayland_glyph` | `glyph` | `letter-w` | Glyph for **Wayland** windows |
| `hide_on_wayland` | `bool` | `true` | Hide on Wayland window |
