# AniList

Browse and update your AniList anime and manga lists from the Noctalia bar. Open the panel to see what you are watching, planning, or have finished, then increment or decrement episode/chapter progress without opening the website.

## Plugin

| Field | Value |
| --- | --- |
| ID | `cleboost/anilist` |
| Entries | Bar widget: `tracker`; panel: `library`; service: `api` |

## Requirements

1. Create an AniList API application at [anilist.co/settings/developer](https://anilist.co/settings/developer).
2. Set the application **Redirect URL** to `http://127.0.0.1:7823/callback`.
3. Copy the **Client ID** and **Client secret** into the plugin settings.
4. `python3` must be available on `PATH` (used for the temporary localhost login helper).
5. `xdg-open` must be available on `PATH` (used to open AniList media pages from the panel).

Network access: the service talks to `https://graphql.anilist.co` and `https://anilist.co` during login.

## Usage

Add the **AniList** bar widget (`tracker`) from Settings, then click it to open the library panel.

```sh
noctalia msg panel-toggle cleboost/anilist:library
```

First launch:

1. Open plugin settings and paste your AniList **client ID** and **client secret**.
2. Open the panel and click **Connect with AniList**.
3. Approve the app in your browser.
4. When the browser shows “Connected to AniList”, return to Noctalia — your lists load automatically.

Inside the panel:

- Switch between **Anime** and **Manga** tabs.
- Filter by list status (Watching, Planning, Completed, Paused, Dropped, Repeating, All).
- Use **−** / **+** to go back or forward one episode/chapter.
- Use the check button to mark an entry completed.
- Use the external-link button to open the entry on AniList.

Right-click the bar widget to open the AniList website.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `client_id` | `string` | `""` | Your AniList OAuth client ID (required for login). |
| `client_secret` | `string` | `""` | Your AniList OAuth client secret (required for login). |
| `access_token` | `string` | `""` | Optional bearer token. If empty, the token saved after browser login is used. |
| `glyph` | `glyph` | `device-tv` | Bar widget icon. |

## IPC

```sh
noctalia msg plugin cleboost/anilist:api all refresh
noctalia msg plugin cleboost/anilist:api all logout
noctalia msg plugin cleboost/anilist:api all login "<jwt-access-token>"
```

## Notes

- Login starts a temporary localhost server on port `7823` only for the duration of the OAuth flow.
- Access tokens are stored in the plugin data directory (`token.json`) after a successful login.
- AniList tokens last about one year; connect again when they expire.
- Incrementing progress on a **Planning** entry moves it to **Watching**. Reaching the last episode/chapter marks it **Completed**.
