# Beszel Desktop

Monitor remote servers, homelab nodes, and other machines live (~1 Hz) from a [Beszel](https://beszel.dev) hub — rendered in customizable Noctalia bar pills and an attached real-time telemetry panel with CPU, memory, GPU, network I/O, disk/storage, per-core heatmap, vitals, and container metrics.

![Beszel Desktop live telemetry panel in Noctalia Shell](https://raw.githubusercontent.com/henriksvensson/beszel-desktop/main/docs/assets/noctalia-panel.gif)

## Plugin

| Field | Value |
| --- | --- |
| ID | `henriksvensson/beszel-desktop` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `service` |

## Requirements

- [`beszel-relay` and `beszel-ctl`](https://github.com/henriksvensson/beszel-desktop) installed on `PATH` (or in `~/.local/bin/` / `~/.cargo/bin/`) and connected to a Beszel hub (`>= 0.13.0`). Install using any of the package-manager or versioned release options, then run `beszel-ctl init`:
  - **Cargo (crates.io):**
    ```sh
    cargo install beszel-relay beszel-ctl
    ```
  - **Homebrew (Linux):**
    ```sh
    brew install henriksvensson/tap/beszel-desktop
    ```
  - **Nix flakes:**
    ```sh
    nix profile install github:henriksvensson/beszel-desktop
    ```
  - **Versioned packages:** Download `.deb`, `.rpm`, or release tarballs (with `SHA256SUMS`) from [GitHub Releases](https://github.com/henriksvensson/beszel-desktop/releases).
- Noctalia Shell `v5.5+` (`plugin_api = 48`).

## Usage

1. Install and enable `henriksvensson/beszel-desktop` in **Noctalia Settings → Plugins** (or link `shells/noctalia` into `~/.local/share/noctalia/plugins/beszel-desktop` for local development).
2. Add **Beszel Desktop** to your bar in **Noctalia Settings → Bar**.
   - If `beszel-relay` isn't installed or configured yet, clicking the bar widget opens an onboarding card with package-manager install instructions and a one-click copy button; the widget connects automatically as soon as `beszel-ctl init` completes.
   - To monitor multiple remote hosts side by side on your bar, add additional **Beszel Desktop** widgets in **Noctalia Settings → Bar** and set **Host** on each instance (unpinned widgets also support scrolling to cycle hosts).
   - Customize what each bar widget displays (host name, CPU, memory, GPU, temperature, disk, and split/combined/download/upload network throughput) independently per bar instance.
3. Click any host pill to open its attached telemetry panel, or toggle the panel via IPC:

```sh
noctalia msg panel-toggle henriksvensson/beszel-desktop:panel
```

## Settings

### Plugin Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `notify_alerts` | `bool` | `true` | Send a desktop notification when a Beszel hub alert triggers on a monitored host. |
| `warn_threshold` | `int` | `70` | Percentage threshold (`10`–`99`) for warning severity coloring. |
| `danger_threshold` | `int` | `90` | Percentage threshold (`11`–`100`) for danger severity coloring. |
| `stale_seconds` | `int` | `5` | Seconds without a new sample before metrics are marked stale (`2`–`60`, advanced). |
| `ctl_path` | `string` | `"beszel-ctl"` | Path or binary name for `beszel-ctl` (also checks `~/.local/bin/beszel-ctl`, advanced). |
| `socket_path` | `string` | `""` | Optional override for the `beszel-relay` Unix socket path (advanced). |

### Panel Settings (`henriksvensson/beszel-desktop:panel`)

Sections automatically hide themselves on hosts that do not report the corresponding metric.

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_vitals` | `bool` | `true` | Show the compact vitals strip (OS/CPU, uptime, pending OS/security updates, failed systemd services, peak temperature, and battery state). |
| `show_load` | `bool` | `false` | Show 1/5/15-minute load averages (with core count context) in the vitals strip. |
| `show_cores` | `bool` | `true` | Show the frame-interpolated per-core CPU heatmap. |
| `show_swap` | `bool` | `true` | Show swap usage under the memory graph whenever swap is in use. |
| `show_gpu` | `bool` | `true` | Show primary GPU utilization sparkline, VRAM usage, and power draw. |
| `show_network` | `bool` | `true` | Show live download and upload throughput rates with a dual-series sparkline. |
| `show_disk` | `bool` | `true` | Show root and extra mounted disk usage bars, live disk read/write rates, and degraded storage pool warnings. |
| `show_containers` | `bool` | `false` | Show top Docker/Podman containers by CPU usage. |

### Bar Widget Settings (`henriksvensson/beszel-desktop:bar`)

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `system` | `string` | `""` | Beszel system name or ID to display (leave empty for the first available host). |
| `show_host_name` | `bool` | `true` | Show the host name prefix before the metrics. |
| `show_cpu` | `bool` | `true` | Show live CPU percentage. |
| `show_memory` | `bool` | `true` | Show live memory percentage. |
| `show_gpu` | `bool` | `false` | Show primary GPU utilization percentage (auto-hides if absent). |
| `show_temp` | `bool` | `false` | Show peak sensor temperature (auto-hides if absent). |
| `show_disk` | `bool` | `false` | Show root disk usage percentage (auto-hides if absent). |
| `network_mode` | `select` | `"off"` | Bar network readout: `off`, `split` (download & upload), `combined`, `download`, or `upload`. |

## Notes

- **Spawned processes:** The singleton `service` entry runs one long-lived `beszel-ctl watch --raw --reconnect` process (reading from the local user-only Unix socket `$XDG_RUNTIME_DIR/beszel-relay.sock`) and shares parsed snapshots/samples through `noctalia.state`. Clicking the bell button in the panel header runs `beszel-ctl alerts setup --defaults --system <id> --json` (direct argv, no shell parsing) to enable recommended Beszel hub alerts for that host without overwriting existing rules. Clicking the external-link button in the panel header runs `xdg-open <hub_url>/system/<id>` (scheme-validated `http://` or `https://`, passed via direct argv without shell parsing) to open that host in your Beszel web UI.
- **Network & credentials:** This plugin makes no network requests, writes no files, and never accesses Beszel hub credentials (credentials stay inside `beszel-relay` / `beszel-ctl` via `systemd-creds`).
- **Auto-pause:** Disabling the plugin stops the `beszel-ctl` stream, allowing `beszel-relay` to pause upstream `rt_metrics` polling automatically.
