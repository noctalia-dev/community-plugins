# Layout Fix

Fixes text typed in the wrong keyboard layout, Punto-style: `ghbdtn` becomes
`привет`, the layout switches, and you keep typing. It runs quietly in the
background — no bar widget, no panel, nothing to click.

The layouts are whatever your compositor is configured with. They are read
from niri and compiled through libxkbcommon at startup, so a `us,ru` setup
and a `de,ru` one both work without touching the code, and the matching
spell-check dictionaries are looked up for you.

## Plugin

| Field | Value |
| --- | --- |
| ID | `umedbazarov/layout-fix` |
| Entries | Service: `service` |

## Requirements

- `niri`, with at least two keyboard layouts configured
  (`xkb { layout "us,ru" }`). Other compositors are not supported yet: the
  layout query and switch go through `niri msg`.
- **Access to the keyboard devices.** The correction daemon reads key
  presses from `/dev/input`, which requires membership in the `input`
  group:

  ```sh
  sudo usermod -aG input "$USER"    # then log out and back in
  ```

  The plugin checks this on startup and tells you if it is missing.
- `python3` (standard library only) and `wtype`, required — the daemon and
  the retyping of a corrected word.
- `bash`, `cp`, `chmod`, `setsid` and `pkill`, required — installing,
  starting and stopping the daemon. All part of a base system.
- `hunspell` with a dictionary per layout, strongly recommended. Without
  dictionaries the plugin falls back to heuristics: safe, but it misses
  words. The plugin reports which dictionaries are missing, and can install
  them for you — see **Dictionaries** below.

## Usage

Enable the plugin and it starts working: finish a word that was typed in
the wrong layout, and it is rewritten as you type the next space.

Bind the manual actions in your niri config — useful when automatic mode is
off, or when a correction was not wanted:

```kdl
binds {
    // Re-encode what has been typed so far
    Mod+Shift+X { spawn "noctalia" "msg" "plugin" "umedbazarov/layout-fix:service" "all" "fix"; }
    // Undo the last automatic correction
    Mod+Shift+Z { spawn "noctalia" "msg" "plugin" "umedbazarov/layout-fix:service" "all" "undo"; }
    // Toggle automatic mode
    Mod+Shift+A { spawn "noctalia" "msg" "plugin" "umedbazarov/layout-fix:service" "all" "auto"; }
}
```

### When it corrects, and when it does not

A word is judged once it is finished (a separator or Enter). It is
corrected only when **both** are true: what is on screen is not a word of
the current language, and its re-encoding *is* a word of the other one.
That is why `grep`, `systemctl`, `npm` and ordinary English words survive
untouched, while `yjhvfkmyj` becomes `нормально`.

Colloquial words are in no dictionary, so a re-encoding it does not list
can still be corrected — but only when it is within a couple of edits of a
word the dictionary suggests. `максималка` is the same letters as the
suggestion `макси малка` and gets corrected; `libgcrypt` re-encodes to
`дшипскнзе`, five edits from anything, and is left alone.

Separators are derived from the actual layout tables — only keys that
produce a letter in *no* layout end a word. The Latin `,` key is the
Russian letter `б`, so `hf,jnftn` is treated as one word (`работает`)
rather than two.

Words shorter than three characters, and anything typed with Ctrl, are
never touched. A short word is rewritten only in the company of a longer
one: correcting `vfrcbvfkrf` in `f vfrcbvfkrf` takes the `f` with it,
across single spaces and never over a word the dictionary knows, so the
`a` of `a docker` stays as it is.

## Dictionaries

The **Dictionaries** setting decides what happens when a dictionary for one
of your layouts is missing:

- *Tell me what to install* (default) — a notification naming the
  dictionaries, e.g. `ru`, `en`.
- *Install automatically* — one `pkexec pacman -S` for the matching
  `hunspell-*` packages, asking for your password once.
- *Do not check* — stay on heuristics.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `auto` | `bool` | `true` | Correct a word as soon as it is finished. Off: only the keybindings correct. |
| `dictionaries` | `select` | `notify` | What to do about missing dictionaries: notify, install, or ignore. |
| `hotkey_hint` | `bool` | `true` | Show once how to bind the fix and undo actions — see below. |

The hint is a single notification on the first start, and only for a config
that does not already spawn this plugin's IPC: with no widget and no panel,
it is the one place the manual actions can be mentioned at all. Having shown
it once, the plugin remembers and stays quiet.

## IPC

```sh
noctalia msg plugin umedbazarov/layout-fix:service all fix
noctalia msg plugin umedbazarov/layout-fix:service all undo
noctalia msg plugin umedbazarov/layout-fix:service all auto
noctalia msg plugin umedbazarov/layout-fix:service all status
```

`status` writes the daemon's state to the Noctalia log: layouts in use,
dictionaries loaded, corrections made, and how many key presses were seen.

## Privacy

This plugin reads your keyboard, so it is worth being precise about what
that means.

- The daemon keeps a buffer of **keycodes**, capped at 120 characters, in
  memory only. It is **never written to disk** and never leaves the
  machine.
- The buffer is cleared on Enter, Tab and Escape, after 30 seconds of
  inactivity, and on any Ctrl chord.
- `status` reports the buffer's *length*, never its contents.
- Disabling the plugin stops the daemon; nothing keeps watching afterwards.
- The daemon is `scripts/layout-fix`: plain Python, standard library only,
  about 600 readable lines. Nothing is downloaded or executed from the
  network.

Passwords are the obvious concern: Wayland gives no reliable way to know
that a field is a password field, so type passwords with automatic mode off
if that worries you (`Mod+Shift+A`, or the `auto` setting).

## Notes

- **Commands spawned.** `niri msg keyboard-layouts` and `niri msg action
  switch-layout` (layout state), `wtype` (erase and retype the corrected
  word), `hunspell -a` (one process per dictionary, fed single words),
  `hunspell -D` (which dictionaries exist), and `pkexec pacman -S` only if
  you choose automatic dictionary installation.
- **Files written.** `~/.config/layout-fix/config` (one line: automatic
  mode on or off) and a copy of the daemon in the plugin's data directory.
  A unix socket in `$XDG_RUNTIME_DIR`, mode 0600, carries the commands.
- **Layout tables** come from `libxkbcommon` via `ctypes` — the same
  library the compositor uses, so the tables match your keymap exactly,
  including punctuation that differs between layouts.
- **Tests**: `python3 tests/test-layout-fix.py` builds the fixtures from
  your real keymap and reports correct decisions, false positives and
  misses. With `us,ru` and both dictionaries installed it is 50/50 with no
  false positives.

## License

MIT.
