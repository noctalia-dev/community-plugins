# AniList (UNOFFICIAL)

Unofficial Noctalia plugin to browse and update your AniList anime and manga lists from the bar. Open the panel to see what you are watching, planning, or have finished, then increment or decrement episode/chapter progress without opening the website.

## Plugin

| Field | Value |
| --- | --- |
| ID | `cleboost/anilist` |
| Entries | Bar widget: `tracker`; panel: `library`; service: `api` |
| Launcher Prefix | — |

## Requirements

1. Create an AniList API application at [anilist.co/settings/developer](https://anilist.co/settings/developer).
2. Set the application **Redirect URL** to `http://127.0.0.1:7823/callback`.
3. Copy the **Client ID** and **Client secret** into the plugin settings.
4. `python3` must be available on `PATH` (used for the temporary localhost login helper).
5. `xdg-open` must be available on `PATH` (used to open AniList media pages from the panel).
6. `zenity` or `kdialog` is required only if you want to download cover images from the panel preview.

Network access: GraphQL and OAuth on `anilist.co`, plus cover image URLs returned by the API (typically AniList CDN hosts such as `s4.anilist.co`).

## Usage

Add the **AniList (UNOFFICIAL)** bar widget (`tracker`) from Settings, then click it to open the library panel.

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
- Filter by list status. Anime uses **Watching**, **Planning**, and so on; manga uses **Reading** instead of Watching and **Plan to Read** instead of Planning.
- The **Watching** / **Reading** filter sorts entries by progress (highest first). Other filters sort A–Z.
- Use **Reload list** to refresh the active tab without logging in again.
- Use the settings button to open **Settings → Plugins**.
- Click a cover image to open a larger preview. From there you can download the cover or close the preview.
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
| `count_mode` | `select` | `current` | Which count to show in the bar widget: `current` (anime in progress), `completed`, `total`, `in_progress` (anime + manga), or `planning`. |

## IPC

```sh
noctalia msg plugin cleboost/anilist:api all refresh
noctalia msg plugin cleboost/anilist:api all logout
noctalia msg plugin cleboost/anilist:api all login "<jwt-access-token>"
```

## Notes

- This is an unofficial third-party plugin and is not affiliated with or endorsed by AniList.
- Login starts a temporary localhost server on port `7823` only for the duration of the OAuth flow. The helper also opens your default browser for authorization.
- OAuth login briefly writes temporary credential/result files in the plugin data directory; they are removed when login finishes.
- Access tokens are stored in the plugin data directory (`token.json`) after a successful login.
- Cover images are cached under the plugin data directory (`covers/v2/`).
- Downloading a cover from the preview writes the image to a path you choose (for example `~/Downloads/`).
- AniList tokens last about one year; connect again when they expire.
- Incrementing progress on a **Planning** / **Plan to Read** entry moves it to **Watching** / **Reading**. Reaching the last episode/chapter marks it **Completed**.
