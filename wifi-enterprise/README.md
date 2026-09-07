# WiFi Enterprise

Create, edit and delete 802.1X (WPA2/WPA3-Enterprise, e.g. eduroam or
corporate RADIUS) Wi-Fi profiles via `nmcli`, since Noctalia's own Wi-Fi
widget can't.

> **This is a stopgap.** Noctalia's own Wi-Fi widget only ever builds
> `wifi-sec.key-mgmt` of `wpa-psk`/`sae`. The maintainers want to support
> enterprise Wi-Fi but are blocked on having a network to test against:
> [noctalia-dev/noctalia#3216](https://github.com/noctalia-dev/noctalia/issues/3216)
> (open) and [#719](https://github.com/noctalia-dev/noctalia/issues/719)
> (closed when v4 was sunset). **Once that lands upstream, retire this
> plugin.** It exists only to cover the gap until then. Once a profile
> exists (created here, or with `nmtui`/`nm-connection-editor`), Noctalia's
> own Wi-Fi list already connects to it correctly, so this plugin's only job
> is creating and editing the profile, never day-to-day connecting.

## Plugin

| Field | Value |
| --- | --- |
| ID | `andrewdems/wifi-enterprise` |
| Entries | Panel: `panel`; Service: `service`; Shortcut: `open` |

There is no bar widget: Noctalia's own Wi-Fi widget already shows connection
status, so this plugin only needs to be reachable to manage profiles, not to
duplicate that.

## Requirements

Install `nmcli` (NetworkManager) on `PATH`. The optional CA-certificate file
picker uses `kdialog`, falling back to `zenity`; without either installed you
can still use the system trust store instead of picking a CA certificate.

## Usage

Add the `open` shortcut in Settings > Control Center, or open the panel
directly:

```sh
noctalia msg panel-toggle andrewdems/wifi-enterprise:panel
```

In the panel:

- **Add Enterprise Network**: pick the SSID from a live scan (802.1X networks
  only) or type one manually, choose the EAP method (PEAP is the common
  default for eduroam/corporate) and phase 2 auth (MSCHAPv2 is the common
  default), enter your identity and password, and create. "Advanced options"
  adds anonymous identity (outer-identity privacy), a CA certificate or the
  system trust store, and domain suffix match.
- **Connect** / **Edit** / **Delete** on an existing profile. Editing without
  retyping the password keeps the existing one.

Once created, the profile shows up in Noctalia's own Wi-Fi list like any
other, and auto-connects like any other saved network.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `auto_connect_after_create` | `bool` | `true` | Connect a new 802.1X profile immediately after it's created. |

## Notes

**Filesystem**: the only file this plugin writes is a transient `pick.tmp`
under its plugin data directory, used to read back the CA-certificate file
picker's result; it's deleted immediately after use. Nothing else is written
or persisted by the plugin itself.

**Processes**: `nmcli` for every connection operation; `kdialog` or `zenity`
only when the CA-certificate browse button is used.

**Network**: none directly. All network activity (RADIUS/EAP authentication,
DHCP) happens through NetworkManager itself, which the plugin only drives via
`nmcli` subprocess calls.

**Secrets**: the password is passed to `nmcli` once, at create/edit time, as
a command argument (briefly visible in the process list, the same technique
NetworkManager's own tools and Noctalia's own PSK Wi-Fi flow already use).
The plugin never stores or re-reads the secret itself: `nmcli` persists it
into NetworkManager's own connection file
(`/etc/NetworkManager/system-connections/*.nmconnection`, mode `600`,
`root:root`), which is better protected than anything a plugin could keep in
its own `settings.toml` (world-readable, `0644`).

Validate the server certificate when you can: set a CA certificate or the
domain suffix match rather than leaving both blank, or a rogue access point
can pass as the real RADIUS server.

## AI assistance

This plugin, and this README, were written with AI assistance. I run it on my
own desktop and tested what shipped.
