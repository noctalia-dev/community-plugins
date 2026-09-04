# Sticky Notes

Create colourful, persistent notes and Markdown checklists from the Noctalia
bar. Pin, reorder, blur, and save them in a folder you control.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ahmedhossamdev/sticky-notes` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `service` |

## Requirements

The plugin uses the standard `mkdir` and `sh` commands to create and resolve
the save folder, and `xdg-open` to open a web link explicitly stored in a note.

## Usage

1. Enable **Sticky Notes** in Settings → Plugins.
2. Add the `bar` widget to a bar section.
3. Click its note icon to open the panel, then use **+** to create a note.
4. Click a note to edit it. **Done** saves it; an empty note is deleted.
5. Use the star to pin a note, and drag its `≡` handle to reorder it.

Open or close the panel directly:

```sh
noctalia msg panel-toggle ahmedhossamdev/sticky-notes:panel
```

### Checklists

Use standard Markdown task-list syntax. Up to three tasks appear as clickable
checkboxes on a note card, with a completion count beside its timestamp.

```md
- [ ] Buy milk
- [x] Send the report
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `default_color` | select | `yellow` | Colour assigned to a new note. |
| `font_size` | int | `13` | Preview and editor text size, from 10 to 20 px. |
| `show_count` | bool | `true` | Shows the number of notes beside the bar icon. |
| `auto_blur` | bool | `false` | Hides note contents whenever the panel opens. |
| `save_shortcut` | bool | `true` | Enables Ctrl+Enter to save and close the editor. |
| `blur_strength` | select | `medium` | Visual weight of the privacy overlay. |
| `save_path` | string | `~/Documents/sticky-notes` | Folder where the notes file is stored. |
| `file_format` | select | `md` | Storage format: Markdown, plain text, or JSON. |

## Notes

- Notes are stored in `notes.md`, `notes.txt`, or `notes.json` in the selected
  save folder. The plugin creates that folder when needed and writes only that
  file.
- The Markdown file includes note metadata in HTML comments; preserve those
  comments if you edit the file outside Noctalia.
- Blur mode hides every preview and disables opening note links until you
  reveal the notes again.
- The plugin has no network calls. It only invokes `xdg-open` for a validated
  `http://`, `https://`, or `www.` link that the user placed in a note.
