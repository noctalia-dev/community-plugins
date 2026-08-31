# Changelog

## [0.2.2] - 2026-08-22

### Added
- **Offline mode**: a new Offline view in the sidebar gathers your downloaded playlists and saved songs in one place. When your connection drops, the app keeps working with what's on disk — playback automatically skips tracks that aren't downloaded, and rows show you what's available offline. Your downloads stay listed even after restarting or clearing caches.
- **Artist pages**: search results can now include artists — open one to browse their songs and albums in a dedicated view.
- **More playlist results**: searching playlists now fills all 25 result slots instead of stopping at 5.

### Fixed
- The Songs tab shows real song matches again instead of an unrelated mix of content.
- The Playlists tab shows featured playlists from Youtube Music
- Per-song play stats now reset when the track changes instead of sticking to the previous song.

## [0.2.1] - 2026-08-21

### Added
- **Playlist suggestions**: YT Music's suggestion shelf now renders below a playlist's pagination controls; clicking one plays it immediately while the rest of the queue continues.
- **Playing-context highlight**: "Play all" and recently-played playlists now light up in the sidebar while their queue is playing, matching single-track row behavior.
- **Offline hygiene**: Removing cookies.txt clears Recently Played and the saved session from both memory and disk; sidebar hides Recently Played while not logged in.

### Fixed
- Playlists no longer paginate past their declared track count — YouTube's suggestion rows no longer count as playlist members or added to the disk cache
- Rapidly opening two playlists no longer lets a slow response for A render under B's title (stale-response guards + per-request scratch files end cross-request corruption).
- Stream URLs cached on disk expire after 4h instead of being served forever.
- Like/unlike reports real success/failure (curl exit status) instead of always claiming OK.
- Shuffle: toggling it physically shuffles the upcoming queue in place (visible in Queue view) and un-shuffling restores the original order; rapid next presses can no longer repeat tracks.
- Mini/full panel opened together can no longer silently swallow each other's commands (request nonce collisions eliminated via millisecond-clock seeds).
- Cached thumbnail fetches are shell-safe against hostile URLs; cache-clear targets are allowlisted.
- Debug log is capped (~512KB, trims to newest 128KB) instead of growing unbounded.

### Changed
- Removed dead code paths (orphaned `daemon.sh`, uncalled API helpers, inert widget state watch).
- Home page defers building the Your Library grid until needed and shows 15 Quick Picks / 6 mixes, noticeably reducing full-panel open lag.

## [0.2.0]

Initial public release: YouTube Music browsing (home feed, search with Top/Songs/Playlists tabs), playlists and queue management, miniplayer + full shell view, offline downloads with per-cache management, session restore, cookie-based sign-in across nine browsers.
