# Spotify Search

Search Spotify tracks from the Noctalia launcher, view cached album artwork, and start a selected track on an available Spotify playback device.

## Plugin

| Field | Value |
| --- | --- |
| ID | `notfinaldev/spotify` |
| Entries | Launcher provider: `tracks` |
| Launcher Prefix | `/sp` |

## Requirements

Install these commands on `PATH`:

- `python3` — runs the bundled Spotify Web API helper.
- `spotify_player` — authenticates Spotify before the plugin can use its token cache. Run `spotify_player authenticate` once.
- `notify-send` — reports playback failures.
- `pgrep` — detects whether the Spotify desktop client is running.
- `gtk-launch` — starts `com.spotify.Client` when no playback device is available.

An authenticated Spotify account and an active Spotify playback device are required. Spotify's playback API normally requires Spotify Premium.

## Usage

1. Run `spotify_player authenticate` once to authenticate Spotify.
2. Open the Noctalia launcher and type `/sp ` followed by a track, artist, or album, for example `/sp daft punk`.
3. Select a track to start playback. The plugin uses the active device first, then a computer device, then another available device. If no device exists, it starts the Spotify desktop client and waits up to 30 seconds for a device.

The provider waits 350 ms before search requests. It shows a hint for an empty query, displays a loading row while searching, and reports unavailable authentication, search, and playback failures in the launcher or a desktop notification.

## Notes

### Authentication and privacy

- The plugin reads the Spotify token created by `spotify_player` at `~/.cache/spotify-player/user_client_token.json`. That file is not stored in this repository.
- When the access token is near expiry, the helper posts the refresh token to Spotify's token endpoint and atomically updates that local token file with mode `0600`. No token is printed, included in launcher results, or sent anywhere except Spotify's HTTPS endpoints.
- Search terms, playback-device queries, and playback requests are sent to Spotify's Web API over HTTPS. Album artwork URLs returned by Spotify are fetched over HTTPS.

### Cache and processes

- Search returns at most 12 tracks from distinct albums. Uncached album artwork is stored in `${XDG_CACHE_HOME:-~/.cache}/noctalia-spotify/covers/` as a hashed WebP filename. Individual downloads are limited to 2 MiB; entries older than 30 days are removed and the cache is capped at 100 MiB.
- The launcher asynchronously runs `python3 spotify_backend.py search <query>` and `python3 spotify_backend.py play <track-id>`. The helper may run `notify-send`, `pgrep -x spotify`, and `gtk-launch com.spotify.Client` as described above.
- The Spotify client id compiled into the helper identifies the application to Spotify; it is not an account credential. The required access and refresh tokens remain only in the local token cache.
