# Beszel Desktop

Monitor remote servers, homelab nodes, and other machines live (~1 Hz) from a [Beszel](https://beszel.dev) hub — rendered in compact Noctalia bar pills and an attached real-time telemetry panel with CPU/memory sparklines and a per-core heatmap.

![Beszel Desktop live telemetry panel in Noctalia Shell](https://raw.githubusercontent.com/henriksvensson/beszel-desktop/main/docs/assets/noctalia-panel.gif)

## Plugin

| Field | Value |
| --- | --- |
| ID | `henriksvensson/beszel-desktop` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `service` |

## Requirements

- [`beszel-relay` and `beszel-ctl`](https://github.com/henriksvensson/beszel-desktop) installed on `PATH` (or in `~/.local/bin/`) and connected to a Beszel hub (`>= 0.13.0`).
  - Quick install & setup (downloads SHA-256-verified binaries and launches `beszel-ctl init`):
    ```sh
    curl -fsSL https://raw.githubusercontent.com/henriksvensson/beszel-desktop/main/packaging/install.sh | sh
    ```
  - Or install via Nix / Cargo / [GitHub Releases](https://github.com/henriksvensson/beszel-desktop/releases), then run `beszel-ctl init`.
- Noctalia Shell `v5.5+` (`plugin_api = 48`).

## Usage

1. Install and enable `henriksvensson/beszel-desktop` in **Noctalia Settings → Plugins** (or link `shells/noctalia` into `~/.local/share/noctalia/plugins/beszel-desktop` for local development).
2. Add **Beszel Desktop** to your bar in **Noctalia Settings → Bar**.
   - If `beszel-relay` isn't installed or configured yet, clicking the bar widget opens an onboarding card where you can copy the install & setup command in one click; the widget connects automatically as soon as `beszel-ctl init` completes.
   - To pin multiple remote hosts side by side on your bar, add another **Beszel Desktop** widget in **Noctalia Settings → Bar**, click it to open the panel, select the host you want, and click **Pin to bar** (you can also scroll on any bar pill to cycle hosts temporarily, or set **Host** directly in the widget's settings).
3. Click any host pill to open the attached telemetry panel focused on that host (with host switcher chips, hover-scrubbable CPU & memory graphs, and a frame-interpolated per-core CPU heatmap), or toggle the panel via IPC:

```sh
noctalia msg panel-toggle henriksvensson/beszel-desktop:panel
```

## Settings

### Plugin Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `ctl_path` | `string` | `"beszel-ctl"` | Path or binary name for `beszel-ctl` (also checks `~/.local/bin/beszel-ctl`). |
| `socket_path` | `string` | `""` | Optional override for the `beszel-relay` Unix socket path. |
| `stale_seconds` | `int` | `5` | Seconds without a new sample before metrics are marked stale (`2`–`60`). |
| `warn_threshold` | `int` | `70` | Percentage threshold (`10`–`99`) for warning severity coloring. |
| `danger_threshold` | `int` | `90` | Percentage threshold (`11`–`100`) for danger severity coloring. |

### Bar Widget Settings (`henriksvensson/beszel-desktop:bar`)

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `system` | `string` | `""` | Beszel system name or ID to display (leave empty for the first available host). |
| `show_host_name` | `bool` | `true` | Show the host name prefix before the CPU and memory readouts. |

## Notes

- **Spawned processes:** The singleton `service` entry runs one long-lived `beszel-ctl watch --raw --reconnect` process (reading from the local user-only Unix socket `$XDG_RUNTIME_DIR/beszel-relay.sock`) and shares parsed snapshots/samples through `noctalia.state`. Clicking **Pin to bar** in the panel invokes `noctalia msg config-set widget.<id>.system "<host>"` to persist the chosen host for that bar widget.
- **Network & credentials:** This plugin makes no network requests, writes no files, and never accesses Beszel hub credentials (credentials stay inside `beszel-relay`).
- **Auto-pause:** Disabling the plugin stops the `beszel-ctl` stream, allowing `beszel-relay` to pause upstream `rt_metrics` polling automatically.
