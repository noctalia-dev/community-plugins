# Changelog

## [0.2.6] - 2026-09-12

### Fixed
- **CPU budget watchdog**: Decoupled state watch callback handling in `service.luau` using asynchronous dispatch, preventing Noctalia's watchdog from killing the service with `state watch callback exceeded its CPU budget`.
- **UTF-8 string corruption**: Replaced byte-class patterns (`[^•]`) with byte-safe plain string search in delimiter parsing (`helpers.luau`), resolving invalid UTF-8 byte crashes (`0x96`) on Asian characters, Japanese typography, and unicode delimiters.
- **Playlist track count fallback**: Added fallback calculation for albums and playlists lacking explicit total track count to prevent the UI from remaining stuck on `Loading tracks... 0 total`.
- **Atomic offline library audit**: Prevented playlists from temporarily vanishing or showing 0 tracks during startup/rescan by making downloaded playlist state transitions atomic.
- **Login state detection race**: Added fallback disk verification for `cookies.txt` in UI state initialization, preventing temporary unauthenticated banner flashes during startup.
- **Download metadata disk writes**: Batched offline metadata saves during bulk playlist queueing instead of writing disk state per item.
- **Scratch file collisions**: Increased scratch file rotation pool from 8 to 128 slots to prevent concurrent request data overwrites.

### Added
- **Manual library refresh**: Added refresh buttons to both the sidebar header and the Library view to trigger instantaneous resync of user playlists and library state.
- **Stream resolution resilience**: Updated yt-dlp resolver to request `bestaudio/best` with opus extraction and multiple player client fallbacks (`android,mweb`), bypassing YouTube throttling and stream 403 errors.
- **In-memory thumbnail caching**: Avoids redundant disk stat calls for already resolved thumbnail paths.

## [0.2.5] - 2026-09-04

### Fixed
- **Rapid skipping**: songs skipped over are no longer fetched or played
- **Playback after skipping**: fixed a race where the new player instance could lose its control socket, leaving duration at 0:00 and transport controls dead.
- **Netcat flavors**: mpv control now works with both OpenBSD netcat and ncat (Fedora/RHEL default).

### Added
- **Dependency healthcheck**: the login page shows a card checking yt-dlp, mpv, jq, netcat and curl : versions, staleness, and unix-socket support, with a refresh button.
- **Boot diagnostics**: debug.log now records platform, plugin/host versions, auth state, and detected browsers on every start.

## [0.2.4] - 2026-09-03

### Added
- **Albums & Artists search**: search tabs now include dedicated filters for Albums and Artists.
- **Player bar download button**: save the currently playing track for offline listening with one click next to the stats button.

### Fixed
- **Chromium browser login**: seamless sign-in support for Chrome, Brave, Edge, and Vivaldi — automatically extracts cookies even when the browser is running.
- Fixed row alignment and button flicker when track thumbnails load in.
- Fixed crashes caused by special characters in YouTube song titles.
- Filtered Recommended Mixes on the home feed to show official YouTube Music radios.
- Clearing thumbnail cache now properly re-downloads missing covers across all pages.

## [0.2.3] - 2026-09-02
- Sync with community release

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
