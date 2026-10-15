# Dropover

A floating file staging shelf and in-place drag target for Noctalia shell and Niri. Stash files from file managers, clipboards, or anywhere on screen, and seamlessly drag them into applications or copy them on demand.

## Plugin

| Field | Value |
| --- | --- |
| ID | `pyrider3/dropover` |
| Entries | Bar widget: `dropover-widget`; panel: `dropover-panel` |

## Requirements

Install `python3` and `wl-copy` (from the `wl-clipboard` package) on `PATH`. GTK4 and PyGObject are also required for floating drop and drag-out surfaces on Wayland.

## Usage

Add the `dropover-widget` to your bar in Settings → Bar. Click the bar icon to toggle the staging panel, or toggle it directly via IPC:

```sh
noctalia msg panel-toggle pyrider3/dropover:dropover-panel
```

### Keybindings and Gestures

You can bind hotkeys in your compositor config (for example in `niri`):

- **In-place Magnetic Drop Zone**: Bind `Mod+Z` to spawn the frosted drop zone directly under cursor. Drag any files onto it and release to stash them immediately.
- **In-place Drag-out Shelf**: Bind `Mod+Shift+Z` to summon the floating drag shelf. Drag individual cards directly into target windows (such as chat apps, browser upload zones, or terminals), or drag the "Drag All" pill to move all stashed files at once.
- **Toggle Shelf Panel**: Bind `Mod+Shift+D` to toggle the full Noctalia shelf panel.

### Panel Shortcuts

When the panel is open:

- Press `Space` to Quick Look preview the first stashed file.
- Press number keys `1` to `9` to instantly copy the corresponding file to the clipboard.
- Click "From Clipboard" to ingest files copied in file managers (Ctrl+C).

## Notes

- Staged file paths are persisted in `$XDG_STATE_HOME/noctalia/plugins/data/pyrider3/dropover/shelf.json`.
- Files themselves are never moved or duplicated; Dropover stores absolute path references.
- Floating windows use the Wayland application IDs `dev.noctalia.dropover.drop` and `dev.noctalia.dropover.shelf`. Configure your window manager to open them floating.
