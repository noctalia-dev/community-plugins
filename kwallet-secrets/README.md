# KWallet Secrets

NetworkManager keeps no copy of an *agent-owned* Wi-Fi password: it asks a
registered secret agent for it every time you connect. On a Plasma desktop that
agent is plasma-nm, which reads the password out of KWallet. On a Noctalia
session there is no such agent, so every one of those networks asks you to type
a password you already saved. This plugin fills that gap: it runs a secret agent
that answers NetworkManager out of KWallet, so those networks just connect.

## Plugin

| Field | Value |
| --- | --- |
| ID | `grassyloki/kwallet-secrets` |
| Entries | service: `service` |

## Requirements

- `python3`, with the `python-dbus` and `python-gobject` bindings. Both ship as
  distro packages (`python-dbus` / `python3-dbus`, `python-gobject` /
  `python3-gi`); no `pip` install and no virtualenv is involved.
- `kwalletd6`, the classic KWallet daemon. It provides the `org.kde.KWallet`
  D-Bus interface this plugin reads. The newer `ksecretd` serves the same wallet
  file over the Secret Service API but does not implement that interface, so it
  is not a substitute.
- `pkill` (from procps-ng) and `systemd-cat` (from systemd), used to supervise
  the helper process and to route its output to the journal.
- NetworkManager as the network stack, and a KWallet wallet that is unlocked.
  `kwallet-pam` unlocks it at login; without it, the first lookup of the session
  raises KWallet's unlock dialog.

The plugin is compositor-agnostic: nothing in it depends on Hyprland, niri, or
any particular Wayland session.

## Usage

There is nothing to add to your bar and no panel to open. Enable the plugin and
the service starts a background secret agent; from then on, saved Wi-Fi networks
whose passwords live in KWallet connect without prompting.

To check that it is working:

```sh
journalctl -b -t NetworkManager | grep 'agent registered'
journalctl --user -t noctalia-kwallet-secrets -f
```

The first command should list an agent named `io.github.grassyloki.kwalletSecrets`.
The second follows the plugin's own log, which prints one line per request: a
`hit` when the password came from the wallet, a `miss` when the wallet had no
entry for that network.

To see what the wallet actually holds, run the helper directly. It prints entry
and key *names* only, never a password:

```sh
~/.local/state/noctalia/plugins/materialized/community/kwallet-secrets/scripts/kwallet-nm-agent.py \
  --check --with-8021x
```

If a network still prompts, the usual causes are a locked wallet, a profile
whose password was never saved to KWallet in the first place, or a stored
password that is simply wrong — see Notes.

## Settings

Configure these under **Settings, Plugins, KWallet Secrets**. Changing any of
them restarts the helper.

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `wallet_name` | `string` | *(empty)* | Wallet to read. Empty means whichever wallet KWallet has configured for network data, normally `kdewallet`. |
| `folder_name` | `string` | `Network Management` | Folder inside the wallet holding the entries. This is where plasma-nm puts them; change it only if you keep them somewhere else. |
| `app_id` | `string` | `Noctalia KWallet Secrets` | The name KWallet shows when it asks whether to grant access to the wallet. |
| `handle_8021x` | `bool` | `false` | Also answer `802-1x` requests, for WPA-Enterprise networks such as eduroam. Off by default because those profiles often carry certificates that no wallet entry covers. |
| `unlock_prompt` | `bool` | `true` | Allow KWallet to raise its unlock dialog when the wallet is locked. Turn this off to treat a locked wallet as "no password" instead, so connecting fails quietly rather than popping a dialog. |
| `debug_logging` | `bool` | `false` | Log every request, including the ones deliberately declined. Passwords are never logged at any level. |

## How it works

### The problem

Every saved Wi-Fi profile in NetworkManager marks its password with a
*secret flag*. `psk-flags=0` means NetworkManager stores the password itself, in
`/etc/NetworkManager/system-connections`, and any client can connect. `psk-flags=1`
means *agent-owned*: NetworkManager deliberately keeps no copy and asks a
registered secret agent at connect time. plasma-nm sets that flag on everything
it saves, so a machine that used to run Plasma typically has a large pile of
agent-owned profiles whose passwords live only in KWallet, under a folder called
`Network Management`, keyed `{uuid};802-11-wireless-security`.

