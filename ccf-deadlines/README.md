# CCF Deadlines

Live countdowns to upcoming computer-science conference deadlines in your bar, using the community-maintained data
from [ccfddl/ccf-deadlines](https://github.com/ccfddl/ccf-deadlines). Rows show CCF and CORE ranks, and each
conference has a detail view with its full timeline, venue and recent acceptance rates.

## Plugin

| Field | Value |
| --- | --- |
| ID | `samxu29/ccf-deadlines` |
| Entries | Bar widget: `widget`; panel: `panel`; service: `service`; launcher provider: `launcher` |
| Launcher Prefix | `/ddl` |

## Requirements

- `curl`, `jq` and `bash` to download and trim the deadline data, with `grep`, `mv`, `rm` and `touch` used by the
  same download script.
- `xdg-open` to open conference websites in your browser.
- Network access to `ccfddl.com`.

## Usage

Add the **CCF Deadlines** widget to a bar from Settings → Bar. It shows the next deadline and a live countdown,
preferring starred conferences. The icon turns tertiary within two weeks of the deadline and error within the urgent
threshold. Hover for the next six deadlines, click to open the panel, right click to download fresh data.

Toggle the panel from a keybind or a terminal:

```sh
noctalia msg panel-toggle samxu29/ccf-deadlines:panel
```

- The **panel** lists one row per submission round, starred conferences first, then by deadline. A round counts down
  to its abstract registration while that is ahead (marked `abs`, with the paper date beside it), then to the paper
  deadline. Badges show the CCF rank, the CORE rank and the research area; hover a badge for what it means. Filter by
  name, area or place, or switch to **Starred**. Click ☆ to follow a conference.
- **Click a row** for its detail view: description, recent acceptance rates, CCF / CORE / THCPL ranks, dates and
  venue, a live countdown, and a timeline of the abstract, paper, rebuttal, notification and conference opening in
  your local time. ↗ opens the conference website, ← goes back.
- **Launcher:** type `/ddl` for the next deadlines, or `/ddl neurips` to search by name, description or area.
  Activating a result opens the conference website.
- **Reminders:** starred conferences get a notification `notify_days` before their abstract and paper deadlines,
  and again in the last 24 hours.

Deadlines are converted from the conference's timezone (`AoE`, `UTC±N`, or `PT` with US daylight saving) to your
local time.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `min_rank` | `select` | `C` | Lowest CCF rank listed: `A`, `B`, `C`, or `all` (including unranked). Starred and always-shown conferences ignore it. |
| `categories` | `string_list` | `[]` | ccfddl area codes to include: `AI`, `CG`, `CT`, `DB`, `DS`, `HI`, `MX`, `NW`, `SC`, `SE`. Empty lists every area. |
| `always_show` | `string_list` | `[]` | Conference names (for example `NeurIPS`) listed regardless of rank and area filters. |
| `include_abstract` | `bool` | `true` | Count down to a round's abstract deadline while it is ahead. When off, rows always count down to the paper deadline. |
| `horizon_days` | `int` | `180` | Only list rounds whose next deadline is within this many days (7 to 730). |
| `notify_days` | `int` | `7` | Days before a starred deadline to send a reminder; a second one follows in the last 24 hours. `0` turns reminders off. |
| `notify_all` | `bool` | `false` | Send reminders for every listed round, not only starred conferences. At most five go out at once; the rest follow on later checks, about ten minutes apart. |
| `refresh_days` | `int` | `7` | Days between data checks (1 to 30). |
| `data_url` | `string` | `https://ccfddl.com/conference/allconf.json` | Advanced. HTTPS source of the deadline data; acceptance rates are read from `allacc.json` next to it (skipped if the URL does not end in `allconf.json`). Other schemes are refused. |

Bar widget settings:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `glyph` | `glyph` | `calendar-due` | Icon shown in the bar. |
| `show_text` | `bool` | `true` | Show the conference name and countdown next to the icon. Off gives an icon-only widget. |
| `display` | `select` | `name_countdown` | With `show_text` on: `name_countdown`, `countdown` only, or `icon` only. |
| `prefer_starred` | `bool` | `true` | Show the next starred deadline, falling back to the next deadline overall. |
| `urgent_days` | `int` | `3` | Days left at which the icon turns to the error color. |

## IPC

Download fresh data now, skipping the refresh interval:

```sh
noctalia msg plugin samxu29/ccf-deadlines:service all refresh
```

Open the panel straight into a conference's detail view, for example from a keybind. The argument is a conference
name; if it has no upcoming deadline, the list opens instead:

```sh
noctalia msg panel-open samxu29/ccf-deadlines:panel mobisys
```

## Notes

- **Network:** every `refresh_days`, and when you refresh by hand, the service runs one `bash` script that requests
  `https://ccfddl.com/conference/allconf.json` and `allacc.json` with `curl`. Each request carries the server's
  last-modified date from the previous download, so unchanged data comes back as an empty `304 Not Modified`. Changed
  data is requested in one compression format, the best your curl supports (zstd, else brotli, else gzip): about
  114 KB and 49 KB. Only `https` is allowed and each download is capped at 20 MB. A failed download is retried after 15 minutes, then 30, 60 and so on, up to the refresh interval.
  The plugin makes no other network requests.
- **Processing:** `jq` trims the deadline file to editions with a deadline from two days ago onward (about 50 KB) and
  the acceptance rates to the two most recent years (about 15 KB). Decoding the full files would go over Noctalia's
  per-callback CPU budget.
- **Files:** the trimmed data, its timestamps (`*.stamp`), `meta.json`, your stars (`favorites.json`) and the
  reminders already sent (`notified.json`) are written to the plugin data directory,
  `~/.local/state/noctalia/plugins/data/samxu29/ccf-deadlines`. Nothing is written anywhere else.
- **Processes:** besides the download script, the plugin only runs `xdg-open <url>` when you open a conference or
  ccfddl website.
- Deadline data and acceptance rates come from ccfddl and may lag behind conference announcements. Check the
  conference website before you submit.
