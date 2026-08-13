# Mihomo Control

Monitor and control a Mihomo (Clash Meta) instance right from the Noctalia
bar: live traffic, proxy mode, proxy-group selection, latency tests and active
connections. It talks to the Mihomo external controller, which can run on this
machine (`127.0.0.1`) or on a remote host — just configure the IP, port and
secret.

## Plugin

| Field   | Value                       |
| ------- | --------------------------- |
| ID      | `mdj2812/mihomo-control`    |
| Entries | Bar widget: `widget`; panel: `panel`; service: `service`; shortcut: `mode` |

## Usage

Add the **Mihomo Control** widget from the Add-widget picker. It shows the
current proxy mode (rule / global / direct); hover it for the connection
status, live download and upload rates, connection count and each proxy
group's current selection. Left-click the widget to toggle the control panel,
or open it with:

```sh
noctalia msg panel-toggle mdj2812/mihomo-control:panel
```

The panel lets you switch the proxy mode (rule / global / direct), restart the
server, refresh the status, and manage every proxy group. Each group card
lists all of its members with their latency — sourced from mihomo's health
checks and refreshed by the group's **Test latency** button. Each card also
shows an overall latency (the selected member's, or the best tested one) right
in its subtitle, visible without expanding. Member lists are collapsed by
default; click a group header to expand it. Click a member to select it; the
current selection is marked with a dot. Use **Test all** next to the Proxy
groups heading to run a latency test on every group at once.

Add the **Mihomo: Rule** shortcut from Settings → Control Center shortcuts to
quickly toggle between rule and global mode.

Before the widget shows anything, enable the plugin's `service` entry — it owns
all communication with the external controller and streams the traffic data.

## Settings

| Setting             | Type    | Default      | Description                                                                 |
| ------------------- | ------- | ------------ | --------------------------------------------------------------------------- |
| Host                | string  | `127.0.0.1`  | Hostname or IP of the Mihomo external controller.                           |
| Port                | string  | `9090`       | Port of the Mihomo external controller.                                     |
| Secret              | string  | *(empty)*    | `secret` from your Mihomo config; empty when authentication is disabled.    |
| HTTPS               | bool    | off          | Use `https://` (external-controller-tls or a TLS reverse proxy).            |
| Allow insecure TLS  | bool    | off          | Skip certificate verification for self-signed TLS controllers.              |
| Test URL            | string  | `https://www.gstatic.com/generate_204` | URL used for latency tests; empty uses each group's configured test URL. |
| Refresh interval    | int     | `2`          | Seconds between status polls (1–60); traffic rates stream in real time.     |

## IPC

The service exposes two IPC events for scripting and debugging:

```sh
noctalia msg plugin mdj2812/mihomo-control:service all refresh
noctalia msg plugin mdj2812/mihomo-control:service all cmd '{"op":"mode","mode":"global"}'
```

`refresh` re-polls version, config, connections and proxy groups. `cmd` accepts
the same command tables the panel sends (`mode`, `select`, `delay_test`,
`delay_test_all`, `restart`, `close_connections`, `refresh`).

## Notes

- The plugin only talks HTTP to the configured external controller. It spawns
  no processes, runs no external commands, and writes no files.
- The bar widget and card use the Clash cat logo (`icon.png`), the official
  mascot of the Clash / mihomo project. In the bar widget the cat is tinted by
  connection status: green online, amber while connecting, red offline; the
  panel uses the neutral logo next to its own status indicator.
- The traffic rate uses mihomo's streaming `GET /traffic` endpoint; status,
  connections and proxy groups are polled every refresh interval.
- The secret is stored in your Noctalia config and sent as the standard
  `Authorization: Bearer <secret>` header. It is sent in plain text unless
  HTTPS is enabled — use HTTPS for remote controllers.
- **Restart** posts to `/restart`, which re-executes the core; the plugin
  reconnects automatically once it is back. There is no API endpoint that
  stops the core — switching the mode to `direct` is the closest equivalent.
- A latency test where every node fails is reported as *all nodes timed out*:
  mihomo answers the delay endpoint with HTTP 504 in that case. If that keeps
  happening, set **Test URL** to an endpoint your network can reach.

## Development

- `service.luau` — headless API backend, publishes `mihomo.*` state.
- `widget.luau` — bar widget (rates + tooltip).
- `panel.luau` — control panel.
- `shortcut.luau` — rule/global mode toggle.
- `translations/` — user-facing strings.