Noctalia registers its own secret agent, but that agent has no persistent store
— all it can do is prompt. So on a Noctalia session those profiles ask for a
password on every connect, even though the password is sitting in the wallet.

### The fix

`scripts/kwallet-nm-agent.py` is a small daemon that registers on the system bus
as a second NetworkManager secret agent, under the identifier
`io.github.grassyloki.kwalletSecrets`. It implements the three calls
NetworkManager makes on an agent:

- **GetSecrets** — looks up `{uuid};<setting>` in the wallet folder and returns
  the keys it finds. On a miss it answers with the `NoSecrets` error, which is
  NetworkManager's cue to ask the next agent in line. That is what keeps
  Noctalia's prompt working as the fallback for a network the wallet has never
  seen: this plugin adds a path, it does not take one away.
- **SaveSecrets** — writes the password into the wallet when a profile is added
  or changed, so a password you type once ends up in the same store the plugin
  reads from.
- **DeleteSecrets** — removes the wallet entry when the profile is deleted, so
  the wallet does not accumulate orphans.

Two details matter for behaviour you will actually notice. When NetworkManager
sets the `REQUEST_NEW` flag it is telling the agent that the stored password was
just rejected; the plugin answers `NoSecrets` there rather than handing back the
same wrong password, so a changed Wi-Fi password produces a prompt instead of a
retry loop. And every KWallet call is given a deadline (15 seconds by default).
`kwalletd6` can wedge — it has been seen stuck in `futex_wait`, hanging every
`open()` — and a stuck wallet has to degrade to "no password" rather than
freezing the connection attempt.

### Reading the wallet

KWallet stores these entries as *maps*, which on the wire are a raw Qt
`QDataStream` dump of a `QMap` of strings: a big-endian count, then alternating
keys and values, each a byte length followed by UTF-16 big-endian text. The
helper encodes and decodes that format directly, which is why it needs no KDE or
Qt bindings — just D-Bus and a main loop.

### Supervision

`service.luau` does no secret handling at all. It starts the helper under
`systemd-cat`, so the helper's output lands in the journal under the tag
`noctalia-kwallet-secrets` instead of a private log file, and re-checks every 30
seconds that it is still alive. "Alive" is decided by looking for the helper's
single-instance lock, an abstract unix socket, in `/proc/net/unix`; the helper
takes that lock at startup and a duplicate copy exits immediately, so no
combination of restarts can end up with two agents fighting over the same
identifier.

## Notes

- **Processes spawned.** One long-lived `python3` process per session. Around
  it the service runs only short-lived shell commands: `grep` against
  `/proc/net/unix` and `id -u` to check whether the helper is up, `setsid` plus
  `systemd-cat` to launch it, and `pkill` to stop it when a setting changes.
  `grep`, `id`, and `setsid` are not declared as dependencies because they come
  with coreutils and util-linux on every supported system.
- **Network access.** None. The helper talks to two D-Bus buses and nothing
  else: NetworkManager on the system bus, KWallet on the session bus.
- **Files written.** None. The plugin writes no state of its own; the only thing
  it ever changes is wallet content, and only through KWallet's own API in
  response to a NetworkManager save or delete.
- **Passwords are never logged.** Log lines record the profile name, its UUID,
  the setting, and which key *names* were found — never a value. `--check` obeys
  the same rule.
- **This does not migrate anything.** Profiles that already store their password
  in NetworkManager keep doing that. If you would rather stop depending on the
  wallet for one network, `nmcli connection modify UUID
  802-11-wireless-security.psk-flags 0` together with the password moves it into
  NetworkManager's own store.
- **Running it by hand.** The helper lives at
  `~/.local/state/noctalia/plugins/materialized/community/kwallet-secrets/scripts/kwallet-nm-agent.py`
  once the plugin is installed, and `--help` lists every flag. Stop the
  supervised copy first, since a second instance exits immediately on its lock:

  ```sh
  cd ~/.local/state/noctalia/plugins/materialized/community/kwallet-secrets
  pkill -f 'kwallet-nm-agent[.]py'
  ./scripts/kwallet-nm-agent.py --debug
  ```

  The service starts its own copy again within 30 seconds of the manual run
  ending.
