# Case Convert

Convert text between naming conventions — camelCase, kebab-case, snake_case,
CONSTANT_CASE and 14 more — without leaving the launcher. Useful when you have a
label in one shape and need it in another: a heading that has to become a file
name, a database column that has to become a JSON key.

## Plugin

| Field | Value |
| --- | --- |
| ID | `kjvdven/case-convert` |
| Entries | Launcher provider: `case` |
| Launcher Prefix | `/case` |

## Requirements

`wl-paste` (from wl-clipboard) on `PATH`, and only for reading the primary
selection. Without it the plugin still works and falls back to the clipboard.

## Usage

Type `/case` in the launcher, then the text to convert:

```
/case parse http response
```

Every conversion of that text is listed, one per row, with the conversion name
as the subtitle. Enter copies the highlighted row to the clipboard. The
launcher's category filter narrows the list to **Programming**, **Text** or
**Fun**.

Leave the query empty and the input comes from your primary selection instead,
falling back to the clipboard — select text in any window, open the launcher,
type `/case`, press Enter.

Start the query with `>` to filter the conversions by name while still using the
selection as input, so `/case >kebab` shows only the kebab conversions.

Input `this is an example` produces:

| Category | Conversion | Result |
| --- | --- | --- |
| Programming | `camelCase` | `thisIsAnExample` |
| Programming | `PascalCase` | `ThisIsAnExample` |
| Programming | `kebab-case` | `this-is-an-example` |
| Programming | `snake_case` | `this_is_an_example` |
| Programming | `CONSTANT_CASE` | `THIS_IS_AN_EXAMPLE` |
| Programming | `dot.case` | `this.is.an.example` |
| Programming | `path/case` | `this/is/an/example` |
| Programming | `Pascal_Snake_Case` | `This_Is_An_Example` |
| Programming | `KEBAB-UPPER-CASE` | `THIS-IS-AN-EXAMPLE` |
| Programming | `Header-Case` | `This-Is-An-Example` |
| Text | `Title Case` | `This Is an Example` |
| Text | `Capital Case` | `This Is An Example` |
| Text | `Sentence case` | `This is an example` |
| Text | `no case` | `this is an example` |
| Text | `lower case` | `this is an example` |
| Text | `UPPER CASE` | `THIS IS AN EXAMPLE` |
| Fun | `sWAP cASE` | `THIS IS AN EXAMPLE` |
| Fun | `AlTeRnAtInG cAsE` | `ThIs Is An ExAmPlE` |

Title Case lowercases small words (`a`, `of`, `the`, …) unless they are first or
last; Capital Case capitalizes every word. The word-based conversions rebuild
the text from its words, so punctuation between words disappears — `lower case`,
`UPPER CASE`, `sWAP cASE` and `AlTeRnAtInG cAsE` work character by character and
keep it.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `input_source` | `select` | `auto` | Where text comes from when the query is empty. `auto` tries the primary selection and falls back to the clipboard; `selection` and `clipboard` use only that one. |
| `preserve_casing` | `bool` | `true` | Keep the casing inside each word, so `NASA rocks` becomes `NASA_Rocks` rather than `Nasa_Rocks`. Conventions that are lowercase by definition (`kebab-case`, `snake_case`, …) ignore this. |
| `notify_on_copy` | `bool` | `true` | Show a notification naming the conversion after copying. |

## Notes

- **Processes.** With an empty query the plugin runs `wl-paste --primary
  --no-newline` once per query to read the selection. Nothing else is spawned,
  no files are written, and there is no network access.
- **Clipboard.** Activating a row writes it to the clipboard as `text/plain`.
  Plugin launcher providers cannot auto-paste, so copying is as far as it goes.
- **Unicode.** Casing covers ASCII and the Latin-1 Supplement block, so `café` →
  `CAFÉ`. Letters beyond it (`Ł`, `Ż`, `Ș`, Greek, Cyrillic) pass through uncased
  rather than corrupted, and `ß` stays `ß`, having no single-character uppercase.
- **Compositor.** Reading the selection is Wayland-only through `wl-paste`;
  everything else is compositor-independent.
- **Compact launcher.** Each row names its conversion in the subtitle, and a
  compact launcher (`shell.launcher.compact = true`) hides subtitles. Turn
  compact off to tell `Hello_World` from `Hello-World` at a glance.

Source and conversion tests:
<https://github.com/kjvdven/noctalia-case-convert>
