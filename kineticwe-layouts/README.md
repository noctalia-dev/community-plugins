# KineticWE Layouts

A bar widget that shows the current [KineticWE](https://github.com/notethene/KineticWE)
tiling layout under KWin and a dropdown panel to switch between the layouts you have
enabled. Rather than guessing, the plugin reads KineticWE's `/Tiling` DBus interface, so
the indicator stays in sync with layout keybinds, per-desktop layouts, and kwinrc changes.

## Plugin

| Field | Value |
| --- | --- |
| ID | `theblackdon/kineticwe-layouts` |
| Entries | Service: `bridge`; bar widget: `indicator`; panel: `layouts` |

## Requirements

- **KDE Plasma (KWin)** with **KineticWE** installed and built the standard way, which
  exposes the `/Tiling` DBus interface (`org.kde.KWin.Tiling`). Without it the widget
  shows an error tooltip and the panel explains that KineticWE must be rebuilt.
- **`qdbus-qt6`** (falls back to `qdbus6` / `qdbus`) on `PATH` — used to query and set the
  current tiling layout.
- **`dbus-monitor`** on `PATH` — used to subscribe to layout and desktop-switch signals.

## Usage

Add the widget from **Settings → Bar**, choose a section, and pick **KineticWE Layouts**
from the widget list. The bar shows the active layout's glyph and, with the `show_text`
setting on, its name. Left-click the widget to open the layouts panel, which lists every
layout enabled in kwinrc (`[Tiling] EnabledLayouts`); clicking one switches the active
output's current desktop straight away.

Open the panel from anywhere with:

```sh
noctalia msg panel-toggle theblackdon/kineticwe-layouts:layouts
```

KineticWE applies layouts per virtual desktop, so the indicator follows the active
output's current desktop as you switch desktops, cycle layouts with keybinds, or change
kwinrc settings.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_text` | `bool` | `true` | Show the layout name next to the glyph in the bar. When off, only the glyph is shown. |

## Notes

**Processes.** The plugin shells out to two KWin/KDE tools, nothing else:

- `qdbus-qt6 org.kde.KWin /Tiling org.kde.KWin.Tiling.currentLayout` — on load and
  whenever a signal fires, plus a 5-second self-heal poll.
- `qdbus-qt6 org.kde.KWin /Tiling org.kde.KWin.Tiling.enabledLayouts` — on the same
  cadence; keeps the panel's list in sync with kwinrc.
- `qdbus-qt6 org.kde.KWin /Tiling org.kde.KWin.Tiling.setLayout <kind>` — only when a
  layout is picked in the panel.
- `dbus-monitor --session "type='signal',interface='org.kde.KWin.Tiling'"
  "type='signal',interface='org.kde.KWin.VirtualDesktopManager',member='currentChanged'"`
  — a single long-lived stream that triggers the re-queries above; updates feel instant
  while the 5-second poll doubles as a self-heal if the stream dies.

**No network access. No filesystem reads or writes.** All state lives in the plugin's
in-memory state channel (`noctalia.state`) and is re-queried from the compositor; nothing
is written to disk.

**Compositor support.** KWin / KDE Plasma only — KineticWE's tiling DBus interface is
KWin-specific, so the plugin shows a placeholder under any other compositor.
