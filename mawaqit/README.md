# Mawaqit for Noctalia

Prayer times for Noctalia v5 — live countdown, notifications, and azan playback, with a bar widget and a panel view.

## Plugin

| Entry | ID | Type |
|---|---|---|
| Bar widget | `ycf/mawaqit:bar` | `[[widget]]` |
| Prayer times panel | `ycf/mawaqit:panel` | `[[panel]]` |
| Background fetcher | `ycf/mawaqit:fetcher` | `[[service]]` |

## Usage

- **Left click** the bar widget → cycles display mode: countdown → static time → prayer name only
- **Right click** the bar widget → open the prayer times panel

Toggle the panel directly:
```
noctalia msg panel-toggle ycf/mawaqit:panel
```

## Requirements

- `paplay` (PipeWire/PulseAudio) **or** `pw-cat` — only one is required, used for azan playback. If neither is installed, azan is silently skipped (a line is logged) and notifications still work normally.

## Settings

Open **Settings → Plugins → Mawaqit** to configure:

| Setting | Description |
|---|---|
| City / Country | Location used for prayer time lookups |
| Calculation method | One of the standard Islamic calculation conventions (MWL, ISNA, Makkah, Egypt, etc.) |
| School | Asr calculation convention — Shafi or Hanafi |
| Hijri day offset | Shift the displayed Hijri day by −1/0/+1 if the API date doesn't match local moon sighting |
| 12-hour format | Show prayer times as 12-hour (e.g. `5:23 AM`) instead of 24-hour |
| Show notifications | Notify at each prayer time |
| Play azan | Play an azan audio file at each prayer time |
| Azan file | Which of the three bundled azan tracks to play |
| Prayer time offsets (tune) | Per-prayer minute adjustment, −60 to +60, applied after fetching |

Bar widget settings (icon, colors, countdown/elapsed display, dynamic icon) are configured separately, from the widget's own settings menu.

## File structure

```
mawaqit/
├── plugin.toml
├── bar_widget.luau
├── panel.luau
├── service.luau
├── DecoType.ttf
├── thumbnail.webp
├── translations/
│   └── en.json
└── assets/
    ├── azan1.mp3
    ├── azan2.mp3
    └── azan3.mp3
```

## Development

To run this plugin from a local checkout while working on it:

```
noctalia msg plugins source add dev path ~/dev/mawaqit
noctalia msg plugins enable ycf/mawaqit
```

`.luau` edits hot-reload; manifest changes are picked up on the next config reload.

## Notes

- The background service fetches prayer times once daily from `api.aladhan.com`, sending the configured city/country/method/school as query parameters. It also fetches the following day's Fajr time in advance, for the countdown after Isha.
- Azan playback runs `paplay` or `pw-cat` against a bundled file in `assets/`; the running process is force-stopped (`pkill`) when the plugin exits or is disabled, and can also be stopped manually from the panel while azan is playing.
- `DecoType.ttf` is bundled and used to render the Arabic Hijri date and prayer-time announcement in the panel; it's loaded from the plugin's own directory.
