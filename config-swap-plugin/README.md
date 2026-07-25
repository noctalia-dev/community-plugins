# Config Swap

Config Swap are a tools for swap configuration with one click on hot reload

## Plugin

| Field | Value |
| --- | --- |
| ID | `nzlov/daily-wallpaper` |
| Entry | Service: `service` |

## Usage

Enable the plugin in Settings → Plugins. Its headless service checks for the
current image on startup and every ten minutes, applying at most one new image
per source and Bing locale each day.

Choose Bing or NASA under the plugin's settings. Bing accepts a market locale
such as `en-US`, `de-DE`, or `fr-FR`; NASA ignores the locale setting.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `source` | `select` | `bing` | Selects Bing or NASA as the daily image source. |
| `locale` | `string` | *(automatic)* | Bing market locale; an empty value uses the service default. |

## Notes

The service contacts the selected provider and downloads images into a
dedicated `daily-wallpaper` cache directory. It removes cached images older
than five days. Repeated failures are logged, but error notifications are
limited to once per day.
