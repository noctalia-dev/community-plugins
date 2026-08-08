# English Dictionary

Look up English words right from the Noctalia launcher. Type `/dic` followed by
a word, pick a suggestion from the autocomplete list, and the definition and
example sentences appear in a dedicated panel.

## Plugin

| Field           | Value                          |
| --------------- | ------------------------------ |
| ID              | `weinguyen/dictionary-english` |
| Launcher Entry  | `dic`                          |
| Launcher Prefix | `/dic`                         |
| Panel           | `panel`                        |

Toggle the definition panel from the command line:

```
noctalia msg panel-toggle weinguyen/dictionary-english:panel
```

## Usage

1. Open the Noctalia launcher.
2. Type `/dic` followed by the word you want to look up (e.g. `/dic abandon`).
3. Matching words appear as you type; use the arrow keys + Enter to select one.
4. The definition panel opens, showing the English definition and the example
   sentences for that word.



## Data

The dictionary data lives in `assets/dictionary/` inside this plugin directory
and is read directly at runtime. To keep every lookup fast, the 28 MB source is
pre-split when the data is generated:

- `assets/dictionary/prefix.json` — the launcher autocomplete index: a map of
  first-two-letters prefix to the sorted words in that bucket.
- `assets/dictionary/chunks/<abc>.json` — the definition data for each prefix:
  one file per first-letter-prefix (1–3 letters, e.g. `abandon` →
  `chunks/aba.json`). The panel decodes only the chunk for the selected word's
  prefix, so it never loads the whole dictionary.

## Notes

- The panel uses `placement = "attached"`; if the position is not to your liking,
  adjust it in `plugin.toml` (e.g. `placement = "floating"`, `position = "center"`).
