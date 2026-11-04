# YouTube Explorer

Search YouTube, browse channels, save videos and play them in mpv from Noctalia.

## Plugin

| Entry | ID |
| --- | --- |
| Plugin | `nullflake/youtube-explorer` |
| Launcher `youtube` | `nullflake/youtube-explorer:youtube` · `/yt` |
| Service `queue-events` | `nullflake/youtube-explorer:queue-events` |

## Usage

Enable YouTube Explorer in Noctalia's plugin manager, then enter `/yt` in the launcher.

- **Search:** `/yt Search linux` finds videos and channels.
- **Play from URL:** `/yt URL https://www.youtube.com/watch?v=VIDEO_ID`.
- Open a video to play it, copy its URL, save it to **Watch later**, or queue it.
- Save **Favorite channels** to browse their latest videos together.

The queue uses one mpv window. Finished, skipped and failed videos leave the queue;
Previous returns to played videos. Closing mpv clears the queue and session history.
**Clear queue** keeps the current video and stops suggestions. **Refresh suggestions**
replaces waiting suggestions, keeps manual entries and resumes Mix while a video is loaded.

Playback resumes from saved positions; completed videos start over. A timestamp
in a pasted link overrides the saved position.

## Requirements

Commands must be available on PATH:

- `yt-dlp` for search, channel browsing and video extraction; keep it updated
  (recommendation fallback tested with 2026.10.21).
- `mpv` 0.38+ with Lua support and its ytdl hook enabled.
- `python3` 3.9+ for search, queue control and cache maintenance; no extra packages.
- `mkdir` from GNU coreutils for playback storage.
- `noctalia`, supplied by the host, for queue updates and error notifications.

Requires Noctalia plugin API 43 or newer (Noctalia 5.4.1 supports it).
The playback profile and mpv scripts are included.

## Settings

| Setting | Default | Effect |
| --- | --- | --- |
| Search language | English | Preferred YouTube result language, independent of the UI language. |
| Max quality | Auto | Resolution limit or Audio only; applies on playback. |
| Continue with YouTube Mix | Off | Prepare suggestions while the last queued video plays. |
| Number of suggestions to queue | 5 | Add 1–10 at once; shown when Mix is enabled. |
| Videos per favorite channel | 3 | Show 1–20 recent videos per channel in the favorites feed. |

Opening a video sets the suggestion source; automatic suggestions advance it.
Manual additions replace waiting suggestions without changing the source.
With 1 suggestion, each suggested video generates the next; larger counts add a batch.
Related videos replace Mix when unavailable. Suggestions are anonymous.
Mix settings apply on playback or refresh. A failed last video stops Mix;
open another video to continue.

## IPC

The `queue-events` service receives `queue-changed`, `autoplay-error` and
`playback-error` events from the helper. It updates the launcher, shows errors
and schedules search and image recovery.

## Notes

Lists are local. History keeps the latest 500 loaded videos. Clearing it also deletes
saved playback positions and channel play counts; an open video will not save its
position again until reopened. Unreadable libraries and queues offer a confirmed
reset with a backup.

Search and recommendations use yt-dlp; playback uses mpv/yt-dlp. A bundled extractor
reads related videos when Mix is unavailable. Images use approved YouTube image
hosts with redirects disabled. No API key or account login is required.
YouTube restrictions or network failures can prevent search and playback.
New queries cancel obsolete searches. Transient search and Mix failures retry once;
transient image failures retry twice while their page is open.

Library, queue, progress, events, backups, search tickets and thumbnails use
Noctalia's plugin data directory, normally
`~/.local/state/noctalia/plugins/data/nullflake/youtube-explorer`.
The image cache targets 128 MiB and removes images unused for 30 days; active images
may exceed the limit. **Clear thumbnail cache** preserves saved lists.
mpv also uses native resume storage. The detached player uses a private directory
under `$XDG_RUNTIME_DIR` (or `/tmp`) for its lock and Unix socket.

## License

Copyright (c) 2026 nullflake. [GPL-3.0-only](LICENSE).
