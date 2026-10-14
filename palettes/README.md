# Palettes

Palettes is a panel plugin designed to help you work with colors across multiple apps and platforms. Add, Edit and Name your colors per file then copy hex codes with one click, all from the UI.

Create and store your own palettes locally, or reference builtin community palettes.

## Plugin

| Field | Value |
| --- | --- |
| ID | `soul/palettes` |
| Entries | panel: `palettes` |

## Usage

Create a compositor keybind with the following IPC command:

```sh
noctalia msg panel-toggle soul/palettes:palettes
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `columns` | `int` | `3` | Number of columns to display in panel. |

## Notes

- This plugin was made with help from AI. And manually tested with every change.
- If you would like a palette to be included in the plugin open a PR for `builtin.json`
