# localsend-controller

The LocalSend receiver and sender behind the LocalSend Plus plugin for Noctalia. The plugin starts it as
`localsend-controller daemon` and sends it one short command per action over a private Unix socket. It links the
official LocalSend core library (`packages/core` in `localsend/localsend`).

## Building

You need Rust 1.97 or newer with `cargo`, a C compiler (`gcc`, for `ring`) and, at run time, `wl-clipboard`.

```sh
cargo install --locked --path controller --target-dir ~/.cache/localsend-plus/target
```

This installs `~/.cargo/bin/localsend-controller`. The build downloads the crates and the LocalSend core; the
controller itself downloads nothing when it runs.

```sh
cargo test --locked      # unit tests, plus two daemons talking over loopback
```

## Commands

| Command | What it does |
| --- | --- |
| `daemon` | Runs the receiver and discovery. Needs `--destination` and `--state-directory`; takes `--port`, `--alias`, `--visibility everyone\|favorites\|hidden`, `--pin-file PATH`, `--auto-accept off\|favorites\|everyone` and `--device-model TEXT` |
| `send FILE... [DEVICE]` | Sends from a terminal, asks for the device when needed and waits for the result; `--list` prints the online devices. Uses the plugin's socket unless `--socket` is given. See the plugin README |
| `snapshot` | Prints the daemon state: devices, the pending request, transfers |
| `refresh` | Looks for devices again (in favorites and hidden mode it probes the favorites only) |
| `add-device --address HOST[:PORT]` | Probes one address over HTTPS and lists the device found there |
| `send-files --device FP --path P...` | Sends files and folders; `--pin-file PATH` for a receiver with a PIN |
| `read-clipboard` | Prints the SHA-256 of the clipboard text and its first characters; needs no daemon |
| `send-clipboard --device FP --expect-sha256 HEX` | Sends the clipboard text if it still has that hash |
| `accept`, `decline`, `cancel` | Answers the pending request or stops a transfer |
| `set-visibility --mode M --favorite FP[=HOST:PORT]...` | Switches visibility and sets the favorites |
| `shutdown` | Stops the daemon |

Every command except `read-clipboard` and `send` needs `--socket PATH`. All but `send`, which talks to a person,
print one JSON object:
`{"ok":true,"result":...}` or `{"ok":false,"error":{"code":...,"message":...}}`.

The daemon starts without favorites. The plugin sends them with `set-visibility` once the daemon reports ready, so
their addresses never show up in `ps`.

### Name

Without `--alias`, the first start picks a random name such as "Swift Mango" and saves it as `alias` in the state
directory. Later starts reuse it.

### PINs

A PIN always comes in a file, never as an argument. The controller reads the file and deletes it at once, so the PIN
does not stay on disk or show up in `ps`. Snapshots and logs never contain it.

The LocalSend receiver reads the PIN only when it starts, so a new PIN means restarting the daemon. It answers 401
both without a PIN and with a wrong one; the controller tells them apart by whether it sent a PIN (`pin_required`,
`pin_invalid`). After three wrong PINs from one address the receiver refuses that address until it restarts
(`pin_locked`). It remembers 200 addresses, so a sender that changes addresses is not stopped by this.

### Auto-accept

`--auto-accept` accepts file transfers without asking, from favorites or from everyone. Text messages always wait for
a decision, because accepting one replaces the clipboard. `everyone` needs a PIN of at least 8 characters; with a
shorter PIN or none it acts as `favorites`, and the snapshot reports the mode in effect. Visibility, the decline
cooldown and the free space check apply as for a manual accept. The controller matches the sender by its TLS
certificate fingerprint, never by its name.

### Safety checks

Transfers go only over HTTPS with the receiver's certificate pinned. A fingerprint announced over plain HTTP counts
as a claim and is never trusted, and a device is online only if it answered over HTTPS recently. The controller
also pins a favorite's certificate when it probes it, so a stranger at an old address learns nothing.

Incoming file names cannot point outside the save folder. The controller rejects bidi controls and zero-width
characters in sender names, replaces them with `_` in file names and strips them from messages, together with other
control characters. It also strips them from the names and models of discovered devices before they reach the
snapshot, so a device cannot put terminal escapes into `send` or the shell completions. A cancel goes to a sender
over HTTPS pinned to the certificate it sent with, whatever protocol it claims. A text preview appears only for a real embedded message, so a text file with a fake preview
shows up as a regular file.

An upload stops when a source file cannot be read, so the receiver never gets a truncated file. The controller does
not read a clipboard that a password manager marked with `x-kde-passwordManagerHint`.

## License

MIT, see `LICENSE`. Based on omarchy-localsend by cryptobredda.
