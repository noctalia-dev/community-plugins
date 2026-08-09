# DNS Switcher

A [noctalia](https://github.com/noctalia-dev/noctalia) v5 bar plugin: switch the system DNS
between popular providers, your own servers, or the ISP default — from a panel
on the bar, no reconnect. Based on
[Ronin-CK's v4 DNS Switcher](https://github.com/noctalia-dev/legacy-v4-plugins),
rebuilt on the v5 Luau plugin API.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nightwatch75/dns-switcher` |
| Entries | Bar widget: `dns-switcher`; panel: `panel`; service: `service` |

## Features

- **Instant, no-drop switching** — one `nmcli con mod` + `nmcli device
  reapply` on the active connection profile; the network never disconnects
- **Pre-configured providers** (Google, Cloudflare, OpenDNS, AdGuard, Quad9)
  plus up to 5 custom servers (`Name = address`, e.g. `Pi-hole = 192.168.1.5`)
- **Detection**, not guessing — reads the connection's own `ipv4.dns` /
  `ipv4.ignore-auto-dns`, so a manually configured resolver (LAN ones
  included) shows as its provider, DHCP-assigned DNS shows as *Default (ISP)*
- **DNS lookup tester** at the bottom of the panel: resolve any name against
  the currently active provider's own address with `dig`/`nslookup`, to
  confirm a switch took effect or check whether a provider blocks a domain
- **Fully rebindable gestures** — left click, right click and scroll are
  declared in the manifest (`[widget.actions]`), so any of them can be
  remapped from the bar's own gesture settings; scroll cycles providers
- **Singleton service** — one engine regardless of how many bars/monitors
  show the widget; widget and panel are pure renderers over its shared state
- Live footer (connection name + active resolver IPs, with a copy button),
  glyph-only mode for compact bars

## Usage

Add the `dns-switcher` widget from Noctalia's widget picker. Default gestures:

| Action       | Effect                                          |
|--------------|--------------------------------------------------|
| Left click   | Open/close the provider panel                     |
| Right click  | Reset to the connection default (ISP)             |
| Scroll       | Cycle to the next/previous configured provider    |

All three are bar-level defaults and can be remapped from *Settings → Bar*.
The panel itself, and the plugin's settings page, also open from the CLI:

```sh
noctalia msg panel-toggle nightwatch75/dns-switcher:panel
noctalia msg settings-open-plugin nightwatch75/dns-switcher
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `providers` | `string` | `google,cloudflare,opendns,adguard,quad9` | Comma-separated built-in provider ids shown in the panel. Empty = none. |
| `custom_1` … `custom_5` | `string` | *(empty)* | One custom resolver each: `Name = address`, one or two IPv4 addresses. |
| `poll_seconds` | `int` | `10` | How often the active DNS is re-read with `nmcli` (2–120). |
| `privilege_command` | `string` | *(empty)* | Prefix to run `nmcli` changes as root (`pkexec`, `sudo -n`) — see *Privileges*. |
| `show_label` (widget) | `bool` | `true` | Show the provider name next to the glyph. |

## IPC

```sh
noctalia msg plugin nightwatch75/dns-switcher:service all apply cloudflare
noctalia msg plugin nightwatch75/dns-switcher:service all poll
noctalia msg plugin nightwatch75/dns-switcher:service all cycle next
```

`apply` takes a built-in id, `default` (ISP), or `custom:<name>`; `poll`
forces an immediate re-check; `cycle next`/`cycle prev` step to the
neighbouring provider (what scroll sends).

## Requirements

- noctalia v5.0.0-beta.7 or newer (`plugin_api = 17`, for the `onExit`
  lifecycle cleanup in `service.luau`)
- NetworkManager (`networkmanager`, provides `nmcli`) with an active connection
- Permission to modify system connections (see *Privileges* below)
- `dig` (bind-tools/dnsutils) or `nslookup`, optional — only the lookup
  tester needs one of them; the rest of the plugin works without either

## Privileges

*Privilege command* is **empty by default**: NetworkManager's polkit policy
usually lets active local sessions modify system connections without a
password. If you get a "not authorized" error, set it to `pkexec` (shows
noctalia's own polkit prompt) or `sudo -n` with a matching sudoers rule.
The privilege command is applied to the `nmcli con mod` and `nmcli device
reapply` calls individually — never to a wrapping shell — so the sudoers
rule only ever needs to name `nmcli` itself:

```
# /etc/sudoers.d/nmcli-dns
youruser ALL=(root) NOPASSWD: /usr/bin/nmcli
```

With `pkexec`, this means an apply may show its polkit prompt twice (once
per elevated `nmcli` call) instead of once.

Or grant it via a polkit rule and keep the setting empty:

```js
// /etc/polkit-1/rules.d/50-nmcli-dns.rules
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.NetworkManager.settings.modify.system" ||
         action.id == "org.freedesktop.NetworkManager.network-control") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
```

Both widen what the account can do to NetworkManager system-wide — apply
your usual judgement on shared machines.

## Notes

- IPv4 DNS only, like the v4 plugin.
- Targets the first active wifi/ethernet connection (falling back to the
  first active non-loopback one); a VPN's own DNS is not touched.
- Custom servers are five separate `string` settings rather than one list,
  because Noctalia's list editor has no in-place row edit — a `string`
  field does. A server name may not contain `=`.

## License

MIT.
