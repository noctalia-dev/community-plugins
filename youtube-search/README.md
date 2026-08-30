# YouTube Search

Search YouTube directly from the Noctalia launcher and open a selected video in
your default browser or other `xdg-open` handler.

## Plugin

| Field | Value |
| --- | --- |
| ID | `notfinaldev/youtube-search` |
| Entries | Launcher provider: `youtube` |
| Launcher Prefix | `/yt` |

## Requirements

Install both dependencies on `PATH`:

- `yt-dlp` searches YouTube and returns the video metadata.
- `xdg-open` opens the selected YouTube video with the system's registered URL
  handler.

## Usage

1. Open the Noctalia launcher.
2. Type `/yt ` followed by a search query, for example `/yt ambient coding`.
3. Choose one of the returned videos to open
   `https://www.youtube.com/watch?v=<video-id>&autoplay=1` through `xdg-open`.

The provider returns at most five results. Each result shows its title and,
when available, the channel and formatted duration. Empty queries clear the
result list. A missing `yt-dlp`, search failure, malformed search response, or
no matches is shown in the launcher as a status row.

## Notes

### Network and filesystem effects

- Every non-empty query starts `yt-dlp` with a YouTube search for up to five
  videos. This sends the query to YouTube and lets `yt-dlp` make the network
  requests needed to retrieve search metadata.
- For each displayed video whose thumbnail is not already cached, the plugin
  downloads `https://i.ytimg.com/vi/<video-id>/hqdefault.jpg`.
- Thumbnails are stored below the plugin directory at
  `cache/youtube/<video-id>.jpg`. The plugin creates `cache/youtube` when it
  first needs to cache a thumbnail. Cached thumbnails are reused by later
  searches and are not automatically removed.

### Processes and playback

- Searches run the equivalent of
  `yt-dlp --ignore-config --no-warnings --flat-playlist --dump-single-json
  'ytsearch5:<query>'` asynchronously with a 15-second timeout. The query is
  shell-quoted before it is passed to the command.
- Activating a video runs `xdg-open` asynchronously for that video's YouTube
  watch URL with `autoplay=1`; its standard output and standard error are
  discarded. `xdg-open` delegates playback to the system's configured handler,
  normally a browser. Whether playback actually starts automatically depends
  on that handler and its autoplay policy.
