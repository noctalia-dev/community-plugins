# Daily Wallpaper

Daily Wallpaper fetches Bing's image of the day or NASA's image of the day,
applies it through Noctalia's wallpaper API, and shows the caption/credit that
came with it — on the bar, in a panel, and on the desktop.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nzlov/daily-wallpaper` |
| Entries | Service: `service`; bar widget: `widget`; panel: `panel`; desktop widget: `desktop` |

## Requirements

Install `xdg-utils` on `PATH` (for the panel's "Learn more" button, via `xdg-open`).

## Usage

Enable the plugin in Settings → Plugins. Its headless service checks for the
current image on startup and every ten minutes, applying at most one new image
per source and Bing locale each day.

Choose Bing or NASA under the plugin's settings. Bing accepts a market locale
such as `en-US`, `de-DE`, or `fr-FR`; NASA ignores the locale setting.

Add the `widget` bar entry and/or the `desktop` desktop widget from Settings
to see today's caption. Clicking the bar glyph (or running
`noctalia msg panel-toggle nzlov/daily-wallpaper:panel`) opens the full panel
with the caption, credit (Bing only), and a "Learn more" link — Bing's quiz
page, or NASA's full article about the image.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `source` | `select` | `bing` | Selects Bing or NASA as the daily image source. |
| `locale` | `string` | *(automatic)* | Bing market locale; an empty value uses the service default. |
| `widget.glyph` | `glyph` | `photo` | Bar icon. |
| `widget.show_text` | `bool` | `true` | Show a truncated caption next to the bar glyph. |
| `widget.max_chars` | `int` | `28` | Max caption length shown on the bar before truncating with an ellipsis. |

## IPC

```sh
noctalia msg plugin nzlov/daily-wallpaper:service all refresh
```

## Notes

The service contacts the selected provider and downloads images into a
dedicated `daily-wallpaper` cache directory. It removes cached images older
than five days. Repeated failures are logged, but error notifications are
limited to once per day.

Neither source gives a wallpaper-application step any reason to keep the
caption text that comes with the image, so it is captured separately at the
point each source resolves and published as plugin state for the bar widget,
panel, and desktop widget to display. Bing's `copyright` field is one caption
line, e.g. "Runners at the base of Victoria Falls, Zimbabwe (© Byron.../Getty
Images)", which is split into a title and a credit; NASA's gallery-item
caption is a single sentence with no separate credit line.
