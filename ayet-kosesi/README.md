# Ayet Köşesi

Ayet Köşesi is a Noctalia desktop widget powered by Akıl Kuran's public **Günün Ayeti** API.

## Plugin

- **ID:** `alitura1/ayet-kosesi`
- **Entry:** `ayet`
- **License:** MIT

## Requirements

- `curl` must be installed and available on `PATH`; it is used only to refresh the Akıl Kuran logo.

## Usage

Add the `ayet` desktop widget from Noctalia's desktop widget settings.

The plugin polls `https://akilkuran.com/api/daily-verse` once per minute. The API is the single source of truth for Akıl Kuran's current automatic/manual Günün Ayeti.

The optional `author` query parameter is used to request the same daily verse in a selected public translation. The plugin resolves it through the following chain:

1. `~/.config/ayet-kosesi/meal-id` — manual override (highest priority; must be a public author ID).
2. `~/.local/bin/akilkuran-meal-id` — helper that reads the user's Akıl Kuran selection (`meal.settings.mealOrder[0]`) from the default browser's local storage. It prints the ID only when a valid selection exists; empty output means "no selection".
3. Every resolved ID is validated against `https://akilkuran.com/api/meal-registry` (public, anonymous). Non-public IDs fall through to the next step.
4. `languageDefaults[language]` from the registry (registry is authoritative — the plugin contains no hardcoded tr/en mapping).
5. Registry `default`, then `105` as a last-resort constant.

The plugin language is detected from Noctalia's own `settings.toml` (`[shell] lang`, read with the API 24 `readFile`) — the most reliable signal, because the Noctalia process may run with an unrelated `LANG`. If the file is missing or unreadable, the process environment (`LC_ALL` / `LC_MESSAGES` / `LANG`) is used as a fallback.

## Interactions (1.5.0)

- **Copy verse** — click the verse text (or the copy glyph button).
- **Share text** — the share glyph copies "verse" + reference + author + URL in one line.
- **Copy URL** — the link glyph copies the verse URL.
- **Header reference** — the header shows the full reference (e.g. `Rad 13:13`) next to the logo.
- **Manual refresh** — the refresh glyph re-resolves the meal selection chain (including the browser helper) and fetches; 20 s cooldown prevents spam.
- Every copy shows a brief "✓ …" confirmation in the status line (2 s, independent from the verse area); long verses scroll instead of being clipped (fixed 420×260 size).
- Status line shows automatic/manual mode, language, and a plain-language notice on network/429/503 errors while the cached verse stays visible.

## Caching and polling

- `/api/meal-registry` is cached ~1 hour (memory + plugin data dir), so the selection chain costs no extra request in the common case.
- The verse cache is validated by day: after midnight the first poll fetches the new verse; the cached verse is never shown for a day it does not belong to.
- The daily verse is fetched only when the day or the resolved meal changes; otherwise the cached verse is rendered. Every ~5 minutes one silent revalidation keeps manual changes in sync; failed requests back off for 90 s.
- Requests are debounced (30 s minimum gap). The helper process is cached for 3 minutes; only manual refresh re-runs it immediately.
- On API failure the last successful verse stays on screen. Cached verses remember their meal; a cache belonging to a different meal is not shown as if it matched the new selection.
- The update loop re-arms its 1 s interval on every tick (interval is one-shot in this Noctalia build), so "✓" confirmations always expire exactly 2 s after the action — verified against the live runtime; a render-time expiry gate is the final safety net.

The plugin stores only its own verse/registry/logo cache under Noctalia's plugin data directory. It does not access Akıl Kuran user accounts, send user data anywhere, or use cookies, Firebase credentials, or private source code.
