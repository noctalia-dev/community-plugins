# Network Control

Pick a Wi-Fi network and set how any NetworkManager connection gets its address
— DHCP or a static IP, gateway, DNS servers and search domains, IPv4 and IPv6 —
from the Noctalia bar. Every write to a connection that is already carrying
traffic runs through a confirm window, so a mistyped address cannot leave the
machine offline.

## Plugin

| Field | Value |
| --- | --- |
| ID | `muhammadessam/network-control` |
| Entries | Bar widget: `network`; panel: `panel`; service: `service` |

## Requirements

Install `nmcli` (NetworkManager's command line) on `PATH` — declared in
`dependencies` together with `ip` (the default-route lookup) and
`install`/`chmod` (creating the Wi-Fi passphrase file with mode 0600 before the
secret is written into it).

- `org.freedesktop.NetworkManager.settings.modify.system` must be allowed for the
  session user — it is on a default install. If it is not, the panel says so and
  Apply stays disabled instead of failing silently.
- This plugin edits NetworkManager connection profiles only. It does not touch
  `/etc`, systemd units or netplan, and it does not manage other backends:
  systemd-networkd and netplan have no profile API that can be round-tripped
  safely from a shell plugin.
- Scanning, joining and leaving Wi-Fi needs a working Wi-Fi device; the radio
  sections stay hidden when there is none.

## Usage

Add the `network` widget to the bar. It shows the name of the network the
machine is on, and the glyph changes with the interface type. Click it, or open
the panel directly:

```sh
noctalia msg panel-toggle muhammadessam/network-control:panel
```

The panel is three parts, top to bottom.

**Route summary** — the interface the kernel actually routes through, the
connection behind it and its address. `No route to the network` means there is no
default route at all.

**Wi-Fi networks** (collapsible) — the scan list, strongest first, with a signal
glyph, the security type, and `saved` on networks that already have a profile.

- `Scan for networks` runs a fresh radio scan; opening the panel reads
  NetworkManager's cached list first, so opening never blocks on the radio.
- Clicking a network connects to it. An open network or one that is already saved
  connects in one click; a secured network that is not saved asks for the
  passphrase inline first.
- `Join a hidden network` takes an SSID and passphrase for a network that does
  not broadcast one.
- 802.1X networks are labelled as needing manual setup (identity, certificate,
  phase-2 method) rather than failing halfway through a join.

**Connections and addressing** — every editable profile, with the active one
marked. Selecting one loads its stored configuration: the IPv4 and IPv6 method,
addresses, gateway, DNS servers and search domains. Fields the selected method
does not own (addresses while `Disabled`, for instance) are greyed out and
cleared on write, because NetworkManager rejects them outright — and because they
are cleared before validation, a half-typed value left in one of them cannot block
a write that does not carry it. Below the fields
is the exact property diff that Apply will write, then Connect / Disconnect for
the selected profile, and a Restore point once a write has happened.

Addresses take a prefix; a bare address gets `/24` (IPv4) or `/64` (IPv6) rather
than the `/32` / `/128` NetworkManager would otherwise assume.

### The confirm window

Applying to an **active** connection re-activates it and then arms a countdown
(`confirm_seconds`, default 45 s): the panel grows a **Keep** button, the bar tile
turns into a countdown, and if nothing is kept, the saved profile is restored
property by property and the connection brought back up.

While a window is open nothing else may change the network: joining a network,
bringing a connection up or down, toggling the radio and restoring a backup are
all refused by the service and disabled in the panel, because any of them can move
the active link before the timer decides what it should be. The window is written
to disk with an epoch deadline, so a shell restart inside the window resumes the
countdown rather than dropping the promise; if the deadline passed while the shell
was down, the rollback happens on the next tick.

With `confirm_seconds = 0` there is no window at all: the change is written and
the panel says so instead of promising a rollback that will not come.

That window is the point of the plugin. A static address on the interface
carrying the default route is the one mistake that takes the machine off the
network, and the usual recovery route — a browser, a search engine, a package
mirror — is exactly what stops working. Inactive profiles arm no window, because
writing to them cannot break anything, and joining a Wi-Fi network arms none
either: a failed join leaves the previous profile intact and selectable.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `confirm_seconds` | `int` | `45` | How long to wait for confirmation after a change before the previous settings are restored. `0` writes immediately, with no window. |
| `refresh_seconds` | `int` | `15` | How often the stored profile, the live addresses, the scan age and the radio state are re-read. |
| `show_text` | `bool` | `true` | Bar widget shows the network name next to the glyph. |
| `glyph` | `glyph` | `network` | Bar widget icon when no interface is up. |

## IPC

Every action is reachable without the panel, which is also how the tests drive
it. `all` is the required target for a service entry.

```sh
ID=muhammadessam/network-control:service

# read
noctalia msg plugin $ID all request '{"action":"refresh"}'
noctalia msg plugin $ID all request '{"action":"diagnose"}'

# Wi-Fi
noctalia msg plugin $ID all request '{"action":"scan"}'
noctalia msg plugin $ID all request '{"action":"wifi-connect","ssid":"MyNetwork","password":"secret123"}'
noctalia msg plugin $ID all request '{"action":"wifi-connect","ssid":"Hidden","password":"secret123","hidden":true}'

# addressing
noctalia msg plugin $ID all request '{"action":"select","uuid":"<uuid>"}'
noctalia msg plugin $ID all request '{"action":"apply","uuid":"<uuid>","form":{"ipv4_method":"manual","ipv4_addresses":"10.0.0.5/24"}}'
noctalia msg plugin $ID all request '{"action":"keep"}'
noctalia msg plugin $ID all request '{"action":"revert"}'
noctalia msg plugin $ID all request '{"action":"restore"}'

# connection and radio
noctalia msg plugin $ID all request '{"action":"up","uuid":"<uuid>"}'
noctalia msg plugin $ID all request '{"action":"down","uuid":"<uuid>"}'
noctalia msg plugin $ID all request '{"action":"radio","kind":"wifi","on":true}'
```

`apply` takes a partial `form`; omitted fields count as empty. Both
`ipv4_method` and `ipv6_method` must be a supported method, so an IPv4-only
change still states its IPv6 method.

`diagnose` writes the service's whole view (connections, profile, live
addresses, primary route, permissions, scan result, pending window, restore
point) to
`~/.local/state/noctalia/plugins/data/muhammadessam/network-control/state.json`
and logs a one-line summary. That is the file to look at when the panel and
`nmcli` disagree.

