# Quran Widget

A Noctalia widget to show a random Quranic Ayah/verse on the desktop. A new Ayah is shown everyy few minutes.

Inspired by browser extensions like Quran Tab ([Chrome](https://chromewebstore.google.com/detail/quran-tab/afaihcdgkjebgabomemccdneglknjkdd), [Firefox](https://addons.mozilla.org/en-US/firefox/addon/quran-tab-original/)) and Muslim Board ([Chrome](https://chromewebstore.google.com/detail/muslim-board/lmnhjilamobdmdihfkofgiejgokabfad), [Firefox](https://addons.mozilla.org/en-US/firefox/addon/muslimboard/))

## Plugin

| Field | Value |
| --- | --- |
| ID | `mezoahmedii/quranwidget` |
| Entries | Desktop widget: `quranwidget` |

## Requirements
- `xdg-open`: For viewing Ayahs in browser

## Usage

Add the desktop widget to your desktop

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_interval` | `int` | `30` | Time before another Ayah is shown |
| `show_translation` | `bool` | `true` | Shows the translation or the tafsir of the Ayah below it |
| `translation_edition` | `select` | `en.sahih` | The language and edition of the translation |

## Notes

- Uses the [Al Quran Cloud API](https://alquran.cloud/) to fetch Ayahs
- Uses the `Kitab-Regular.ttf` font, which is licensed under the SIL Open Font License Version 1.1 (see `OFL.txt`)
