# IP Monitor

A Noctalia bar widget to monitor network IPs. 
It supports fetching IPs from network interfaces, custom commands, or via IPC.

## Plugin

| Field | Value |
| --- | --- |
| ID | `3ri4ng0ld/ip-monitor` |
| Entries | Bar widget: `widget` |

## Requirements

- `ip` (part of `iproute2`): Required to resolve IP and gateway in Interface mode.
- `curl`: Required if using the default custom command to fetch public IPs.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `glyph` | `glyph` | `network` | The icon glyph displayed on the widget |
| `glyph_color` | `color` | `on_surface` | Color of the icon |
| `mode` | `select` | `interface` | Operating mode: Interface, Custom Command, or IPC |
| `iface` | `string` | `wlan*` | Network interface wildcard to fetch IP from |
| `custom_command` | `string` | `curl -s ifconfig.me` | Shell command to execute in custom command mode |
| `text_color` | `color` | `on_surface` | Color of the IP text |
| `name` | `string` | `""` | A custom name to display alongside the IP |
| `ipc_id` | `string` | `default` | Identifier used to target this specific widget via IPC |
| `name_color` | `color` | `on_surface_variant` | Color of the name text |
| `separator` | `string` | `-` | Separator symbol between IP and Name |
| `separator_color` | `color` | `on_surface_variant` | Color of the separator |
| `hide_on_empty` | `boolean` | `true` | Hide the widget completely if no IP is found |
| `refresh_interval` | `int` | `10` | Refresh interval in seconds (max 3600) |

## Usage

Add the widget to a bar from *Settings → Bar*. Plugin options live in *Settings → Plugins*.

### Modes

1. **Interface**: Fetches the IP from a local network interface. The `Interface` setting supports wildcards, for example `wlan*` or `eth*`, and will select the first matching interface that has a valid IP address.
2. **Custom Command**: Runs a shell command to fetch the IP. For example, `curl -s ifconfig.me` for the public IP.
3. **IPC**: Listens to external events to set the IP and name.

### IPC

The widget listens to the `set` event. By default, the widget is assigned the IPC ID `default`. To set the IP and name for a default widget, use the following command (you don't need to specify an ID in the JSON, it defaults to `default`):

```sh
noctalia msg plugin 3ri4nG0ld/ip-monitor:widget all set '{"ip":"192.168.1.5","name":"MyIP"}'
```

If you have multiple `ip-monitor` widgets in IPC mode and want to update them independently, you can change the **IPC ID** setting for each widget. Then, target them by passing their ID string in the JSON payload:

```sh
noctalia msg plugin 3ri4nG0ld/ip-monitor:widget all set '{"id":"my_vpn","ip":"100.64.0.1","name":"VPN"}'
noctalia msg plugin 3ri4nG0ld/ip-monitor:widget all set '{"id":"my_local_iface","ip":"192.168.1.5","name":"Ethernet"}'
```

### Tooltips

Hovering over the widget displays detailed network information if available:
- **Interface**: Network interface name (e.g. `eth0`)
- **IP**: IPv4 address
- **Network**: Network range (e.g. `192.168.1.0/24`)
- **Default route**: Gateway address (e.g. `192.168.1.1`)
- **Mask**: Subnet mask (e.g. `255.255.255.0`)
- **Broadcast**: Broadcast address (e.g. `192.168.1.255`)

In **IPC Mode**, tooltip fields can be passed optionally in the JSON payload (either as top-level keys or nested inside a `tooltip` object):

```sh
noctalia msg plugin 3ri4nG0ld/ip-monitor:widget all set '{
  "id": "my_vpn",
  "ip": "100.64.0.2",
  "name": "Tailscale",
  "iface": "tailscale0",
  "network": "100.64.0.0/10",
  "gateway": "100.64.0.1",
  "mask": "255.192.0.0"
}'
```

### Click Actions

You can configure what happens when you left-click or right-click the widget:
- Copy IP
- Copy Name
- None
