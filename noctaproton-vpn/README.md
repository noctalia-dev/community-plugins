# NoctaProton VPN

A sleek, native Noctalia shell plugin to control Proton VPN without needing the official GUI. Seamlessly manage your Kill Switch, NetShield ad/tracker blocker, Port Forwarding, and Split Tunneling, or hop countries and servers on the fly with live throughput graphs and dynamic theme coloring.

Built for **Noctalia Shell**, extensively tested on **MangoWM** on **Arch Linux (CachyOS)**.

---

> [!NOTE]
> **AI Development Disclaimer**: This plugin was engineered, written, and verified with the assistance of artificial intelligence (Google Antigravity / Gemini), paired with thorough hands-on testing on a live Wayland desktop environment (Noctalia on MangoWM, Arch Linux).

---

## Plugin

| Field | Value |
| --- | --- |
| ID | `riversyx/noctaproton-vpn` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `service`; shortcut: `toggle` |

## Requirements

- `proton-vpn-cli`: Official Proton VPN Linux CLI (v1.0.3+). Install via your package manager:
  ```bash
  sudo pacman -S proton-vpn-cli
  ```
- `nmcli`: NetworkManager command-line client for high-performance zero-latency link status tracking.
- `python`: Python 3.10+ runtime (for NAT-PMP port keepalive, server caching, and split-tunneling desktop scanner).
- An active Proton account (Free or Plus/Unlimited).

## Features

- 🎨 **Dynamic Theme Coloring**: Automatically synchronizes with your active Noctalia color palette and wallpaper tones (using semantic `primary`, `on_surface`, and `surface_variant` tokens).
- 🛡️ **Kill Switch**: Instant standard Kill Switch toggle to prevent accidental IP leaks.
- 🛡️ **NetShield Ad & Malware Blocker**: 3-level DNS filtering (`Off`, `Malware only`, `Malware, Ads & Trackers`).
- ⚡ **Port Forwarding**: Automatic continuous NAT-PMP port mapping renewal every 45s with one-click port copying to clipboard for torrent clients and P2P software.
- 🔀 **Split Tunneling**: Seamless application picker scanning installed `.desktop` applications to route specific apps outside the VPN tunnel.
- 🌍 **Country & Server Hopping**: Quick connect to **Fastest**, **Random**, **P2P**, **Tor**, or **Secure Core**, with a full searchable country and server list.
- 📈 **Real-Time Bandwidth Meter**: Live download & upload speed counters (KB/s, MB/s) and session transfer totals.
- 🔐 **Secure Interactive Authentication**: Launches an interactive terminal prompt for username, password, and 2FA authentication, keeping credentials completely isolated from scripts.
- 🚀 **Desktop Bar & Quick Toggle**: Left-click the bar shield to open the panel, or right-click anytime to quick-connect / disconnect.

## Installation

### Method 1: Using Noctalia Plugin Sources (Local / Dev)

1. Clone this repository into your local Noctalia plugins directory:
   ```bash
   git clone https://github.com/RiverSyx/noctaproton-vpn.git ~/.config/noctalia/plugins/noctaproton-vpn
   ```

2. Register the local plugin source (if you haven't already):
   ```bash
   noctalia msg plugins source add local path ~/.config/noctalia/plugins
   ```

3. Enable the plugin:
   ```bash
   noctalia msg plugins enable riversyx/noctaproton-vpn
   ```

4. Add the widget to your Noctalia configuration (`~/.config/noctalia/config.toml`):
   ```toml
   [widget.protonvpn]
   type = "riversyx/noctaproton-vpn:bar"
   ```
   And add `"protonvpn"` to your `[bar.default].end` or `[bar.default].start` array.

### Method 2: From the Noctalia Community Plugin Store

Once merged into the community catalog:
```bash
noctalia msg plugins enable riversyx/noctaproton-vpn
```

## Usage

- **Toggle Panel via CLI / Keybind**:
  ```bash
  noctalia msg panel-toggle riversyx/noctaproton-vpn:panel
  ```
- **Control Center Shortcut**: Add the `toggle` shortcut in Noctalia Settings → Control Center to toggle your connection with a single click.
- **Bar Widget**:
  - **Left Click**: Open or dismiss the control panel.
  - **Right Click**: Quick toggle (connects to fastest server or disconnects).

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_interval` | `int` | `5` | How often (in seconds) to poll the Proton VPN CLI and NetworkManager for status. |
| `traffic_monitoring` | `bool` | `true` | Enables continuous sampling of interface throughput from `/sys/class/net/proton0/statistics/`. |
| `notify_on_connect` | `bool` | `true` | Show desktop notifications when the VPN tunnel connects or disconnects. |

## Notes

- **Network Access**: The plugin itself makes no direct external web calls; all VPN connectivity is managed via the official `protonvpn` CLI. When Port Forwarding is enabled, `port.py` sends local NAT-PMP renewals exclusively to the internal tunnel gateway (`10.2.0.1:5351`).
- **Files Written**:
  - Split tunneling settings are written directly to Proton's native configuration file at `~/.config/Proton/VPN/settings.json`.
- **System Requirements**: Requires `proton.VPN.service` systemd service running (`systemctl status proton.VPN.service`).

## License

GPL-3.0-only
