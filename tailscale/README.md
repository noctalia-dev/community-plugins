# Tailscale

Manage Tailscale connection state, peers, exit nodes, and preference toggles from Noctalia.

## Plugin

| Field | Value |
| --- | --- |
| ID | `davemhammer/tailscale` |
| Entries | Bar widget: `status`; panel: `manager`; service: `service`; launcher: `ts` |
| Launcher Prefix | `/ts` |

## Requirements

Install these on `PATH` (declared in `plugin.toml` `dependencies`):

- `tailscale` — status, prefs, up/down, set, ping, ssh (requires a running `tailscaled`)
- `jq` — slim prefs extract from `tailscale debug prefs`
- `xdg-open` — open the admin console URL

You need permission to operate the daemon (operator user or equivalent).

## Usage

Add the **status** bar widget (`davemhammer/tailscale:status`). Click for the panel.

Panel tabs:

- **Status** — connect/disconnect, shields, SSH, accept routes, advertise exit, allow LAN
- **Peers** — ping, SSH, copy IP/DNS, use as exit if offered
- **Exit nodes** — select or clear an exit node

Toggle chips use a fixed label and highlight when the setting is **on**.

Launcher: `/ts`, `/ts peers`, `/ts exit`, `/ts up`, `/ts down`.

```sh
noctalia msg panel-toggle davemhammer/tailscale:manager
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_interval` | `int` | `10` | Status poll interval in seconds. |
| `notify_on_peer_change` | `bool` | `true` | Notify when a peer goes online/offline. |
| `tailscale_bin` | `string` | `tailscale` | CLI path. |
| `admin_url` | `string` | _(empty)_ | Override admin console URL (default login.tailscale.com admin). |
| `ssh_user` | `string` | _(empty)_ | Default user for `tailscale ssh`. |
| `show_counts` | `bool` (widget) | `true` | Show online/total peers on the bar. |

## IPC

```sh
noctalia msg panel-toggle davemhammer/tailscale:manager
noctalia msg plugin davemhammer/tailscale:service all refresh
noctalia msg plugin davemhammer/tailscale:service all up
noctalia msg plugin davemhammer/tailscale:service all down
noctalia msg plugin davemhammer/tailscale:service all toggle
```

## Notes

- Shells out to `tailscale status --json | jq …` (same Mullvad-exit filter as text `status`; those nodes stay on the Exit tab via `exit-node list`), `tailscale debug prefs | jq …` (safe field projection), `tailscale exit-node list`, `tailscale set …`, `tailscale up` / `down`, optional `tailscale ping` / `tailscale ssh` in a terminal, and `xdg-open` for the admin URL. A raw `--json` dump on a Mullvad-enabled tailnet is large enough to trip Noctalia's plugin CPU budget and auto-disable the service.
- Advertise-exit state is read from prefs `AdvertiseRoutes` (`0.0.0.0/0` / `::/0`), not only `ExitNodeOption`.
- Network: only through the Tailscale CLI/daemon (no separate HTTP client in the plugin).
- Filesystem: no plugin-written credentials; uses local Tailscale state via the CLI.
- Brand mark assets are bundled under `assets/` (Simple Icons style 3×3 dots).
