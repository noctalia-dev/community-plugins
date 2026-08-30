# Cloudflare WARP

Control Cloudflare WARP from Noctalia and inspect the live tunnel connection, traffic, and security statistics.

## Plugin

| Field | Value |
| --- | --- |
| ID | `levi/warp` |
| Entries | Bar widget: `warp`; panel: `panel`; service: `service`; Control Center shortcut: `toggle` |

## Requirements

Install `warp-cli` from Cloudflare WARP and keep the `warp-svc` service running. The WARP client must be registered.

## Usage

Add `levi/warp:warp` as a bar widget or `levi/warp:toggle` as a Control Center shortcut in Noctalia Settings.

- Left-click the bar widget to open the panel.
- Right-click the bar widget, or click the Control Center shortcut, to connect or disconnect WARP.
- Use the panel selector to switch between WARP, DoH, DoT, proxy, and tunnel-only modes. The panel shows a description of each mode and keeps the current selection visible while `warp-cli` applies it.
- Use the refresh button to request fresh status and tunnel statistics.

Open the panel directly with:

```sh
noctalia msg panel-toggle levi/warp:panel
```

## IPC

```sh
noctalia msg plugin levi/warp:service all toggle
noctalia msg plugin levi/warp:service all refresh
noctalia msg plugin levi/warp:service all set-mode warp+doh
```

The `set-mode` event accepts `warp`, `doh`, `warp+doh`, `dot`, `warp+dot`, `proxy`, or `tunnel_only`.

## Notes

The plugin runs `warp-cli status`, `warp-cli settings list`, and `warp-cli tunnel stats` for read-only data. User actions run `warp-cli connect`, `warp-cli disconnect`, or `warp-cli mode <mode>`. It does not make network requests or write files itself; Cloudflare WARP owns the tunnel and its configuration.
