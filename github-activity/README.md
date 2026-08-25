# GitHub Activity for Noctalia

A native, theme-aware GitHub contribution calendar for the Noctalia v5 bar.
See your activity at a glance without opening GitHub in a browser.

![GitHub Activity panel](github-activity/thumbnail.webp)

## Highlights

- Compact bar widget showing a configurable contribution metric or only the GitHub icon.
- Interactive annual heatmap with per-day activity on hover.
- Today, current streak, best streak, and annual contribution statistics.
- Configurable automatic refresh every 15, 30, or 60 minutes, plus manual refresh from the panel.
- Theme-aware colors that follow the active Noctalia palette.
- Offline-friendly cache that preserves the latest successful result.

## Requirements

- Noctalia v5 with plugin API 24 or newer.
- [GitHub CLI](https://cli.github.com/) (`gh`), authenticated with the account
  whose activity you want to display.
- `xdg-open` (`xdg-utils` on Arch Linux) for the **Open profile** button.

Authenticate GitHub CLI before enabling the plugin:

```bash
gh auth login -h github.com
```

## Usage

Enable **GitHub Activity** in Noctalia's plugin manager, add the `activity`
widget to a bar, and click it to open the calendar. Right-click the widget or
use the refresh button in the panel to update immediately.

Choose the automatic refresh interval in Noctalia's plugin settings. The
default is 30 minutes; 15- and 60-minute intervals are also available.
The widget tooltip and calendar panel show when contribution data was last
updated and the selected automatic refresh interval.

Each bar-widget instance can independently show only the GitHub icon or pair it
with today's contributions, the current streak, or the annual contribution
total. Configure these presentation choices from that widget's own settings.

The panel can also be toggled through IPC:

```bash
noctalia msg panel-toggle alexmnrs/github-activity:calendar
```

See the [plugin README](github-activity/README.md) for complete usage,
troubleshooting, compatibility, and privacy information.

## Privacy

The plugin requests contribution data through `gh api graphql`. GitHub CLI
remains the sole owner of authentication: the plugin never reads, stores, or
displays a GitHub token.

## Project structure

The installable plugin lives in [`github-activity/`](github-activity/).
`catalog.toml` indexes it as a Noctalia source, while tests and development
configuration remain at the repository root.

## Local development

Add this checkout as a local source, enable the plugin, then add **GitHub
Activity** from Noctalia's bar widget picker:

```bash
noctalia msg plugins source add github-activity-dev path "$(pwd)"
noctalia msg plugins enable alexmnrs/github-activity
```

Luau source changes hot-reload. Manifest changes require a Noctalia config
reload. The optional standalone tests require the `luau` command:

```bash
luau tests/activity_spec.luau
```

## License

[MIT](LICENSE)