## Notes

- **Profiles written**: `nmcli con mod <uuid>` for the fields that changed, then
  `nmcli con up <uuid>` when the connection is active. Joining a secured network
  creates one Wi-Fi profile (`nmcli con add`, no secret in the argument list) —
  and deletes it again if the join fails, so a network that did not work is never
  left looking saved.
- **Files written**, all in the plugin's data directory:
  `last-profile.json` (the restore point, written *before* the connection is
  modified so a failure in between still leaves something to recover from) and
  `secret.tmp` (a Wi-Fi passphrase — `nmcli con up --passwd-file` reads it
  instead of taking a secret as an argument, because a command line is
  world-readable in `/proc` while a stored NetworkManager key is root-only).
  `secret.tmp` is created empty and 0600 by `install -m 600` before the secret is
  written into it, removed on every path out including failures, and any file left
  by a shell that died mid-join is removed at startup. If it cannot be created
  privately the join fails rather than activating without the passphrase.
  `state.json` is diagnose output only.
- **Passphrases and SSIDs are byte-exact**: neither is trimmed, because leading and
  trailing spaces are legal in both. Only an all-space manual entry is rejected.
- **Commands spawned**: `nmcli -t -f … con show`, `nmcli -t -f … dev status`,
  `nmcli -t -f … dev show <dev>`, `nmcli -t -f … dev wifi list [--rescan yes]`,
  `nmcli radio`, `nmcli -t general permissions`, `nmcli con mod`, `nmcli con
  add`, `nmcli con up|down`, `nmcli con delete` (only a profile this plugin just
  created), `ip -j route get 1.1.1.1`, plus `install -m 600` and `chmod 600` for
  the passphrase file.
- **Network access**: none of its own. It reads and writes NetworkManager only.
- **Secrets**: a passphrase typed into the panel travels through the plugin's
  in-process request channel to `nmcli` and nowhere else. It is never written to
  plugin state, never logged, and never part of the `diagnose` dump.
- **Reading the live state**: the plugin reports the interface from
  `ip route get`, not the first entry in the routing table. A stray static route
  on a dummy link (metric 550 against Wi-Fi's 600) wins the table but is not
  where traffic goes.
- **DNS with DHCP**: DNS servers and search domains are stored on the profile and
  apply to every method, so a static DNS list survives a switch back to DHCP.
- **Compositor-agnostic**: nothing here talks to the compositor.
- While a confirmation window is open the service refuses every other mutation
  (join, up/down, radio, restore) instead of racing the rollback timer.
- Not implemented, deliberately: creating or deleting profiles from the panel,
  Wi-Fi secrets other than a WPA/SAE passphrase (802.1X identities and
  certificates, WEP), `shared`/hotspot mode, per-route tables, MAC cloning, and
  VPN or WireGuard profile internals. The IPv6 method does include `Ignore`,
  the usual answer for a connection whose IPv6 is handled elsewhere.

## Tests

```sh
lua tests/run.lua                    # assertions against net.luau, no host needed
sh tests/capture-fixtures.sh         # re-capture nmcli fixtures from this machine
python3 tests/check-translations.py  # every tr() key exists in en.json
python3 tests/e2e-live.py            # live end-to-end, needs the running shell
lua tests/secret-path.lua            # the passphrase path, no shell and no NetworkManager
python3 tests/make-thumbnail.py      # rebuild thumbnail.webp from the official generator
```

`tests/e2e-live.py` creates one throwaway dummy connection (no gateway, so it
cannot displace the default route) and deletes it again. It drives the plugin's
IPC surface only, and covers validation refusals, a real write, the keep path,
the timeout rollback and the restore action. It never touches an existing
profile.
