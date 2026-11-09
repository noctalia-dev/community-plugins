# Synced Lyrics — Installation

This guide installs the plugin from a local checkout into a running Noctalia Shell. It documents the tested local-source layout and commands.

## Requirements

- Noctalia Shell running with its CLI available as `noctalia`.
- Python 3 and `playerctl` available in `PATH`.

Check the dependencies:

```bash
command -v noctalia
python3 --version
playerctl --version
noctalia msg status
```

## First-time installation

Run these commands from the root of the synced-lyrics checkout. The source root must contain a child folder named `synced-lyrics`; **do not register the plugin folder itself as the source root**.

```bash
cd /home/kaler/Documents/AntiGravity/synced-lyrics

SOURCE_ROOT="$HOME/.local/share/noctalia/plugin-sources"
PLUGIN_DIR="$SOURCE_ROOT/synced-lyrics"

mkdir -p "$PLUGIN_DIR/scripts" "$PLUGIN_DIR/translations"
cp plugin.toml bar.luau panel.luau README.md INSTALL.md "$PLUGIN_DIR/"
cp scripts/fetcher.py "$PLUGIN_DIR/scripts/"
cp translations/en.json "$PLUGIN_DIR/translations/"
```

Register the **parent** source directory once:

```bash
noctalia msg plugins source add synced-lyrics-dev path "$SOURCE_ROOT"
```

If `synced-lyrics-dev` is already listed by `noctalia msg plugins source list`, do not add it again. If it points to the wrong directory, remove and re-add that source:

```bash
noctalia msg plugins source remove synced-lyrics-dev
noctalia msg plugins source add synced-lyrics-dev path "$SOURCE_ROOT"
```

Refresh the source and wait for the plugin to appear in Noctalia's inventory before enabling it. The update command reports that work is happening in the background, so check the inventory after it finishes:

```bash
noctalia msg plugins update synced-lyrics-dev
noctalia msg plugins list | grep -F 'kaler/synced-lyrics [synced-lyrics-dev]'
```

The inventory line should show `kaler/synced-lyrics [synced-lyrics-dev]` and its version. If no line appears, verify that `"$PLUGIN_DIR/plugin.toml"` exists and contains `id = "kaler/synced-lyrics"`; the plugin has not been discovered yet, so do not try enabling it until discovery succeeds.

Enable the discovered plugin and reload the Noctalia configuration:

```bash
noctalia msg plugins enable kaler/synced-lyrics
noctalia msg config-reload
noctalia msg plugins list | grep -F 'kaler/synced-lyrics [synced-lyrics-dev]'
noctalia msg config-get plugins.enabled
```

The inventory should say `enabled`, and `plugins.enabled` should include `kaler/synced-lyrics`. The enable command may say that export is happening in the background; check the inventory again after that completes.

## Add the widget to the bar

The plugin must be enabled **and** its widget must be configured in `settings.toml`. The settings file is normally `$HOME/.local/state/noctalia/settings.toml`.

Define the widget:

```toml
[widget.lyrics]
type = "kaler/synced-lyrics:lyrics"
```

Add `"lyrics"` to one of the lanes of the bar you use. Keep the rest of that lane's existing widgets; for example:

```toml
[bar.top-bar]
end = [ "lyrics", "notifications", "volume" ]
```

Reload the config after editing the settings:

```bash
noctalia msg config-reload
noctalia msg config-get widget.lyrics
```

Verify that `widget.lyrics` reports `type = 'kaler/synced-lyrics:lyrics'` and that the configured bar lane contains `"lyrics"`. The widget auto-hides when there is no active playback by default.

## Updating the local plugin

After changing files in the checkout, copy the runtime files into the registered source folder and update that source. Do not add the source again.

