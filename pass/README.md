# Pass

Pass adds password-store search to the Noctalia launcher so you can copy passwords and OTP codes from `pass`.

## Plugin

| Field | Value |
| --- | --- |
| ID | `emrtnn/pass` |
| Entries | Launcher provider: `search`; service: `cache` |
| Launcher Prefix | `/pass` |

## Requirements

Install `pass`, `pass-otp`, `gpg`, and `wl-copy` on `PATH`.

A working password store is expected in the same location `pass` uses: `$PASSWORD_STORE_DIR` when that variable is set, otherwise the default `~/.password-store`. OTP copying requires entries that are configured for `pass-otp`.

## Usage

Open the Noctalia launcher and type `/pass` to search password-store entries indexed by the `cache` service. Activate a result from launcher provider `search` to copy the password with `pass -c <entry>`.

To copy an OTP code instead, type `/pass otp <query>` and activate the matching result. For example:

```text
/pass otp github
```

If GPG needs an unlock passphrase, the plugin opens the configured terminal and runs the same copy command there so you can unlock the key interactively.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_interval` | `int` | `30` | Seconds between password-store rescans. Minimum `5`, maximum `3600`. |

## IPC

This plugin does not expose custom IPC actions. It provides launcher provider `search` and background service `cache` entries only.

## Notes

- Filesystem reads: the service recursively scans `$PASSWORD_STORE_DIR` when set, otherwise `~/.password-store`, and indexes non-hidden `*.gpg` file names. It does not read decrypted password contents.
- Spawned processes: activating a password result runs `pass -c <entry>`; activating an OTP result runs `pass otp -c <entry>`. If GPG reports an unlock failure, the plugin opens a terminal and runs the same command interactively.
- Clipboard/privacy: copied secrets are handled by `pass`/`pass-otp` and the system clipboard tooling, typically including `gpg` and `wl-copy` on Wayland. The plugin stores only entry paths/titles in Noctalia state, not decrypted secrets.
- Network: the plugin makes no network calls.
- Writes: the plugin does not write files directly. `pass`, `pass-otp`, `gpg`, or clipboard tools may update their own runtime files such as agent or clipboard state.
