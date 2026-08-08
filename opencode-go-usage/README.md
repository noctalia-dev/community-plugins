# OpenCode Go Usage

OpenCode Go Usage is a Noctalia bar plugin that shows local OpenCode token usage
and estimated OpenCode Go limits in a detail panel.

## Plugin

| Field | Value |
| --- | --- |
| ID | `elrondforwin/opencode-go-usage` |
| Entries | Bar widget: `bar`; service: `usage-service`; panel: `panel` |

## Requirements

Install the `opencode` command and make sure it is available on `PATH`. The
plugin uses `opencode db` to read the local OpenCode database.

## Usage

1. Enable **OpenCode Go Usage** in Noctalia.
2. Add the **OpenCode Go Usage** bar widget from the widget picker.
3. Open the details with the widget, or run:

   ```sh
   noctalia msg panel-toggle elrondforwin/opencode-go-usage:panel
   ```

4. Right-click the bar widget to refresh immediately.

No manual credentials are required. After signing in to OpenCode Go, the
plugin detects the local login from `~/.local/share/opencode/auth.json`.
`OPENCODE_DATA_DIR` and `XDG_DATA_HOME` are also respected.

The panel displays:

- Rolling five-hour, weekly, and monthly estimated Go usage.
- Today's input, output, and cache-read tokens.
- Today's cost and session count.
- A seven-day token graph.
- Usage grouped by model.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_minutes` | `int` | `5` | Local database refresh interval in minutes, from 1 to 120. |
| `show_limits` | `bool` | `true` | Show estimated OpenCode Go limits. |
| `show_usage` | `bool` | `true` | Show local token and cost usage. |
| `show_percentage_label` | `bool` | `true` | Show the percentage beside the bar glyph. |
| `pin_window` | `select` | `rolling` | Limit shown in the bar: rolling, weekly, or monthly. |
| `display_mode` | `select` | `remaining` | Show remaining or used percentage in the bar. |
| `glyph` | `select` | `activity` | Glyph shown in the bar widget. |

## IPC

Request an immediate refresh through the service:

```sh
noctalia msg plugin elrondforwin/opencode-go-usage:usage-service all refresh
```

The panel can also be opened directly:

```sh
noctalia msg panel-toggle elrondforwin/opencode-go-usage:panel
```

## Notes

OpenCode Go limits are estimated locally using the standard caps used by
OpenQuota: `$12` per rolling five hours, `$30` weekly, and `$60` monthly.
They are based only on `opencode-go` costs recorded on this device. Usage from
other devices, or sessions not yet written to the local database, is not
included.

The plugin does not make network requests. It reads `auth.json` to detect a Go
login, runs the local `opencode db` command, and writes only its cached
snapshot to Noctalia's plugin data directory. The OpenCode API key is never
sent, logged, or stored in the plugin cache.

Built with Deepseek V4 Flash 0731 and highly inspired by [OpenQuota](https://github.com/deviffyy/OpenQuota)
