# Design

## Purpose

GitHub Activity is a native, compact view of an authenticated GitHub account's
contribution activity in the Noctalia v5 bar. It should feel like part of the
active Noctalia theme rather than a separate GitHub-branded application.

## Surfaces and interactions

| Surface | Purpose | Interaction |
| --- | --- | --- |
| Bar widget | Quiet at-a-glance status | Shows the GitHub glyph with a configurable contribution metric, or the glyph alone. Left-click opens the calendar; right-click requests a refresh. |
| Calendar panel | Inspect annual activity and streaks | Opens attached to the widget, near the click when possible; hover a day to inspect its count; use Refresh to request new data; use Open profile to open the authenticated account on GitHub. |

The panel is `680 × 430` and attached by default. Keep it compact enough for
a bar workflow and avoid navigation, settings, or persistent controls inside
it.

## Visual language

- Use Noctalia semantic theme colors, typography, controls, separators, and
  iconography. Do not introduce fixed GitHub-green palettes or custom fonts.
- The panel hierarchy is: header and refresh action; calendar; contextual
  annual or hovered-day summary; three metrics; profile action.
- The heatmap uses seven weekday rows and consecutive week columns. Its five
  intensity levels map from `surface_variant` through increasing `primary`
  opacity to `primary`. Cells remain individually hoverable.
- Show only Monday, Wednesday, and Friday labels to preserve horizontal space.
  Month labels are centered across the weeks that belong to each month and may
  be omitted when there is insufficient space.
- Metric values are visually dominant. Their small block indicators provide a
  secondary, bounded visual cue and must not replace the numeric value.

## States and resilience

- The widget always remains visible. Before data is available it shows an em
  dash; its tooltip explains loading or the actionable failure.
- Prefer valid cached data to an empty interface. Cached data must be clearly
  identified as stale while a refresh is attempted.
- The panel has explicit loading/preparation, no-data, missing-`gh`, GitHub CLI
  authentication, request, and invalid-response states. Each no-data state
  provides a retry action.
- Building the interactive calendar must stay incremental and non-blocking so
  it remains within Noctalia's Luau execution budget. Do not replace it with a
  large synchronous UI build without measuring the impact.
- Opening a profile depends on `xdg-open`; when it is unavailable, show a
  localized error instead of failing silently.

## Accessibility and content

- Text must remain legible in light and dark themes and must use semantic
  foreground colors against the current surface.
- Do not rely on heatmap color alone: the selected day exposes its date and
  count as text, and metrics remain numeric.
- Keep actionable labels and failure guidance localized through
  `translations/en.json`; do not introduce user-facing string literals without
  a translation entry.
- Preserve concise, factual language. The plugin never exposes credentials or
  claims data freshness that it cannot establish.
