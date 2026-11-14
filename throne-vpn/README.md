# Throne VPN for Noctalia

Control [Throne](https://github.com/throneproj/Throne) from a native Noctalia bar widget and attached panel. Browse VPN profiles, switch TUN connections and compare saved connection metrics without opening the Throne window.

[Project repository](https://github.com/lonefrogg/noctalia_throne_plugin)

## Features

- Connect or disconnect a profile and reconnect to the last used profile.
- View saved latency, download/upload speeds and accumulated traffic.
- Sort profiles by download speed, search by name and scroll through large lists.
- Follow connection state through the bar icon.
- Use a native panel that follows Noctalia's theme and placement settings.

## Plugin

| Field | Value |
| --- | --- |
| ID | `lonefrogg/throne-vpn` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `backend` |
| Version | `2.1.2` |
| License | MIT |

## Requirements

| Dependency | Requirement |
| --- | --- |
| [Noctalia](https://noctalia.dev/) | Native Noctalia 5 with plugin API 24 or later |
| `python3` | Python 3.11 or later; standard library only |
| [Throne](https://github.com/throneproj/Throne) | API-enabled build; reference version: `1.4.0-beta.4` |
| [`thronectl`](https://github.com/throneproj/Throne-api) | Reference version: `v0.2.0`; available on PATH or through a configured executable path |

Install dependencies using the method supported by your distribution. The plugin does not install or update them.

Throne must be running with its API enabled, at least one profile configured and the core's TUN privileges granted. An existing API key file readable by the desktop user is required. API configuration is documented [upstream](https://throneproj.github.io/advanced/api/); TUN permissions are described in [permissions.md](permissions.md).

## Installation

Add this repository as a Noctalia plugin source and enable the plugin:

```sh
noctalia msg plugins source add throne-vpn git https://github.com/lonefrogg/noctalia_throne_plugin.git
noctalia msg plugins enable lonefrogg/throne-vpn
```

For a local checkout or extracted ZIP, run these commands from the repository root, which contains `catalog.toml`:

```sh
noctalia msg plugins source add throne-vpn-local path "$PWD"
noctalia msg plugins enable lonefrogg/throne-vpn
```

Keep a local source directory in place while using it.

## Usage

1. Open **Settings → Plugins → Throne VPN** and configure the API address, key file and thronectl executable.
2. Add **Throne VPN** to the bar using the Add Widget picker. Its full widget ID is `lonefrogg/throne-vpn:bar`.
3. Open the panel and select a profile to connect with TUN.

The `backend` service starts with the plugin and supplies the `bar` widget and `panel` entry automatically.

| Control | Action |
| --- | --- |
| Left-click the widget | Open or close the panel |
| Right-click the widget | Close the panel |
| Click a profile | Connect that profile |
| **Disconnect** | Stop the running connection |
| **Last profile** | Connect the previously used profile |
| **Refresh** | Read the latest saved metrics from Throne |
| Wheel or touchpad | Scroll the profile list |
| Escape or close button | Dismiss the panel |

The panel can also be toggled directly:

```sh
noctalia msg panel-toggle lonefrogg/throne-vpn:panel
```

Profiles are ordered by saved download speed, descending. Untested profiles follow measured profiles; failed tests appear last. Speeds use Mbps, latency uses milliseconds, and `Σ` shows accumulated traffic.

## Settings

Settings are shared by the widget and panel and are available under **Settings → Plugins → Throne VPN**.

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `api_address` | string | `127.0.0.1:9095` | Throne API endpoint |
| `api_key_file` | file | Unset | Path to an existing API key file; select a file rather than entering the key value |
| `thronectl_path` | string | `thronectl` | Executable name or full path; a leading `~` is expanded |
| `poll_seconds` | int | `3` | Status refresh interval in seconds, from 2 to 60 |

Panel placement, including attached/floating mode and open-near-click, is configured in Noctalia's panel settings.

## Updates

For the Git source:

```sh
noctalia msg plugins update throne-vpn
```

A local path source uses the files in its directory and does not download updates.

## Notes

- Throne remains responsible for routing, profiles and subscriptions. The plugin preserves the selected route.
- Metrics come from tests already stored in Throne. Refreshing the panel does not start a speed test.
- The icon reflects Throne's reported state, including TUN, proxy-only and degraded states.
- Disabling the plugin stops polling but leaves an active Throne connection running.

The service launches `python3` with the bundled `backend.py`, which calls `thronectl` using argument arrays. thronectl contacts the configured API, on loopback by default, and reads the selected key file. The helper neither reads nor prints the key value. Explicit connection actions may enable TUN; the plugin does not grant privileges or modify profiles, routes or subscriptions.

The helper writes a private action lock under `$XDG_RUNTIME_DIR/noctalia-throne-vpn`, with `~/.cache/noctalia-throne-vpn` as a fallback. Noctalia manages plugin settings. There are no telemetry requests or runtime code downloads.



## AI assistance

The implementation and documentation were created with AI assistance. They are shared openly for review and contribution; the maintainer does not claim to have manually authored the implementation.

## License

[MIT](LICENSE). This project is independently maintained and is not affiliated with the Throne or Noctalia teams.
