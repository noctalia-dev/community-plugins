# Web Search

Open a configurable set of websites or search Google directly from the Noctalia launcher. Frequently opened configured sites are promoted automatically.

## Plugin

| Field | Value |
| --- | --- |
| ID | `notfinaldev/web-search` |
| Entries | Launcher provider: `search` |
| Launcher Prefix | `/web` |

## Requirements

Install these commands on `PATH`:

- `python3` — URL-encodes Google search queries.
- `xdg-open` — opens selected websites and searches in the system's default browser.

## Usage

Open the Noctalia launcher and type `/web` to browse the configured websites. Type text after `/web` to filter those sites and add a **Search Google** result. Activating a website opens its configured URL in the default browser; activating **Search Google** opens a Google search for the entered text.

Configured sites are ordered by most recent activation. Sites that have never been opened retain the order in **Websites** settings.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `links` | `string_list` | `GitHub|https://github.com`, `GitLab|https://gitlab.com`, `Codeberg|https://codeberg.org`, `Reddit|https://reddit.com`, `YouTube|https://youtube.com`, `Gmail|https://mail.google.com` | Websites displayed by `/web`. Each entry must be `Name|https://example.com`; entries without a non-empty name or an `http://`/`https://` URL are ignored. |

## Notes

- The plugin fetches missing 64px favicons over HTTPS from `https://www.google.com/s2/favicons` for every valid configured website domain whenever launcher results refresh, even if that site does not match the current filter; it also fetches `www.google.com` when a non-empty search is entered. Favicon PNGs are cached in the plugin's `cache/` directory and are reused while present.
- Each activated configured website updates `cache/mru.txt`. It is a local last-use ledger containing one `used <sequence>|<url>` line for each opened configured URL; higher sequence numbers are more recent.
- Website activation asynchronously runs `xdg-open '<configured URL>' >/dev/null 2>&1`. Google search activation asynchronously runs `python3` to percent-encode the entered query, then opens the resulting `https://www.google.com/search?q=...` URL with `xdg-open`; both command outputs are discarded.
