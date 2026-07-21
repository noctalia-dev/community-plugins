# Tailscale

Tailscale status and control for Noctalia, built around one core flow: **see
which hosts are online and copy their IP or name in one gesture** — from the
launcher or from the panel. Plus connect/disconnect, exit-node management,
per-host ping and SSH, Taildrop receive, and a desktop widget. A port of the
v4 `tailscale` plugin to the v5 Luau plugin API.

> Community plugin built on top of the Tailscale CLI. Not affiliated with
> Tailscale Inc.

## Plugin

| Field | Value |
| --- | --- |
| ID | `rylos/tailscale` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `poller`; shortcut: `toggle`; launcher: `hosts`; desktop widget: `desktop` |
| Launcher Prefix | `/ts` |

## Requirements

Install `tailscale` and authenticate the node. For Taildrop receive without a
root prompt, grant your user operator rights once:

```sh
sudo tailscale set --operator=$USER
```

## Usage

- **Launcher** (`/ts`): type `/ts <query>` to fuzzy-search the tailnet by host
  name, IP, or OS; activating a result **copies the host's Tailscale IP** to
  the clipboard. Type `/ts n <query>` to copy the host **name** (the Tailscale
  short name, the form `tailscale ssh`/`file cp` expect) instead. Online hosts
  rank first.
- **Bar widget** (`bar`): add it from the Add-widget picker. Tailscale logo
  with state badge, online/total peer count, and optionally this node's IP.
  Left click opens the panel, right click toggles `tailscale up`/`down`.
- **Panel** (`panel`): connect/disconnect, Taildrop receive, and refresh in
  the header; this node's row with copy buttons; a live filter box; then the
  peer list sorted online-first with status dot, OS icon, last-seen time for
  offline peers, and per-row buttons: **copy IP**, **copy name**, **ping**,
  **SSH in terminal**, and **use as exit node** (on peers that advertise it).
  When an exit node is active a banner shows it with a disable button.

  ```sh
  noctalia msg panel-toggle rylos/tailscale:panel
  ```

- **Shortcut** (`toggle`): add it from Settings → Control Center shortcuts. It
  toggles the Tailscale connection up/down.
- **Desktop widget** (`desktop`): add it from the desktop-widgets editor. A
  compact card with state, this node's IP, online/total peers, and the active
  exit node.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `poll_interval` | `int` | `5` | Status refresh interval in seconds (1–60). |
| `hide_mullvad` | `bool` | `true` | Hide Mullvad exit nodes from the peer lists. |
| `hide_offline` | `bool` | `false` | Hide offline peers from the panel and launcher. |
| `taildrop_dir` | `folder` | `""` | Where Taildrop saves received files. Empty = the XDG download folder (advanced). |
| `ssh_username` | `string` | `""` | Username for the SSH button. Empty = system default (advanced). |
| `show_ip` | `bool` | `false` | Bar widget: show this node's Tailscale IP. |
| `show_count` | `bool` | `true` | Bar widget: show the online/total peer count. |

## IPC

```sh
noctalia msg plugin rylos/tailscale:poller all refresh   # force a status refresh
noctalia msg plugin rylos/tailscale:poller all up        # tailscale up
noctalia msg plugin rylos/tailscale:poller all down      # tailscale down
noctalia msg panel-toggle rylos/tailscale:panel
```

## Notes

- **Processes**: the service polls `tailscale status --json`; actions spawn
  `tailscale up|down`, `tailscale set --exit-node=…`, `tailscale ping -c 3
  <ip>`, `tailscale file get <dir>`, and `xdg-user-dir DOWNLOAD` (to resolve
  the default Taildrop folder). The login button opens the daemon's auth URL
  with `gio open` (fallback `xdg-open`); the SSH button runs `ssh <host>` in
  your terminal via the shell's run-in-terminal facility. There is no direct
  network access from the plugin itself — everything goes through the
  Tailscale CLI.
- **Filesystem**: Taildrop receive lists the download directory before and
  after `tailscale file get` to report exactly which files arrived. Nothing
  else is written.
- **Privacy**: host names, IPs, and last-seen times come from your own
  tailnet via the local CLI and are only shown/copied locally.
- Not ported from v4: Taildrop **send** (the plugin API has no file picker)
  and multi-account switching.

## Credits

Based on the v4 [tailscale](https://github.com/noctalia-dev/legacy-v4-plugins/tree/main/tailscale)
plugin. MIT license.