```bash
cd /home/kaler/Documents/AntiGravity/synced-lyrics
SOURCE_ROOT="$HOME/.local/share/noctalia/plugin-sources"
PLUGIN_DIR="$SOURCE_ROOT/synced-lyrics"

mkdir -p "$PLUGIN_DIR/scripts" "$PLUGIN_DIR/translations"
cp plugin.toml bar.luau panel.luau README.md INSTALL.md "$PLUGIN_DIR/"
cp scripts/fetcher.py "$PLUGIN_DIR/scripts/"
cp translations/en.json "$PLUGIN_DIR/translations/"

noctalia msg plugins update synced-lyrics-dev
noctalia msg plugins list | grep -F 'kaler/synced-lyrics [synced-lyrics-dev]'
noctalia msg config-reload
```

The plugin manager discovers local plugins from configured sources. Copying files only into `~/.local/state/noctalia/plugins/materialized/...` does **not** register a plugin source. Noctalia manages that materialized directory; install and update the plugin through the registered source instead.

## Playback and lyrics checks

Confirm that Noctalia sees a player and its track metadata:

```bash
playerctl status
playerctl metadata --format '{{xesam:title}} — {{xesam:artist}}'
```

With playback active, the title and artist should be non-empty. The widget is hidden when media is stopped or paused if the corresponding `auto_hide` / `hide_when_paused` settings are enabled.

To test lyric lookup independently of the bar, run the deployed fetcher with the same track metadata. This checks provider lookup but does not verify that the widget is placed in a bar lane:

```bash
PLUGIN_DIR="$HOME/.local/share/noctalia/plugin-sources/synced-lyrics"
python3 "$PLUGIN_DIR/scripts/fetcher.py" \
  "Song title" "Artist name" "Album name" auto "" "" "" "" "" \
  "$PLUGIN_DIR/cache" "https://noctalialyrics.vercel.app" 1 "" 0 ""
```

The JSON result should have `status` set to `ok` and a non-empty `lines` array if a provider has lyrics for that track.

## Troubleshooting

- **“Plugin not enabled” / “no plugin found in any source”**: Check `noctalia msg plugins source list`. The registered source must point to the parent folder containing `synced-lyrics/plugin.toml`. Run `noctalia msg plugins update synced-lyrics-dev`, then verify the exact plugin ID appears in `noctalia msg plugins list` before enabling it.
- **Plugin is enabled but the bar widget is absent**: Verify `noctalia msg config-get widget.lyrics`, confirm the configured bar lane contains `"lyrics"`, and run `noctalia msg config-reload`.
- **Widget is present but hidden**: Check `playerctl status` and the `auto_hide` / `hide_when_paused` plugin settings.
- **No lyrics are found**: Confirm `playerctl metadata` returns a title and artist. Try another provider through `preferred_source`, or run the fetcher check above and inspect its `sources` and `checked_sources` fields.
- **Dependency warning in the plugin list**: Install Python 3 and `playerctl`, then update the local source and reload the config.

## Configuration reference

Plugin settings can be managed in Noctalia's Settings UI or in `settings.toml`:

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `preferred_source` | select | `auto` | Provider choice; auto mode prioritizes metadata-based sources when sync quality is equal. |
| `auto_hide` | bool | `true` | Hide the widget when playback stops. |
| `hide_when_paused` | bool | `true` | Hide the widget while playback is paused. |
| `spicy_lyrics_api_key` | string | empty | Optional Spicy Lyrics API key. |
| `musixmatch_user_token` | string | empty | Optional Musixmatch token; a public token is attempted when empty. |
| `betterlyrics_api_key` | string | empty | Optional BetterLyrics API key for uncached requests. |
| `spotify_client_id` | string | empty | Optional Spotify app client ID for track-ID resolution. |
| `spotify_client_secret` | string | empty | Optional Spotify app client secret. |
| `timing_offset_ms` | int | `0` | Manual lyric timing adjustment, also adjustable with the bar's scroll control. |

Other display and karaoke settings are declared in `plugin.toml`.
