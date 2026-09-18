# Sticky Notes

Create persistent notes and Markdown checklists from the Noctalia bar. Use
classic sticky colors or blend them with the current wallpaper palette.

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
6. Use a note's eye button to hide only that note, or the header eye to hide
   every note at once.
7. Use the settings button in the panel header to open the plugin's settings.

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
| `use_wallpaper_colors` | bool | `false` | Blends the seven classic colors with Primary, Secondary, and Tertiary colors generated from the current wallpaper. |
| `no_colors` | bool | `false` | Uses one neutral shell surface color for every note. It overrides wallpaper blending without changing saved note colors. |
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
- Wallpaper-color mode changes only how colors are rendered. It uses
  `noctalia msg wallpaper-get` to locate the active wallpaper when the plugin
  API does not provide it, then runs the local `noctalia theme` command to
  resolve its palette. Turning the setting off restores every note's original
  saved color.
- No colors mode gives every card the same neutral shell color. It takes
  priority over wallpaper-color mode, and turning it off restores the selected
  classic or wallpaper-blended colors.
- Per-note blur hides only the selected previews. The header privacy control
  hides every preview without clearing individual blur choices.
- Hidden notes cannot be edited and do not expose or open their links until
  they are revealed again.
- The plugin has no network calls. It only invokes `xdg-open` for a validated
  `http://`, `https://`, or `www.` link that the user placed in a note.
