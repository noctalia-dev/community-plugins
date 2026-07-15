# To Do

A [noctalia](https://github.com/noctalia-dev/noctalia) v5 bar plugin: a
prioritised to-do list. Click the bar glyph to toggle a panel of task rows —
add tasks with **+**, tick them off (the text is struck through), delete them,
and set each task's priority. The list is kept sorted by priority and stored as
a single JSON file; no external commands are run.

| Action                       | Effect                                              |
|-------------------------------|-----------------------------------------------------|
| Left click (bar glyph)        | Open/close the To Do panel                          |
| **+** (panel header)          | Add a new task and start typing it                  |
| Sort toggle (panel header)    | Switch ordering between **Priority** and **Manual** |
| Colour chip (row)             | Cycle the task's priority: important → medium → low |
| ☰ grip (row, manual only)     | Pick the row up / drop the held row here (reorder)  |
| Click the text, or ✎ (pencil) | Edit the task's text                                |
| **Enter**, or ✓ (row)         | Commit the edit — the row goes back to a static line |
| ☐ / ☑ button (row)            | Toggle done/to-do (done tasks are struck through)   |
| 🗑 button (row)                | Delete the task                                     |

## Priorities

Each task carries a priority, shown at the start of the row as a small coloured
square. Click the square to cycle it. A legend at the foot of the panel maps
each colour to its category:

| Priority  | Colour |
|-----------|--------|
| Important | red    |
| Medium    | amber  |
| Low       | green  |

## Ordering

The panel header carries a toggle that switches between two ordering modes; the
choice is remembered.

- **Priority** (default) — rows are sorted by priority: important first, then
  medium, then low. Changing a task's priority moves it into its new group but
  keeps its position relative to its peers; equal-priority rows are never
  reshuffled. No grips are shown.
- **Manual** — rows keep the order you give them. Each row grows a ☰ grip on the
  left; here changing a priority only recolours the chip and never moves the row.

Priority mode is only a view: the stored order is always the manual one, so
switching between the two modes (as often as you like) never loses your custom
ordering.

### Reordering in manual mode

The noctalia plugin UI exposes no drag callbacks (only clicks), so the ☰ grip
reorders with two clicks instead of a drag:

1. Click a row's ☰ grip — it lights up; that row is now "held".
2. Click another row's ☰ grip — the held row drops in just above it.
3. Click the held row's own grip again to cancel.

## Editing

Rows are static lines by default. Click a task's text (or its ✎ pencil button)
to edit it; press **Enter** or the ✓ button to commit back to a static line. A
new task (**+**) opens straight into edit mode — committing it while still empty
simply discards it. Edits are also autosaved after a short idle pause and on
close.

Tick a task (☐ → ☑) to complete it — its text is struck through until you
un-tick it. The bar glyph's tooltip shows how many tasks are still to do.

## Storage

Tasks live in one file, `todo.json`, inside the configured **To Do folder**
(default `~/Documents/Todo`). It is a small JSON object,
`{ "version": 2, "sort": "priority" | "manual", "tasks": [ … ] }`, where `tasks`
is the array of `{ id, text, priority, done }` objects (in manual order) — easy
to read, hand-edit, sync, or back up. An older plain-array file is still read
automatically. The plugin runs no external programs.

## Settings

| Setting      | What it does                                             |
|--------------|----------------------------------------------------------|
| To Do folder | Where `todo.json` is stored (default `~/Documents/Todo`).|
| Bar glyph    | The glyph shown for the widget on the bar.               |

## Install

Install **To Do** from Noctalia's plugin store (*Settings → Plugins*), then add
the widget to a bar from *Settings → Bar*. Plugin options live in
*Settings → Plugins*.

For local development, add your working copy as a path source instead
(`.luau` edits hot-reload):

```sh
noctalia msg plugins source add dev path /path/to/plugins
noctalia msg plugins enable nightwatch75/todo
```

## Requirements

- noctalia ≥ 5.0.0
- No external dependencies

## License

MIT.
