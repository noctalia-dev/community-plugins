# KWallet Secrets

NetworkManager keeps no copy of an *agent-owned* Wi-Fi password, and no copy of
a VPN password at all: it asks a registered secret agent for them every time you
connect. On a Plasma desktop that agent is plasma-nm, which reads them out of
KWallet. On a Noctalia session there is no such agent, so every one of those
networks and every VPN asks you to type a password you already saved. This
plugin fills that gap: it runs a secret agent that answers NetworkManager out of
KWallet, so they just connect.

It handles passwords, so before you enable it, read
[How your secrets are handled](#how-your-secrets-are-handled): what it reads,
who can ask it for a password, where a password can and cannot end up, and how
to check all of that yourself.

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
  `kwallet-pam` can unlock it at login, but only once `/usr/lib/pam_kwallet_init`
  runs in the session. Plasma runs it for you. On any other session, start it
  from your compositor's startup, ahead of anything that uses the wallet.
  Otherwise the wallet is locked at login. A connect that finds it locked fails
  at first, then retries by itself once the wallet is unlocked.

The plugin is compositor-agnostic: nothing in it depends on Hyprland, niri, or
any particular Wayland session.

## Usage

There is nothing to add to your bar and no panel to open. Enable the plugin and
the service starts a background secret agent; from then on, saved Wi-Fi networks
and VPNs whose passwords live in KWallet connect without prompting.

To check that it is working:

```sh
journalctl -b -t NetworkManager | grep 'agent registered'
journalctl --user -t noctalia-kwallet-secrets -f
```

The first command should list an agent named `io.github.grassyloki.kwalletSecrets`.
The second follows the plugin's own log, which prints one line per request: a
`hit` when the password came from the wallet, a `miss` when the wallet had no
entry for that network. A `wallet locked` line means the request arrived before
the wallet was unlocked. It is followed by `re-registering` once the wallet
opens, which makes NetworkManager retry the connection.

To see what the wallet actually holds, run the helper directly. It prints entry
and key *names* only, never a password:

```sh
~/.local/state/noctalia/plugins/materialized/community/kwallet-secrets/scripts/kwallet-nm-agent.py \
  --check --with-vpn --with-8021x
```

If a network or VPN still prompts, the usual causes are a locked wallet, a
profile whose password was never saved to KWallet in the first place, or a
stored password that is simply wrong — see Notes.

## Settings

Configure these under **Settings, Plugins, KWallet Secrets**. Changing any of
them restarts the helper.

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `wallet_name` | `string` | *(empty)* | Wallet to read. Empty means whichever wallet KWallet has configured for network data, normally `kdewallet`. |
| `folder_name` | `string` | `Network Management` | Folder inside the wallet holding the entries. This is where plasma-nm puts them; change it only if you keep them somewhere else. |
| `app_id` | `string` | `Noctalia KWallet Secrets` | The name KWallet shows when it asks whether to grant access to the wallet. |
| `handle_8021x` | `bool` | `false` | Also answer `802-1x` requests, for WPA-Enterprise networks such as eduroam. Off by default because those profiles often carry certificates that no wallet entry covers. |
| `handle_vpn` | `bool` | `true` | Also answer `vpn` requests — OpenVPN, vpnc, openconnect, L2TP and the rest — and NetworkManager's own `wireguard` setting, including per-peer preshared keys. On by default, because a VPN secret is agent-owned in every profile plasma-nm imports and so prompts on every single connect. |
| `unlock_prompt` | `bool` | `true` | Allow KWallet to raise its unlock dialog when the wallet is locked. Turn this off to treat a locked wallet as "no password" instead, so connecting fails quietly rather than popping a dialog. Either way, a connect that failed on a locked wallet is retried once the wallet is unlocked. |
| `debug_logging` | `bool` | `false` | Log every request, including the ones deliberately declined. Passwords are never logged at any level. |

## How your secrets are handled

This plugin reads Wi-Fi, VPN and WireGuard passwords out of your wallet and
hands them to NetworkManager, so it is fair to be wary of it. This section says
exactly what happens to a password, who can ask for one, where it can and cannot
end up, and what the plugin cannot protect you from.

You do not have to take any of it on trust. All of the secret handling is one
readable Python file, `scripts/kwallet-nm-agent.py`, about 700 lines, using
nothing but your distribution's D-Bus bindings. The service around it,
`service.luau`, only starts and stops that file and never sees a password.

### The life of one password

```
 NetworkManager               kwallet-nm-agent.py              kwalletd6
 (system service)             (runs as you)                    (your wallet)
       |                             |                              |
       |  1. GetSecrets              |                              |
       |  "psk for {uuid}, please"   |                              |
       |---- system D-Bus ---------->|                              |
       |                             |  2. is the caller            |
       |                             |     NetworkManager?          |
       |                             |     no -> refuse, log it     |
       |                             |  3. is this kind of secret   |
       |                             |     enabled in Settings?     |
       |                             |     no -> "not mine"         |
       |                             |                              |
       |                             |  4. read one entry:          |
       |                             |     Network Management /     |
       |                             |     {uuid};802-11-wireless-… |
       |                             |---- session D-Bus ---------->|
       |                             |<--- { psk: … } --------------|
       |                             |                              |
       |<--- { psk: … } -------------|  5. log "hit" with key       |
       |                             |     names only; keep nothing |
  6. connects                        |                              |
```

1. **You connect**, or NetworkManager autoconnects, to a profile whose password
   is *agent-owned* (NetworkManager keeps no copy of it). NetworkManager asks
   every registered secret agent in turn, over the system D-Bus: a local Unix
   socket, not the network.
2. **The caller is checked.** The agent answers NetworkManager and nothing else.
   See [Who can ask it for a password](#who-can-ask-it-for-a-password).
3. **The kind of secret is checked.** Wi-Fi passwords are always handled.
   WPA-Enterprise (`802-1x`) is handled only when `handle_8021x` is on, and VPN
   and WireGuard only when `handle_vpn` is on. Anything else gets
   NetworkManager's "not mine" answer, and NetworkManager moves on to the next
   agent, normally Noctalia's own password prompt.
4. **One entry is read.** The agent asks kwalletd6 for exactly one entry, in one
   folder: `{uuid};<setting>` in `Network Management` (or your `folder_name`),
   for the one profile NetworkManager named. If the entry is not there, the
   agent answers "not mine" and you get the usual prompt.
5. **The answer goes back** to NetworkManager in the same D-Bus reply. The agent
   logs one line naming the profile and the *key names* it found, never a value.
   It does not cache the password; the next request reads the wallet again.
6. **NetworkManager connects.** From here it treats the password exactly as it
   treats one you typed into a prompt or one plasma-nm supplied.

### What it can reach in your wallet

KWallet has no per-folder permissions. Opening a wallet opens all of it, so
anything that opens your wallet could technically read every entry in it. This
plugin opens one wallet, the one KWallet uses for network data (normally
`kdewallet`) or the one set in `wallet_name`, and does so under the name in
`app_id`. Depending on your KWallet settings, KWallet may ask you whether to
allow that; it is KWallet's own dialog, not the plugin's.

What the code actually reads is much narrower than what KWallet allows. Every
wallet call it makes names the one configured folder, and the only entries it
reads are the ones NetworkManager asks about, one profile at a time. Browser
passwords, SSH keys, and anything else in other folders are never read,
listed, or touched. `--check` lists entry and key *names* in that folder, not
values.

The plugin never sees your wallet password. If the wallet is locked, the agent
either lets KWallet show its own unlock dialog (`unlock_prompt`, on by default)
or answers "not mine" (`unlock_prompt` off). Either way, it cannot open a locked
wallet without you.

### Who can ask it for a password

The agent registers with NetworkManager on the system D-Bus, which is how
NetworkManager reaches it. That makes it reachable in principle by other
programs on that bus, so who gets an answer is decided in two places:

| Caller | What happens |
| --- | --- |
| NetworkManager | Served. |
| A program running as you, or as any other ordinary user | Blocked by the system bus itself before it reaches the agent. The system bus refuses method calls by default, and nothing opens that up for this agent. |
| Any other process running as root | Refused by the agent with `PermissionDenied`, and logged as `rejected GetSecrets from <bus name>: not NetworkManager`. |

The root row needs explaining. NetworkManager's own D-Bus policy lets every
root process, not only NetworkManager, call any secret agent. Root can read the
wallet file already, but that file is encrypted; this agent is sitting in front
of an *unlocked* wallet. Without a check, one D-Bus call from any root process
would return a decrypted password. So the agent records which bus name
NetworkManager currently owns and refuses every other caller, the same check
libnm's own agent code makes. Versions before 1.1.2 did not make this check.

### Where a password goes, and where it never goes

- **To NetworkManager**, in the D-Bus reply to the request that asked for it,
  and nowhere else.
- **Never to the network.** The agent opens no network socket, downloads
  nothing, and sends no telemetry. It talks to two local D-Bus buses and nothing
  else.
- **Never to disk.** The plugin has no files of its own: no cache, no state,
  no config. The agent does not even keep the files it inherits from Noctalia
  when it starts; it closes them before doing anything else. The wallet only changes when NetworkManager asks for a save or a
  delete, and only through KWallet's own API.
- **Never to the log.** Log lines hold the profile name, its UUID, the kind of
  secret, and key names, like
  `hit HomeWiFi (6fec006a-…) 802-11-wireless-security -> 1 key(s) [psk]`.
  `debug_logging` adds more requests and NetworkManager's hints, which are key
  names too, but no value at any level.
- **Briefly in the agent's memory.** A password exists in the agent's memory for
  the length of one request. Python cannot scrub memory, so the bytes can linger
  until they are reused, as in any Python program.

### What it writes

NetworkManager also calls agents to store and forget passwords, and the plugin
answers both. It never writes to the wallet on its own initiative.

- **SaveSecrets.** When a profile with an agent-owned password is saved, for
  example after you type a new Wi-Fi password into the prompt, NetworkManager
  sends the new secret. The agent writes it to `{uuid};<setting>` in the same
  folder, in the format plasma-nm uses, so the two stay interchangeable. For
  Wi-Fi, `802-1x` and WireGuard it keeps only the known secret fields. For a VPN
  it keeps whatever NetworkManager lists as the VPN's secrets.
- **DeleteSecrets.** When you delete a profile, the agent removes that
  profile's entries, so the wallet does not fill up with orphans.

### What it cannot protect you from

- **Programs running as you.** While your wallet is open, KWallet will hand its
  contents to a program running as your user that asks for them. The
  application name KWallet shows is whatever the program claims, so it
  identifies but does not authenticate. That is how KWallet works with or
  without this plugin, and the plugin opens no new route: its own interface is
  not reachable by your programs at all (see the table above). Locking the
  wallet when you step away is the protection here.
- **A determined root.** Root can read any process's memory, including this
  agent's and kwalletd6's. The caller check closes the easy route, a single
  D-Bus call; it cannot stop an attacker who already owns the machine.
- **What NetworkManager does next.** Once NetworkManager has a password, it is
  NetworkManager's: it holds it for the connection and passes VPN secrets to the
  VPN plugin that needs them. That is the same whichever agent supplied the
  password.

### Turning it off

Disable the plugin under **Settings, Plugins**, or run
`noctalia msg plugins disable grassyloki/kwallet-secrets`. The agent
unregisters from NetworkManager and exits at once, and it is not started again.
Agent-owned profiles go back to prompting. There is nothing to clean up, since
the plugin keeps no files. Your wallet entries stay where they are: they are
plasma-nm's format, and plasma-nm or a re-enabled plugin can still use them.

To confirm it is gone, `pgrep -af kwallet-nm-agent` should print nothing, and
the plugin's log should end with `shutting down`.

### Checking it yourself

```sh
# Exactly one agent, running as you, from the plugin directory:
pgrep -af kwallet-nm-agent

# Every request it answered or refused, with key names but never values:
journalctl --user -t noctalia-kwallet-secrets

# No network sockets at all (prints nothing):
ss -tunap | grep "pid=$(pgrep -f 'kwallet-nm-agent[.]py'),"

# Nothing open but its log pipe, D-Bus connections and GLib's own eventfds:
ls -l /proc/"$(pgrep -f 'kwallet-nm-agent[.]py')"/fd

# What the wallet folder holds, as names only:
~/.local/state/noctalia/plugins/materialized/community/kwallet-secrets/scripts/kwallet-nm-agent.py \
  --check --with-vpn --with-8021x
```

In the source, every wallet call lives in the `Wallet` class and names the
configured folder. Each of the four methods NetworkManager can call begins with
the caller check, `_check_caller`. And every line that writes to the log is a
`log.` call you can read in a few minutes.

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

VPN profiles are worse off still: NetworkManager never stores a VPN secret
itself, so a VPN password is agent-owned whatever the flags say. plasma-nm keeps
those in the same folder, keyed `{uuid};vpn`.

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

All three answer NetworkManager and nobody else; see
[Who can ask it for a password](#who-can-ask-it-for-a-password).

### VPN secrets are shaped differently

Two things about the `vpn` setting do not look like any other setting, and the
plugin special-cases both.

On the NetworkManager side, a reply for `vpn` nests its secrets one level
deeper: `{"vpn": {"secrets": {"password": "..."}}}`, where the inner map is
`a{ss}`, not the `a{sv}` every other setting uses. That is what libnm itself
emits and what plasma-nm sends, so it is the shape the plugin sends. (Modern
NetworkManager is lenient and will also fold flat top-level string entries into
the VPN secrets, but the nested form is the documented one.) The same asymmetry
applies when NetworkManager hands a connection *back* on a save: the `vpn`
setting arrives split into `data` and `secrets`, and only the latter holds
passwords.

On the KWallet side, the entry is not one map key per secret. NetworkManagerQt
flattens the entire VPN secret map into a single `VpnSecrets` key whose value is
`key`, separator, `value`, separator, `key`, … joined by the literal `%SEP%`.
The plugin packs and unpacks that format, so `--check` still lists real key
names and a password saved here is one plasma-nm can read.

Which secrets a VPN uses depends on the VPN plugin — openvpn has `password`,
`cert-pass` and `http-proxy-password`, vpnc has `Xauth password`, openconnect
has a cookie — so unlike Wi-Fi there is no fixed list of key names to filter
against. Whatever non-empty keys the wallet holds are returned, and whatever
non-empty keys NetworkManager sends are saved. NetworkManager passes `hints`
naming the one secret it is after; the plugin logs them and returns everything
it found anyway, exactly as plasma-nm does, because a VPN plugin routinely needs
a second secret that the hint never mentions.

`wireguard` rides along under the same setting. NetworkManager's native
WireGuard is not the `vpn` setting at all — it is its own setting, with an
agent-owned `private-key` and an agent-owned `preshared-key` per peer — but it
is a VPN to the user, and plasma-nm keys it `{uuid};wireguard`. Its reply is the
ordinary flat shape for `private-key`. A peer's preshared key needs one more
step: the wallet keys it `peers.<public-key>.preshared-key`, but sending it back
under that flat name makes NetworkManager reject the whole answer with
`secret not found`. It has to travel inside the setting's `peers` array instead,
next to the public key that says which peer it belongs to, which is what the
plugin builds from the peer list NetworkManager passes in with the request.

### Other details

Two details matter for behaviour you will actually notice. When NetworkManager
sets the `REQUEST_NEW` flag it is telling the agent that the stored password was
just rejected; the plugin answers `NoSecrets` there rather than handing back the
same wrong password, so a changed Wi-Fi or VPN password produces a prompt
instead of a retry loop. And every KWallet call is given a deadline (15 seconds by default).
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

A launch is confirmed the same way. The helper is started in the background, so
the launching shell exits successfully whatever happens to it — a missing
`systemd-cat` would look exactly like a clean start. Rather than trust that, the
service waits for the lock to appear and only then reports the agent as running;
if it never appears the service says so, logs it, and tries again on the next
check. The helper is detached from Noctalia, so the service also stops it
explicitly when the plugin is disabled or uninstalled, or when Noctalia exits.
A hot reload of `service.luau` leaves it running. The four commands the plugin depends on are verified before any of this,
and a missing one disables the plugin with a message naming it rather than
failing quietly.

## Notes

- **Processes spawned.** One long-lived `python3` process per session. Around
  it the service runs only short-lived shell commands: `grep` against
  `/proc/net/unix` and `id -u` to check whether the helper is up, `setsid` plus
  `systemd-cat` to launch it, and `pkill` to stop it when a setting changes.
  `grep`, `id`, and `setsid` are not declared as dependencies because they come
  with coreutils and util-linux on every supported system.
- **Network access.** None. The helper talks to two D-Bus buses and nothing
  else: NetworkManager on the system bus, KWallet on the session bus.
- **Files written.** None. The only thing the plugin ever changes is wallet
  content, and only through KWallet's own API when NetworkManager asks for a
  save or a delete.
- **Sensitive data.** Wi-Fi, VPN and WireGuard passwords pass through the helper
  on their way from the wallet to NetworkManager. They are never logged, stored,
  or sent anywhere else; see
  [How your secrets are handled](#how-your-secrets-are-handled).
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
