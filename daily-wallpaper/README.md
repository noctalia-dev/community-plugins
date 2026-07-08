# Daily Wallpaper

Fetches a daily wallpaper from Bing or NASA and applies it through the Noctalia 5 wallpaper API.

The service checks on startup and then every 10 minutes. It downloads at most one image per source per day, reuses the cached daily file when present, and removes cached Bing/NASA images older than 5 days.

Settings:

- Source: Bing or NASA.
- Locale: Bing market locale such as `en-US`, `de-DE`, or `fr-FR`. NASA ignores this setting.
