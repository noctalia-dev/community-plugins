# Holy Quran Radio

Live stream of the Egyptian Holy Quran Radio (إذاعة القرآن الكريم من القاهرة,
on air since 1964) with today's programme schedule from
https://misrquran.gov.eg/home.

## Plugin

| Field | Value |
| --- | --- |
| ID | `muhammadessam/misr-quran-radio` |
| Entries | Bar widget: `radio`; panel: `panel`; service: `service` |

## Requirements

Install `mpv`, `pkill` (procps), and `xdg-open` (xdg-utils, for the station-site
button) on `PATH`. Playback is one detached `mpv --no-video` process; stopping
it uses `pkill`.

## Usage

Add the `radio` widget to the bar. It shows `Live` while the stream plays and
`Quran` otherwise; click it to open the panel:

```sh
noctalia msg panel-toggle muhammadessam/misr-quran-radio:panel
```

The panel has Play / Stop for the live HLS stream, the current programme
(matched against Cairo time), and today's schedule list. The `Station site`
button opens https://misrquran.gov.eg/home and `Copy stream URL` copies the
stream URL to the clipboard. The panel layout is right-aligned for Arabic.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `stream_url` | `string` | station HLS URL | Live HLS stream. Advanced: change only if the station moves it. |
| `refresh_minutes` | `int` | `30` | Minutes between programme schedule fetches (clamped to 5–720). |
| `show_text` (widget) | `bool` | `true` | Show Live / Quran next to the icon. |
| `glyph` (widget) | `glyph` | `radio` | Bar widget icon. |

## IPC

Headless actions for the service, useful for testing:

```sh
noctalia msg plugin muhammadessam/misr-quran-radio:service all request '{"action":"toggle"}'
noctalia msg plugin muhammadessam/misr-quran-radio:service all request '{"action":"diagnose"}'
```

Actions: `play`, `stop`, `toggle`, `refresh`, `diagnose`. `diagnose` writes the
full state as JSON to the plugin data dir and logs a one-line summary.

## Notes

- Reads the public schedule API at `https://API.misrquran.gov.eg` (POST
  `/api/RadioProgrammeSchedule/GetByDay`) and plays the public live HLS
  stream. No authentication, no other network calls.
- Files written: only the `diagnose` dump under the plugin data dir.
- The live HLS URL is hardcoded as the default `stream_url`; if the station
  rotates its CDN link and play goes silent, paste the fresh `m3u8` URL from
  the station site into the setting.
