# Bangumi Progress

Track anime from [bgm.tv](https://bgm.tv) on the Noctalia desktop. See newly aired episodes, browse every collection status, and update watched progress without leaving the panel.

## Plugin

| Field | Value |
| --- | --- |
| ID | `mirei124/bangumi-progress` |
| Entries | Desktop widget: `tracker`; bar widget: `bar`; panel: `library`; service: `api` |

## Requirements

- Network access to `api.bgm.tv` and `lain.bgm.tv`.
- A [Bangumi personal access token](https://next.bgm.tv/demo/access-token) is required to update progress or read private entries. A username alone is sufficient for read-only access to public collections.
- `xdg-open` on `PATH` is required only for opening subject and profile pages in the default browser.

## Usage

1. Enable **Bangumi Progress** in Settings → Plugins.
2. Open the plugin settings and enter either a personal access token or a Bangumi username.
3. Add the `tracker` desktop widget and/or the `bar` bar widget to your layout.

The `tracker` desktop widget lists currently watching anime with cover art, watched progress, aired progress, and total episodes. Titles with newly available unwatched episodes are pinned first. Use its paging controls when the list exceeds the configured number of visible entries, and use an entry's open button to visit its Bangumi page.

The `bar` widget displays the number of episodes that became available and remain unwatched since the last progress action. The first calculation establishes a baseline and displays `0`:

- Left-click the widget to open the `library` panel.
- Right-click it to open your Bangumi profile.
- Hover over it to see the number of currently watching titles.

The `library` panel browses Watching, Wish, Completed, On Hold, and Dropped collections. Newly available unwatched titles are pinned first and marked with a red dot in the Watching list. Use `+` or `-` to change episode progress, the completion button to mark all main-story episodes as watched, and the open button to visit the subject page.

Toggle the panel directly with:

```sh
noctalia msg panel-toggle mirei124/bangumi-progress:library
```

The `api` service runs in the background. It refreshes collections, resolves aired episode counts, downloads covers, persists cache data, and processes progress changes requested by the panel.

## Settings

Plugin settings:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `access_token` | `string` | empty | Personal access token used to read your own collection, including private entries, and update progress. Takes precedence over `username`. |
| `username` | `string` | empty | Bangumi username used to read public collections anonymously when no token is set. |
| `refresh_minutes` | `int` | `30` | Automatic refresh interval and cache lifetime in minutes, from `5` to `1440`. Manual refreshes are not throttled. |

Desktop widget settings, configured per `tracker` instance:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_covers` | `bool` | `true` | Show cover art beside each title. |
| `widget_width` | `int` | `320` | Natural content width in logical pixels, from `220` to `800`. |
| `visible_items` | `int` | `6` | Number of entries displayed per page, from `1` to `20`; this also determines the widget's natural height. |

Bar widget settings, configured per `bar` instance:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `glyph` | `glyph` | `device-tv` | Icon displayed by the bar widget. |

Keep the desktop widget box at its automatic size. Explicitly resizing it in the desktop editor may cause the host to scale its contents; use `widget_width` and `visible_items` instead.

## IPC

Force the `api` service to refresh the Watching collection and every other collection category already loaded in the panel:

```sh
noctalia msg plugin mirei124/bangumi-progress:api all refresh
```

Clear the service's in-memory viewer, collection, episode-progress, and badge state:

```sh
noctalia msg plugin mirei124/bangumi-progress:api all logout
```

The `logout` event does not erase plugin settings or the on-disk cache. Disable the plugin or change its settings if credentials should no longer be used.

## Notes

- The service sends the configured access token to `api.bgm.tv` as a Bearer token. A normal bgm.tv website login cookie cannot authenticate the v0 API.
- It calls `/v0/me`, collection, and episode endpoints on `api.bgm.tv`, and downloads cover images from URLs returned by the API, normally on `lain.bgm.tv`.
- Cache data is written under Noctalia's plugin data directory, normally `~/.local/state/noctalia/plugins/data/mirei124/bangumi-progress/`, as `cache.json`, `badge-baselines.json`, and files under `covers/`.
- Collection, identity, and episode caches use `refresh_minutes`. Episode lookups are limited to two titles concurrently. Repeated panel opens are throttled, while the panel's refresh button and the `refresh` IPC event force a collection refresh.
- The service invokes `xdg-open` to open `https://bgm.tv/subject/<id>` and `https://bgm.tv/user/<username>` in the default browser.
- Anime progress is changed episode by episode through `PATCH /v0/users/-/collections/{subject_id}/episodes`. Collection-level `ep_status` updates apply only to books, and the legacy collection update endpoint can reset an anime to Wish.
- With a personal access token, collection reads use the explicit username returned by `/v0/me`; the `-` self-reference has been observed to return 404 for reads but works for writes.

## License

MIT
