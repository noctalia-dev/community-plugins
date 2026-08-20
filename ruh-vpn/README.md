# Ruh VPN

Ruh VPN is a VPN and proxy manager for `sing-box`. It manages SSH, VLESS,
VMess, Shadowsocks and SOCKS5 connections from a Noctalia bar widget, panel
and control-center shortcut.

## Plugin

| Field | Value |
| --- | --- |
| ID | `umedbazarov/ruh-vpn` |
| Entries | Bar widget: `vpn_widget`; panel: `vpn_panel`; service: `vpn_service`; shortcut: `vpn_toggle` |

## Requirements

The backend requires `sing-box`, `python3` and `pkill`, plus the Python
packages declared in `pyproject.toml`: `pydantic`, `aiofiles`, `aiohttp` and
`aiohttp-socks`. The plugin never installs packages itself: it checks the
configured interpreter at startup and, if something is missing, reports the
exact package names in the panel and does not start the backend.

Install the packages either from your distribution (e.g. `python-pydantic`,
`python-aiofiles`, `python-aiohttp` on Arch), or into a dedicated virtual
environment:

```sh
python3 -m venv ~/.local/share/ruh-vpn-venv
~/.local/share/ruh-vpn-venv/bin/pip install pydantic aiofiles aiohttp aiohttp-socks
```

Then set the `backend_python` setting to that environment's interpreter, e.g.
`~/.local/share/ruh-vpn-venv/bin/python3`. The default `backend_python` value
is `python3`, which works when the packages are installed system-wide.

SSH connections require `ssh`; password-based SSH connections additionally
require `sshpass`. System proxy mode requires `gsettings`. TUN mode and the kill
switch use `pkexec`, `setcap`, `getcap` and `nft` for privileged operations;
TUN mode also uses `ip` (iproute2) for a read-only pre-flight check that no
other VPN client already holds the sing-box routing table.

## Usage

Add the **Ruh VPN** widget under Settings → Bar, or add the `vpn_toggle`
shortcut to the control center. Click the widget to open the panel. Select or
add a server, choose the routing mode (`rules` or `global`) and connection mode
(`system` or `tun`), then enable the main switch.

Open or close the panel with:

```sh
noctalia msg panel-toggle umedbazarov/ruh-vpn:vpn_panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `backend_python` | `file` | `python3` | Python executable with the backend packages installed. |
| `auto_start` | `bool` | `false` | Connect the active server when the plugin service starts. |
| `geoip_country` | `bool` | `true` | Resolve server countries through `api.country.is`. |
| `control_port` | `int` | `11090` | Loopback HTTP port used by the Luau entries and Python backend. |
| `show_ping` | `bool` | `true` | Show active-server latency in the bar. |
| `show_traffic` | `bool` | `false` | Show live upload and download rates in the bar. |

## Notes

- The service starts the Python backend, which starts `sing-box` and, for SSH
  connections, `ssh` or `sshpass`. `sing-box` is resolved from `PATH`.
- SSH host keys are recorded on first connect into a `known_hosts` file inside
  the plugin data directory and verified on every later connect; a changed host
  key makes the connection fail instead of being ignored.
- Server passwords and UUIDs never leave the backend: the panel lists servers
  without secrets, and an empty secret field when editing keeps the stored
  value.
- Persistent settings, servers, subscriptions and generated `sing-box`
  configuration are written under the directory returned by
  `noctalia.pluginDataDir()`. Runtime state and logs are stored in its
  `runtime/` subdirectory.
- The backend listens on the configured loopback control port. It does not bind
  the control API to an external interface, and every RPC call requires a
  per-launch bearer token stored in a user-only (mode 0600) file under the
  runtime directory, so other local users cannot control the VPN or read
  server credentials.
- Network access includes configured VPN endpoints and subscription URLs,
  `api.country.is` when country detection is enabled, Cloudflare's speed-test
  endpoint, and remote rule sets enabled by routing presets.
- DNS in the generated configurations: Google DNS (`8.8.8.8`) over plain UDP
  through the proxy tunnel; AliDNS (`223.5.5.5`) over plain UDP directly, as
  the resolver for direct-routed and unmatched domains in rules mode; Google
  DNS-over-HTTPS (`8.8.8.8`, through the tunnel) in TUN mode.
- TUN mode grants `CAP_NET_ADMIN`, after a PolicyKit prompt, to a private copy
  of `sing-box` kept in a user-only (mode 0700) directory under the plugin
  data directory — never to the shared system binary. The copy is recreated
  whenever the system `sing-box` changes, which also clears the previously
  granted capability. The kill switch installs a dedicated nftables table and
  removes it when disabled.
