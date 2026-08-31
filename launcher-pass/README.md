# Launcher pass

Browse a [GNU Pass](https://www.passwordstore.org/) password store from the
Noctalia launcher and copy or auto-type passwords, OTP codes, usernames, and any
other field — without opening a terminal.

## Plugin

| Field | Value |
| --- | --- |
| ID | `mellotanica/launcher-pass` |
| Entries | Launcher provider: `pass` |
| Launcher Prefix | `/pass` |

The prefix is `pass` preceded by your launcher's provider prefix
(`shell.launcher.provider_prefix`, `/` by default). Every example below assumes
the default, so adjust `/pass` if you changed it.

## Requirements

Install `pass`, `find`, and `grep` on `PATH`. `pass` also needs `gpg` and a
Wayland clipboard helper (`wl-clipboard`) for its `-c` copy mode.

Optional:

- `pass-otp` — enables the **Copy OTP** / **Type OTP** rows. They appear only for
  entries whose decrypted body contains an `otpauth://` line.
- `wtype` — enables every **Type** row. If it is not on `PATH` the Type rows are
  hidden and only the Copy rows are shown.

A working password store is expected where `pass` looks for it:
`$PASSWORD_STORE_DIR` when set, otherwise `~/.password-store`. Override it with
the **Password store path** setting.

## Usage

Open the Noctalia launcher and type `/pass`.

| Input | Result |
| --- | --- |
| `/pass` | list the store root |
| `/pass <query>` | fuzzy-search the whole store (see below) |
| `/pass work/` | browse inside the `work` folder |
| `/pass work/aws pr` | fuzzy-search inside `work/aws` |

Activating a **folder** drills into it; a **"Go back"** row returns to the
parent. Activating an **entry** decrypts it with `pass show` and opens its detail
view, which lists, in order:

1. **Copy Password** / **Type Password**
2. **Copy OTP** / **Type OTP** — only when the entry has an `otpauth://` line
3. **Copy Username** / **Type Username** — the value of the first `login`,
   `user`, or `username` field (case-insensitive), or the entry's own name when
   there is none
4. **Copy `<field>`** / **Type `<field>`** for every remaining `key: value` line,
   in file order
5. **Edit** — open `pass edit <entry>` in a terminal (only when a terminal
   resolves; see below)
6. **Go back** to the entry's folder

In the detail view, keep typing to filter these rows: `/pass work/aws/root otp`
shows only the two OTP rows. The filter uses the same match rule as search
(spaces are wildcards).

**Copy** puts the value on the clipboard. Password and OTP go through `pass -c` /
`pass otp -c`, so the clipboard is cleared automatically after the timeout;
usernames and other fields are copied directly and are *not* auto-cleared.
**Type** closes the launcher, waits *Type delay*, then types the value with
`wtype`.

**Edit** closes the launcher and runs `pass edit <entry>` in a terminal, letting
you change the entry's contents in an editor (`pass` re-encrypts on save). The
terminal comes from the **Terminal command** setting; if that is blank the
plugin uses `$TERMINAL`, then the first of `ghostty`, `kitty`, `alacritty`,
`wezterm`, `foot`, `konsole`, `xterm` found on `PATH`. When none of those
resolve, the Edit row is hidden. The **Editor command** setting, when set, is
exported as `EDITOR` for that run; left blank, `EDITOR` is not touched and `pass`
uses its own default. The decrypted-entry cache is dropped after an edit, so
reopening the entry shows the new contents.

If GPG needs a passphrase, a pinentry dialog appears; the launcher hides itself
so the dialog can take focus and reopens once decryption finishes.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `storePath` | `folder` | *(empty → `~/.password-store`)* | Exported as `PASSWORD_STORE_DIR` to every `pass` call. |
| `clipTimeout` | `string` | *(empty)* | Seconds before `pass` clears the clipboard after **Copy Password** / **Copy OTP**. Empty falls back to the `PASSWORD_STORE_CLIP_TIME` environment variable, then to `pass`'s own default. Only a positive integer takes effect. |
| `typeDelay` | `int` | `500` | Milliseconds to wait after the launcher closes before `wtype` starts typing, so the compositor can restore focus to the field you were in. *(Advanced. The v4 label "Launcher Close Delay" was misleading — this is the pre-typing delay.)* |
| `wtypeDelay` | `int` | `12` | Milliseconds between simulated keystrokes. Increase it if characters are dropped. *(Advanced.)* |
| `pinentryGraceMs` | `int` | `50` | Milliseconds to wait for a decrypt to finish before assuming a pinentry dialog is blocking and hiding the launcher. If your GPG agent already has the passphrase cached, the launcher never flickers. Lower values let the pinentry dialog take focus more easily but can make the launcher flicker more often; higher values (around 200–300ms) give a more stable launcher but risk the pinentry dialog spawning while the launcher is still open and waiting out the timeout, in which case it may not get focus depending on your window manager. *(Advanced.)* |
| `detailActionOrder` | `select` | `copy` | In an entry's detail view, whether the **Copy** row (`copy`) or the **Type** row (`type`) comes first for each value. *(Advanced.)* |
| `detailActionGrouping` | `select` | `interleaved` | `interleaved`: each value's Copy and Type rows sit together. `grouped`: every Copy row first, then every Type row (each block in the `detailActionOrder` direction). *(Advanced.)* |
| `terminalCommand` | `string` | *(empty)* | Terminal for the **Edit** action, as a full command prefix including its exec flag (`foot -e`, `kitty -e`, `gnome-terminal --`). Empty auto-detects from `$TERMINAL`, then a common terminal on `PATH`. When nothing resolves the Edit row is hidden. *(Advanced.)* |
| `editorCommand` | `string` | *(empty)* | Exported as `EDITOR` for the **Edit** action's `pass edit` run (`nvim`, `code --wait`, …). Empty leaves `EDITOR` unset so `pass` uses its own default. *(Advanced.)* |

## IPC

This plugin exposes no custom IPC actions. To open the launcher straight into
this provider, use Noctalia's panel IPC:

```sh
noctalia msg panel-open   launcher "/pass "
noctalia msg panel-toggle launcher "/pass "
noctalia msg panel-close  launcher
```

Replace `/` with your `provider_prefix` if you changed it. The plugin uses these
same `panel-close` / `panel-open` commands internally to juggle focus around the
GPG pinentry prompt.

## Notes

- **Auto-paste:** Noctalia's `shell.launcher.auto_paste` (Ctrl+V / Shift+Insert
  after a copy) only applies to the built-in providers — the plugin runtime has
  no hook to opt in. The **Type** rows exist to cover that case; they insert the
  value with `wtype` regardless of the `auto_paste` setting.
- **Index file:** `find` lists the non-hidden folders and `*.gpg` names under the
  store once into `<plugin data dir>/store.index` (rebuilt in the background,
  ~once a minute). Every keystroke `grep`s that file — it holds paths only, never
  decrypted content. Decrypted contents are read only when you open an entry's
  detail view (`pass show`), and are cached in memory for 60 s.
- **Spawned processes:** `find` (index build); `grep` (per keystroke); `pass
  show`, `pass -c`, `pass otp`, `pass otp -c` (per action); `wtype` and `sleep`
  (Type actions); a terminal running `pass edit` (Edit action); `noctalia msg
  panel-*` (pinentry focus handling).
- **Secrets:** decrypted values live only in the plugin's in-memory cache and on
  the system clipboard via `pass` / Noctalia. Neither Noctalia state nor the
  index file holds decrypted content. Navigation state is encoded in the launcher
  query, not persisted.
- **Network:** none.
- **Writes:** only the `store.index` file above; `pass`, `gpg`, and clipboard
  tools manage their own runtime state.
