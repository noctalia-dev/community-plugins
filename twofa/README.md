# 2FA

Two-factor (TOTP) codes in Noctalia: a bar icon, a panel with live codes and a launcher provider. Secrets are kept in
the system keyring (Secret Service, through `secret-tool`) and codes are computed in Luau (RFC 6238, HMAC-SHA1), so no
separate authenticator app is needed.

## Plugin

| Field | Value |
| --- | --- |
| ID | `lycorisnd/twofa` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `service`; launcher provider: `codes` |
| Launcher Prefix | `/totp` |

## Requirements

- `secret-tool` (libsecret) and a running Secret Service provider such as gnome-keyring or KeePassXC with Secret
  Service integration. The keyring is unlocked on first use if it is locked.
- `grim`, `slurp` and `zbarimg` (zbar) for scanning a QR code on screen.
- Optional: `wl-copy` (wl-clipboard). When present, codes are copied with `--sensitive` so clipboard managers,
  including Noctalia's history, skip them; without it the plugin falls back to the regular clipboard API.

## Usage

Add the **2FA** widget to a bar. **Left click** opens the panel; the tooltip shows how many accounts are stored and the
icon turns red when the keyring cannot be read. The panel can also be toggled directly:

```sh
noctalia msg panel-toggle lycorisnd/twofa:panel
```

In the panel:

- Each row shows the service, the account and the current code; one countdown next to the search field shows how long
  the codes stay valid (red for the last 5 seconds).
- **Click a row** to copy its code. Type in the search field to filter; **Enter** copies the outlined row.
- **✎** switches to edit mode: rename an account or delete it (delete asks for a second click).
- **+** adds accounts:
  - **QR on screen**: the panel closes and you select the area with the QR code.
  - **Paste**: an `otpauth://` link or a Google Authenticator export (`otpauth-migration://`, "Transfer accounts →
    Export") from the clipboard. The clipboard is cleared after reading it.
  - **Manual**: service, account and the Base32 secret key a site shows instead of a QR code. The key is validated
    while you type.

In the launcher, type `/totp` followed by a service name, for example `/totp github`; **Enter** copies that account's
current code. The provider is excluded from global search, so codes only appear behind the prefix.

Only time-based SHA1 codes (6–8 digits) are supported, which covers almost every site.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `glyph` | `glyph` | `shield-lock` | Icon shown in the bar widget. |

## IPC

```sh
noctalia msg plugin lycorisnd/twofa:service all scan            # scan a QR code on screen
noctalia msg plugin lycorisnd/twofa:service all import <file>   # import otpauth:// or otpauth-migration:// lines
noctalia msg plugin lycorisnd/twofa:service all reload          # re-read the keyring
```

`import` accepts a plain-text export from GNOME Authenticator or FreeOTP+ (one `otpauth://` link per line) as well as
Google Authenticator export links. Delete the file afterwards: it holds your secrets in plain text.

## Notes

- **Storage.** One keyring item per account, with the attributes `application=lycorisnd-twofa` and a hex `id`. The
  secret is a JSON record (service, account, key, digits, period), so account names are encrypted too. Keyring
  managers such as Seahorse show the items as "2FA: …".
- **Processes.** The plugin runs `secret-tool` (search, store, clear), `grim`, `slurp` and `zbarimg` for QR scans, and
  `wl-copy` for copying. Secrets and codes never appear in a process's arguments: they are passed through stdin.
- **Files.** When storing an account, the record goes through a 0600 file in `$XDG_RUNTIME_DIR` (a per-user tmpfs)
  that is deleted right after `secret-tool` reads it. QR captures are written to the same place and deleted right
  after decoding. Nothing else is written to disk.
- **Network.** None.
- **Notifications** name the service but never show the code.
- **Threat model.** The login keyring is encrypted at rest and unlocked for the session, so any process running as you
  (including other Noctalia plugins, which are trusted code) can read it. This is the same as for browser passwords or
  any other Secret Service app.
