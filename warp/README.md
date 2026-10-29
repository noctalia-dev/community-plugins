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

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `manage_daemon` | `bool` | `false` | Automatically start `warp-svc` when connecting and stop it when disconnected to save system RAM. |

## On-Demand Daemon (Optional)

By default, Cloudflare WARP requires `warp-svc.service` to run continuously in the background (~115MB RAM). If you prefer to save RAM by only running the daemon while connected:

1. Enable **On-demand daemon** in Noctalia Settings $\rightarrow$ Plugins $\rightarrow$ Cloudflare WARP.
2. Disable `warp-svc` from automatically starting at boot:

```sh
sudo systemctl disable warp-svc
```

### Passwordless Management (Optional)

By default, managing system services through systemd prompts for authentication via your desktop's Polkit agent (e.g., when clicking connect or disconnect). 

If you prefer seamless, passwordless toggling from the bar, you can **optionally** install a Polkit rule scoped strictly to `warp-svc.service` for local administrators (`wheel` group):

```sh
sudo tee /etc/polkit-1/rules.d/50-warp-svc.rules << 'EOF'
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        action.lookup("unit") == "warp-svc.service" &&
        subject.isInGroup("wheel") &&
        subject.local) {
        var verb = action.lookup("verb");
        if (verb == "start" || verb == "stop" || verb == "restart") {
            return polkit.Result.YES;
        }
    }
});
EOF
```

> **Security Note:** This rule only grants permission to start, stop, or restart `warp-svc.service` for local users in the `wheel` group. It does not grant general root privileges. If you prefer not to install custom Polkit rules, leave it omitted — the plugin will simply trigger your desktop's standard graphical password prompt when toggled.

## Notes

The plugin runs `warp-cli status`, `warp-cli settings list`, and `warp-cli tunnel stats` for read-only data. User actions run `warp-cli connect`, `warp-cli disconnect`, or `warp-cli mode <mode>`. It does not make network requests or write files itself; Cloudflare WARP owns the tunnel and its configuration.
