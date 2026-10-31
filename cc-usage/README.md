# Command Code Usage

Desktop widget with the same meters as Command Code's `/usage` overlay — monthly,
5-hour and weekly usage with reset countdowns — computed from Command Code's local
transcripts.

## Plugin

| Field | Value |
| --- | --- |
| ID | `wennington/cc-usage` |
| Entries | Desktop widget: `usage` |

## Requirements

- `python3` on `PATH`.
- Command Code CLI usage data under `~/.commandcode/projects/**/*.jsonl`. These files
  are written by using the Command Code CLI; the plugin needs no login, API key or
  network access of its own.

## Usage

Open **Settings → Desktop → Toggle Editor**, add a desktop widget and pick
**Command Code Usage**, then place it. Outside edit mode the tile sits on the desktop
layer, so normal windows draw above it.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `plan` | `select` | `GOAT` | Plan whose caps are used: `Go`, `GOAT`, `Pro` or `Max 20x`. |
| `multiplier` | `double` | `2.5` | Credits charged per USD of usage for the model you run. Calibrate it against `/usage`; `1.0` is a full-allowance model. |
| `billing_day` | `int` | `28` | Day of the month the subscription renews, used to find the current monthly cycle. |

## Notes

### What it reads and runs

- Reads `~/.commandcode/projects/**/*.jsonl` (the top-level `usage` object on
  assistant messages). Nothing outside that directory is touched.
- Spawns `python3 cc_usage.py` from the plugin directory once a minute; the script
  prints JSON and exits. A run takes ~0.4 s on a 47 MB transcript set.
- No network access, no filesystem writes, no credentials read.

### Limitations

- **Approximation, not the server's numbers.** `/usage` reads the server's credit
  accounting, which is not exposed headlessly (see
  [CommandCodeAI/command-code#1093](https://github.com/CommandCodeAI/command-code/issues/1093)).
  This plugin simulates the 5-hour and weekly windows from local timestamps — a
  window opens on the first request and resets a fixed span later, as the
  [usage-limits docs](https://commandcode.ai/docs/resources/usage-limits) describe —
  and applies a credit multiplier.
- **Other machines are invisible.** Usage made from another computer (or from
  transcripts that were deleted) does not appear here, so the weekly and monthly
  meters can read low when you use Command Code elsewhere.
- **The multiplier depends on the model.** Credits are not a fixed number of dollars:
  a lower-allowance model draws more credits per dollar. Recalibrate the
  `multiplier` setting if you change models.
- **The billing day has to match your subscription.** The monthly meter starts at
  `billing_day` 00:00 local time; set it to your renewal day.
- Window resets can differ from `/usage` by the time since the last refresh (the
  widget updates once a minute).
