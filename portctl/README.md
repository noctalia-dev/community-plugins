# Portctl

A simple and minimal plugin to inspect and terminate listening TCP/UDP ports from the bar.

## Plugin

| Field | Value |
| --- | --- |
| ID | `rxtsel/portctl` |
| Entries | Bar widget: `indicator`; panel: `panel`; service: `scanner` |

## Requirements

Install `ss` from `iproute2` on `PATH`. Available on all major Linux distributions; install the `iproute2` package if missing.

## Usage

Add the `indicator` widget to a bar. It shows a plug icon with the count of active listening ports. The widget is hidden when no ports are detected. Click it to open the port panel.

Open the panel directly with:

```sh
noctalia msg panel-toggle rxtsel/portctl:panel
```

The panel lists listening ports grouped by category (Development, Databases, Containers, Servers, Cloud, Other). From there you can:

- Search by port number, process name, or PID.
- Toggle TCP and UDP visibility independently with the header toggles.
- Click any PID label to copy the PID to the clipboard.
- Kill a process: click `×` to stage the kill, then confirm with `Kill` in the inline confirmation row. The row transforms in place — no dialog opens.

To customize the bar icon, right-click the widget → settings → **Glyph**.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_interval` | `int` | `5` | Seconds between automatic port scans (1–60). |
| `ignore_list` | `string` | *(empty)* | Comma-separated process name substrings to hide (e.g. `discord,chrome,steam`). |
| `ignore_ports` | `string` | *(empty)* | Comma-separated port numbers to hide (e.g. `37700,6463`). |
| `hide_system_ports` | `bool` | `true` | Hide ports below 1024 (privileged/root ports). |
| `hide_unknown_ports` | `bool` | `false` | Hide ports whose process info is inaccessible (root-owned processes, rootlessport, etc.). |

Widget settings (right-click widget → settings):

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `glyph` | `glyph` | `plug` | Icon shown in the bar. |

## Notes

**Root-owned ports** — ports owned by root-level processes show `—` as the PID and cannot be killed from the plugin (no privilege escalation is performed). Enable `hide_unknown_ports` to exclude them from the list.

**Container ports with pasta networking** — ports forwarded via `pasta` (the default network backend in Podman 4+) do not create a host-side socket and are not visible to `ss`. They will not appear in portctl. Ports forwarded via `rootlessport` (older Podman, or explicit `--network slirp4netns`) do appear, categorized under Containers.

**`rootlessport` entries** — expected behavior when running Podman or Docker in rootless mode with published ports (`-p`). Add `rootlessport` to `ignore_list` or the specific port number to `ignore_ports` to suppress them.

**Processes spawned** — `ss -ltnp` and `ss -lunp` on every scan. No network calls. No filesystem writes outside `noctalia.pluginDataDir()`.
