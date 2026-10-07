# Noctes

Sticky notes on your desktop rather than in a window. Each note is its own
desktop widget - a sheet of paper at a small random angle, a strip of tape on
top, in a colour drawn from your Noctalia palette - sitting above the wallpaper
and below every window. Writing happens in a small panel that opens when you
click a sheet.

Noctes is developed at [RamonRemo/noctes](https://github.com/RamonRemo/noctes).
Suggestions and bug reports are welcome in its
[issues](https://github.com/RamonRemo/noctes/issues).

## Plugin

| Field | Value |
| --- | --- |
| ID | `remo/noctes` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `service`; desktop widget: `note` |

## Requirements

`python3` on `PATH`. It runs `tools/noctes-widget`, the helper that adds,
removes and tilts sheets, because a widget's rotation, its background panel and
the widget entry itself are host state in `settings.toml` that no plugin call
can write. See **Notes**.

## Usage

### The first sheet

```sh
noctalia msg plugin remo/noctes:service all desk
```

That puts a sheet on the focused output, tilted, coloured and bound to a note of
its own. `tools/noctes-widget` is what writes it into `settings.toml`, since no
plugin call creates a desktop widget.

Noctalia's editor does it too, for anyone who would rather click: **Settings ->
Desktop -> Widgets -> Toggle Editor**, add a **Noctes** widget, then **Done**. A
widget added that way appears square, grey and framed. A moment later the service
notices a sheet with no note behind it and adopts it: a key of its own, a small
angle, no frame.

### Everything after that

**Click a sheet.** The panel opens on that note, and it is the only view: title,
body, colour chips, and a toolbar with

- **+** - a new sticker, note and sheet together
- **arrows** - hands the desk back to Noctalia's widget editor, for dragging,
  resizing and rotating
- **gear** - this plugin's settings
- **bin** - deletes the note and takes its sheet off the desktop

Deleting a sheet in Noctalia's widget editor deletes its note too, the next time
the service reads `settings.toml`. A sheet this machine never had, and every
known sheet vanishing at once (a reset settings file), are never taken for a
deletion.

The bar widget shows the note count and opens the panel. To open the panel from
a keybind:

```sh
noctalia msg panel-toggle remo/noctes:panel
```

Typing lives in the panel because desktop widgets are background layer-shell
surfaces and never take keyboard focus.

### Colours

A note with no colour of its own is **dynamic**: it derives one from its key, so
neighbouring sheets rarely match and each keeps its look across restarts. With
*Paper follows the theme* on, that draws from `primary`, `secondary`, `tertiary`
and `error`, each with its own `on_*` text role - so on a generated scheme the
whole wall recolours with your wallpaper. Off, it draws from eight classic
papers.

Picking a chip fixes a note's colour. Besides the eight papers there is
**glass**, a translucent pane with a hairline edge, and **black**, the one sheet
written in white ink. A caption under the chips always names the mode.

## Settings

Plugin-wide:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `default_color` | `select` | `auto` | Colour new notes get. `auto` leaves it to the sheet's key. |
| `theme_colors` | `bool` | `true` | Dynamic notes draw from the palette instead of the classic papers. |
| `tilt` | `bool` | `true` | Sheets sit at a small random angle. Off squares every one of them; on gives each a new angle. Rewrites `settings.toml`. |
| `paper_opacity` | `double` | `0.96` | How solid a sheet is. Text stays fully opaque. |
| `save_path` | `string` | *(empty)* | Folder for `notes.json`. Empty uses the plugin's data directory. |

Per sheet, in the widget's own settings:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `key` | `string` | *(empty)* | Which note this sheet shows. Generated, and hidden from the widget editor. |
| `paper_width` | `int` | `220` | Paper width in px. |
| `paper_height` | `int` | `200` | Paper height in px. |
| `font_size` | `int` | `16` | Body size in pt; the title is three larger. A handwriting font needs more than a UI font. |
| `font_path` | `string` | `PatrickHand-Regular.ttf` | Font the note is drawn in. Plugin-relative, absolute or `~`; empty uses the shell font. |

A sheet holds only what belongs to the paper. The colour belongs to the note and
is picked in the panel; opacity and theme following are plugin-wide. Text longer
than the paper is cut to the lines that fit and ends in "...".

## IPC

```sh
noctalia msg plugin remo/noctes:service all desk            # note and sheet together
noctalia msg plugin remo/noctes:service all new "buy milk"  # note and sheet, with that text
noctalia msg plugin remo/noctes:service all open work       # select the note keyed "work",
                                                            # creating it if absent
noctalia msg plugin remo/noctes:service all move            # toggle the widget editor
noctalia msg plugin remo/noctes:service all stick work      # give the note keyed "work" a sheet
noctalia msg plugin remo/noctes:service all gather          # bring sheets off a disconnected output
noctalia msg plugin remo/noctes:service all reload          # re-read notes.json
```

`stick` is for a note that has a key but no sheet on this machine, such as one
from a synced `notes.json`. `gather` also runs by itself whenever an output
comes or goes; see **Notes**.

`desk`, `new` and `open` all select what they touch, so pairing one with
`noctalia msg panel-toggle remo/noctes:panel` gives a single-keybind quick note.

## Notes

**Files written.** `notes.json` in `save_path`, or in the plugin's data
directory when that is empty, written through `notes.json.tmp` and a rename so a
crash cannot leave half a file. Writes are debounced onto a two second tick. A
`notes.json` that does not parse is renamed to `notes.json.unreadable-<time>`
and reported, never written over. The plugin's data directory also holds
`tilt.state`, `sheets.json` (the sheets this machine has seen) and `homes.json`
(where `gather` moved sheets from).

**Noctalia's `settings.toml`.** A desktop widget's `rotation`, its background
panel and the widget entry itself are host state, and no plugin call reaches
them - so a plugin that creates its own sheets, tilts them or takes them down
has to edit that file. `tools/noctes-widget` does. Each change is written beside
it as `settings.toml.noctes-new`, checked with `noctalia config validate`, and
renamed into place only if it passes, so the shell never loads a file it would
reject. Commands hold a lock on the settings directory, so two at once cannot
undo each other. It touches only `desktop_widgets` entries whose `type` is
`remo/noctes:note`, and the plugin's own `plugin_settings` block is read, never
written.

Once per start the helper also cleans up after older versions: it removes
settings on noctes' own sheets that `noctalia config validate` reports as
unknown, and deletes the `settings.toml.bak-noctes` and
`settings.toml.bak-noctes-<date>` backups that 0.19 and earlier left beside the
file. Nothing else beside `settings.toml` is touched.

**Monitors.** A sheet on an output that is no longer connected is drawn nowhere,
so it is moved to a connected one, and goes back when its own output returns.

**Process spawned.** `python3 tools/noctes-widget`, for the above (it runs
`noctalia config validate` itself), and `noctalia msg desktop-widgets-toggle-edit`
for the toolbar's move button. Nothing else.

**No network access.** Nothing is fetched or sent.

**Font.** `PatrickHand-Regular.ttf` ships with the plugin and is the default.
Patrick Hand by Patrick Wagesreiter, SIL Open Font License 1.1, in
`PatrickHand-OFL.txt`.

**Debugging.** Noctalia logs to stdout, which most ways of starting it discard.
`pkill -x noctalia; nohup noctalia >/tmp/noctalia.log 2>&1 &` makes plugin
errors visible.
