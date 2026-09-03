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
- **DNS lookup tester** at the bottom of the panel: resolve a name with
  `dig`/`nslookup` against the active provider, or against any other provider
  from its row menu. Use it to confirm a switch, or to find out if a provider
  blocks a domain before you switch to it
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

In the panel, right-click a provider to open its row menu:

| Entry | Effect |
| --- | --- |
| **Apply this provider** | Same as a left click. On the active row it applies the profile again. |
| **Copy these addresses** | Copies that provider's addresses to the clipboard. |
| **Look up *name* through this resolver** | Sends the hostname from the *DNS lookup* box to that provider. It does not change the system DNS. |

The lookup entry needs a valid hostname in the box, and a provider that has its
own addresses. It is disabled for *Default (ISP)*.

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

- noctalia v5.0.0-beta.9 or newer — the first release that accepts
  `plugin_api = 28`. The plugin needs 28 for the provider row menu
  (`panel.openContextMenu`), and 24 for argv process execution: every command
  it runs is an argument vector, so no shell parses a DNS address, a hostname
  or the privilege command. On beta.8 the plugin store keeps serving 0.1.2
- NetworkManager (`networkmanager`, provides `nmcli`) with an active connection
- `env` (coreutils) — runs `nmcli` under `LC_ALL=C`
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
rule only ever needs to name `nmcli` itself. It is split on whitespace into
separate arguments (`sudo -n` is two), and `nmcli` stays the program it is
asked to run, which is what the rule below matches on; a privilege command
whose own path contains spaces is not supported — use a wrapper script.

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
