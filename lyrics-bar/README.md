# Lyrics Bar

Shows the current synced lyric line from [lyrics-term](https://github.com/vitalikr2x3/lyrics-term) in the bar.

## Requirements

- `lyrics-term` running in headless mode, writing the current line to a file:

      lyrics-term --headless --export ~/.cache/lyrics-term/current.txt &

The plugin itself makes no network requests and runs no external commands. It only reads the file above.

## Entries

| Id | Kind | Description |
|----|------|-------------|
| `lyrics` | bar widget | Shows the current lyric line |

## Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `lyricsFile` | string | `~/.cache/lyrics-term/current.txt` | Path to the file written by `lyrics-term --export`. `~` is expanded to the home directory. |

## Usage

1. Enable the plugin in Settings → Plugins.
2. Add the `lyrics` widget to a bar.
3. Start `lyrics-term --headless --export ~/.cache/lyrics-term/current.txt` in the background.

The widget is hidden while the file is empty.

## License

MIT
