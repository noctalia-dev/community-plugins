# Scratchpad

Plain-text sticky notes for the Noctalia bar: a stack of notes on the left, a
big editor on the right. A note is just text — no titles, no extra
fields; the first line of the body automatically becomes its name in the list.
Everything is stored locally: no network access, no model, no external helper
beyond one declared command.

## Plugin

| Field | Value |
| --- | --- |
| ID | `xinghui/scratchpad` |
| Entries | Bar widget: `launcher`; panel: `pad`; shortcut: `open` |

## Requirements

- `xdg-open` — only used by the data-folder button in the editor footer; declared in
  `dependencies` in plugin.toml.

## Usage

Open the pad from the bar button (add "Scratchpad" from the widget picker),
from the control-center tile, or with:

```sh
noctalia msg panel-toggle xinghui/scratchpad:pad
```

- **New note** — the `+` button in the slim toolbar, or `Ctrl+N` while the
  panel has keyboard focus.
- **Edit** — type in the editor; changes auto-save about a second after you
  stop typing. The list name follows the first line as you type.
- **Paste** — ordinary `Ctrl+V`: the editor is a plain text field, so any
  formatting is dropped automatically and only the text lands at the caret.
  Invisible leftovers from web copies (zero-width spaces, BOM, soft hyphens,
  CRLF endings) are stripped silently on every edit; composed emoji are safe.
  Emoji and other Unicode work normally.
- **List rows** — one-line: the note title (first line). Hovering reveals a
  squared-off delete button.
- **Delete** — hover a row, click the delete button (it turns solid red), then
  click it again to confirm. A click within 400 ms of arming counts as a
  double-click and is ignored, so two fast clicks never delete in one motion.
  The request cancels itself after 4 seconds, when you click the row, or when
  you switch notes.
- **Data folder** — the folder icon in the editor footer opens the plugin's
  data directory in your file manager (via `xdg-open`).

## Settings

| Key | Type | Default | Description |
|---|---|---|---|
| `label` | string | `Notes` | Text shown on the bar button. |

## IPC

All events target the panel and require it to be open:

```sh
P="noctalia msg plugin xinghui/scratchpad:pad all"
$P list              # notify with the note list
$P new "first line"  # create a note (payload becomes its body)
$P select 2          # switch to note 2
$P add "more text"   # append text to the current note
$P delete            # delete the current note immediately
$P confirm-delete    # two-step delete: first call arms, second deletes
```

The `delete` event executes immediately (a typed command is explicit intent),
while the UI button and `confirm-delete` use the two-step confirmation.

## Notes

- Data lives in the plugin's private directory:
  `~/.local/state/noctalia/plugins/data/xinghui/scratchpad/`
  - `notes.json` — all notes: `[{ id, text, time, mtime }, …]`
  - `state.json` — `{ lastId }`; the pad reopens on the note edited last
  - `notes.json.bak` — only written if `notes.json` was unreadable, kept as a
    backup before the file is rebuilt
- Upgrades: an old separate `title` field is folded into the body's first
  line; the contents of a legacy `document.txt` become note #1. Notes from the
  removed picture experiment (0.5.x, `{{img:id}}` markers + attachment files)
  are converted back to plain text on first load — markers are stripped and
  their picture files deleted; nothing else changes.
- Privacy: fully offline. No network calls, no model, and the only spawned
  process is `xdg-open` on the data-folder button. Notes never leave the
  machine.
- Single instance: opening one panel position closes the others — two panels
  never run side by side, so their lists can never go stale or overwrite each
  other's saves.
- Typing repaints immediately: the list name, preview, date and footer follow
  every keystroke. Auto-save is an idle debounce: it writes 900 ms after your
  last keystroke, checkpoints at most every 5 s while you type non-stop, and
  retries a failed write with a 3 s back-off.
- Saved state is silent by design (auto-save is assumed); the footer only
  shows "Unsaved" while typing and "Save failed" if a write fails.
- Opening the panel and switching notes use a short (~150–180 ms) fade/slide
  driven by `onFrameTick`; frame callbacks stop as soon as the animation ends.
- The panel's update tick only runs while the panel is open; closing it saves
  pending edits, and edits are also flushed on reload, disable and shutdown.
- The panel is declared `persistent`: closing it only hides the surface
  instead of destroying it, so reopening is instant and the close animation
  never waits on a layer-surface teardown.
