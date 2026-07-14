# Daily Wallpaper

Fetches a daily wallpaper from Bing or NASA and applies it through the Noctalia 5 wallpaper API.

The service checks on startup and then every 10 minutes. It downloads at most one image per source and Bing locale per day, stores its files in a dedicated `daily-wallpaper` directory, and removes cached images older than 5 days. Repeated failures are logged, but error notifications are limited to once per day.

Settings:

- Source: Bing or NASA.
- Locale: Bing market locale such as `en-US`, `de-DE`, or `fr-FR`. NASA ignores this setting.
