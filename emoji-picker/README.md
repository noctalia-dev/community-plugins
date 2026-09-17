# Emoji & Symbol Picker

A Raycast-inspired emoji and Unicode symbol browser for Noctalia: instant
fuzzy search over ~4,000 emoji and symbols, category browsing, and a
frequently-used section that learns from what you pick. Selecting an entry
copies it to the clipboard (and can optionally run a paste command), then
closes the panel — built for a bind-Select-paste flow.

## Plugin

| Field | Value |
| --- | --- |
| ID | `liamwh/emoji-picker` |
| Entries | Panel: `wide`; panel: `desktop`; panel: `compact` |

The three panel entries share one script and differ only in window size, so
you can bind the one that suits each display — `wide` for ultrawide
monitors, `desktop` for 1080p-class displays, `compact` for laptop panels.

## Usage

Bind a key to the panel that fits your display (Noctalia Settings →
Shortcuts → Panel, or your compositor's spawn). For example:

```sh
noctalia msg panel-toggle liamwh/emoji-picker:wide
```

The other entries, same command shape:

```sh
noctalia msg panel-toggle liamwh/emoji-picker:desktop
noctalia msg panel-toggle liamwh/emoji-picker:compact
```

- **Type** to search names and keywords — "coffee", "arrow right",
  "euro", "plusminus", or paste a character itself to find it.
- **Arrows** move the selection, **Enter** copies the selected entry and
  closes the panel, **Escape** closes without copying.
- Without a query, the panel shows **Frequently Used** (ranked by a
  recency-decayed frequency score) plus category tabs along the top.
- Queries that name a symbol ("euro", "gbp", "check") rank the plain
  character (€, £, ✓) above related emoji, so text symbols are one
  keystroke away too.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `paste_command` | `string` | `""` | Optional shell command run after the copy. `{emoji}` is replaced with the shell-quoted character. Empty copies to the clipboard only. |

Because Wayland deliberately prevents one surface from injecting
keystrokes into another, the plugin does not ship its own paste machinery.
If you want paste-on-select and already run an input-injection tool, configure it here, for example:

- `ydotool key -d 20 29:1 47:1 47:0 29:0` — press Ctrl+V after the copy
  (the clipboard already holds the character);
- `wtype {emoji}` — type the character literally.

The command runs asynchronously after the panel closes, when the window
you launched the picker from has its focus back.

## Requirements

None. The paste setting is optional and only needs a tool if you configure
one (see above).

## Notes

- **Data**: `assets/emoji.json` is committed data generated from pinned
  Unicode sources (CLDR 47 English annotations + Unicode 16.0
  emoji-test.txt and UnicodeData.txt) by `tools/emoji-list-gen.py`.
  Regenerate with that script; see its docstring for the exact inputs.
  Licensing: CLDR data is Unicode-licensed, Unicode data files are
  Unicode-licensed; the generated dataset and this plugin's code are MIT.
- **Files written**: one — `<plugin data dir>/usage.json`, the
  frequently-used counters (pick counts and timestamps, per character).
  Deleting it resets Frequently Used.
- **Network**: none. **Processes**: none spawned by default; only the
  optional `paste_command` you configure yourself.
- Search runs locally over the bundled dataset on every keystroke; the
  dataset ships pre-indexed (lowered names/keywords/aliases) so a
  full-dataset search stays well inside the shell's per-callback CPU
  budget (see `tests/`).
- `tests/` holds a self-contained search/ranking/interaction suite
  runnable with the stock `luau` CLI: `python3 tests/build_test.py --out
  /tmp/t.luau && luau /tmp/t.luau`.
