# noctwhspr

Noctalia companion for [hyprwhspr](https://github.com/goodroot/hyprwhspr) —
native speech-to-text for Linux. hyprwhspr is fast, accurate, private,
system-wide dictation: press a hotkey, talk, and your words land in whatever
you were typing — transcribed by local in-memory models (Whisper, Parakeet)
that never leave your machine, or by top cloud APIs if you point it there.
Its visuals even theme themselves to match your Noctalia theme.

This plugin puts hyprwhspr on your bar: the widget shows the dictation state
at a glance, left-click starts or stops a recording, and right-click restarts
the hyprwhspr service if it ever gets stuck.

## Plugin

| Field | Value |
| --- | --- |
| ID | `goodroot/noctwhspr` |
| Entries | Bar widget: `status` |

## Requirements

Install [`hyprwhspr`](https://github.com/goodroot/hyprwhspr) and set it up so
its `hyprwhspr.service` systemd user service exists. The widget drives
hyprwhspr's own tray script (`hyprwhspr-tray.sh`), which it looks up under the
install root — `/usr/lib/hyprwhspr` for the Arch/AUR package. Nothing else is
needed; the widget has no network access of its own.

## Usage

Enable the plugin in Settings → Plugins, then add the `status` widget to your
bar in Settings → Bar.

The glyph tracks the dictation state reported by hyprwhspr:

| Glyph | State |
| --- | --- |
| Filled record dot (error color) | Recording — dictation is capturing audio |
| Microphone (primary color) | Ready — service is up, waiting for a hotkey or click |
| Zzz | Model unloaded — first recording will load it |
| Microphone off | Service stopped |
| Warning triangle | Error — the tooltip explains what is wrong |

Interactions:

- **Left-click** — toggle recording (same as the hyprwhspr hotkey). If the
  service is stopped, this starts it first.
- **Right-click** — restart the `hyprwhspr.service` systemd user service.
- **Hover** — the tooltip shows the detailed status line, including error
  reasons when something is wrong.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `root` | `string` | `/usr/lib/hyprwhspr` | Directory hyprwhspr is installed under. Leave at the default unless hyprwhspr lives at a non-standard prefix; `HYPRWHSPR_ROOT` in Noctalia's environment is also honored. |

## Notes

- The widget is a thin shim over hyprwhspr's tray script — the same script
  that backs its Waybar module — so state detection stays in one place. It
  polls `<root>/config/hyprland/hyprwhspr-tray.sh status` every 2 seconds and
  renders the returned JSON.
- Spawned processes: the tray script on every poll and click; the script in
  turn queries `systemctl --user` and hyprwhspr's runtime state files.
  Right-click runs `systemctl --user restart hyprwhspr.service` through the
  script. No network calls and no filesystem writes are made by the plugin
  itself.
- If the widget shows "hyprwhspr not found", hyprwhspr is not installed at
  the configured root — point the `root` setting at your install prefix.
- Works on any compositor Noctalia runs on; the `hyprland` in the script path
  is historical, hyprwhspr itself supports Hyprland, Niri and friends.
