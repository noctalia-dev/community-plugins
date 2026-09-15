# World Radio

Browse thousands of internet radio stations from around the world and play
them straight from a Noctalia panel - each country shows its flag, and while a
station plays, its logo appears in the media widget thanks to mpv's
`--cover-art-files`.

## Plugin

| Field   | Value                                        |
| ------- | -------------------------------------------- |
| ID      | `nilsonlinux/world-radio`                    |
| Entries | Bar widget: `radio`; Panel: `Panel`          |

## Features

- **Dashboard** - two stat cards (total stations and total countries) fetched
  from the radio-browser.info stats API, animated with a count-up effect every
  time the panel opens. Below them, genre and decade chips, then a searchable
  list of every country sorted by station count with each country's flag.
- **Tappable stat cards** - tap **Total de estações** to open every station in
  the directory ordered by votes (`Load more` fetches the next 100), or tap
  **Total de países** to open the full country list (paginated 50 at a time).
- **Paged country list** - the dashboard's "Todos os países" drawer and the
  **All countries** view render 50 countries at a time with a `Load more`
  button, so the full ~240-country list never locks the panel while opening.
- **Per-country stations** - tap a country to list its stations ordered by
  votes. A search box above the list filters them by name, and rows show the
  station's favicon (downloaded on demand), codec, bitrate and vote count,
  with a `Load more` button for the next page (100 stations per page).
- **Favorites** - star any station to save it; all favorites live in one
  place and are persisted to disk.
- **Local radios** - add your own stations by URL (name is optional and
  guessed from the host). Each one can be played, favorited, or removed;
  they persist across restarts in a separate file.
- **Playback via mpv** - stations are played through `mpv` at 85% volume
  (falls back to `ffplay` when mpv is missing). Starting a new station stops
  the previous one. The mini player shows a pulsing green live icon while a
  station is playing.
- **Station logo in the media widget** - the playing station's favicon is
  passed to mpv via `--cover-art-files`, which makes mpv-mpris publish it as
  `mpris:artUrl`; Noctalia's media tab then shows the station's own logo.
- **Now playing on the bar** - while a station plays, the bar widget shows its
  name next to the icon (configurable, see `show_now_playing`) and a tooltip
  with "Now playing: <station>".
- **Two languages** - English and `pt-BR` translations.

## Requirements

Install `mpv` and make sure it is on `PATH`. If `mpv` is missing, playback
automatically falls back to `ffplay` (provided by `ffmpeg`), also expected on
`PATH`.

- `mpv` - the primary player used by the plugin (declared dependency).
- `ffmpeg` - only used as the `ffplay` fallback when `mpv` is not installed
  (declared dependency).
- `mpv-mpris` - *optional*. Required only for the station's logo to appear in
  Noctalia's media widget/tab: mpv embeds the cover via `--cover-art-files`,
  but `mpv-mpris` is what publishes it as `mpris:artUrl` through MPRIS, and
  Noctalia reads the artwork from exactly that property. Without it Noctalia
  sees no MPRIS player, so no now-playing info and no artwork.
- **Network** - reaching `radio-browser.info` is required for the country
  list, the stats cards, all station lists and searches. No API key or
  account is needed; the service is a public, free API.
- The panel only works while a network connection is available to reach
  `radio-browser.info`.

## Usage

Open the panel directly with:

```sh
noctalia msg panel-toggle nilsonlinux/world-radio:Panel
```

or click the radio widget (`radio`) placed in the bar.

1. **Dashboard** - search or scroll the country list; the stat cards show the
   total of stations and countries with a count-up animation on open. Tap a
   country to open it.
2. **All stations** - tap the **Total de estações** card to browse the whole
   directory ordered by votes (100 per page). Tap **Total de países** to open
   the full country list (50 per page). Use `Load more` to fetch the next
   page.
3. **Country view** - type in the search box to filter stations by name, tap
   the play button on a station to start it (it becomes a stop button while
   playing), the star to favorite it, or `Load more` for the next page.
4. **Favorites** - the star button in the header lists every station you
   starred.
5. **Local radios** - the broadcast button in the header opens your saved
   stations; `+` lets you add one with a stream URL (and an optional name).
   Use the trash button to remove it.
6. While a station plays, check the media widget for the station's logo, and
   the bar for the now-playing name.

## Settings

### Bar Widget

| Setting            | Type    | Default  | Description                                             |
| ------------------ | ------- | -------- | ------------------------------------------------------- |
| `glyph`            | `glyph` | `radio`  | Icon shown in the bar for the widget.                   |
| `show_now_playing` | `bool`  | `true`   | Show the currently playing station name next to the icon (the tooltip always keeps it). |

## IPC

Only the panel toggle is exposed:

```sh
noctalia msg panel-toggle nilsonlinux/world-radio:Panel
```

While a station plays, the plugin publishes `{ name, uuid, url }` on the
`playing` state channel (`noctalia.state`); `widget.luau` watches it to update
the bar text, tooltip and icon.

## Notes

- The plugin has no background service: all fetching, caching and playback is
  driven from the panel, so nothing runs while the panel is closed.
- **Network calls** - the plugin talks to `radio-browser.info`
  (`de1.api.radio-browser.info`) using `/json/countries`, `/json/stats`, and
  `/json/stations/search` (`hidebroken=true`, ordered by votes) with a
  `User-Agent` of `nilsonlinux/world-radio/1.0.0`. No credentials are sent.
- **Processes** - playback spawns `mpv` (or `ffplay`) per station; the PID is
  stored in `player.pid` so the next play/Stop kills it cleanly. The debounce
  and animation timers shell out to `sleep`, and playback cleanup uses `kill`.
- **Files** - runtime data lives in the plugin's data directory and survives
  reloads: `countries.json` and `stats.json` (4h cache), `favorites.json`,
  `custom-stations.json`, `playing.json` (mini player state), `thumbs/`
  (downloaded favicons) and `player.pid`. All of them can be safely deleted
  to force a refresh.
- While a station plays, the mini player state is persisted to `playing.json`.
  If the plugin reloads (for example after toggling another plugin in
  Settings), the panel restores the mini player on next open as long as the
  player process is still alive; deleting `playing.json` clears it.
- Station logos sometimes fail to download (some favicons return 403/404) -
  playback is never blocked by that; the station just plays without artwork.

## License

MIT