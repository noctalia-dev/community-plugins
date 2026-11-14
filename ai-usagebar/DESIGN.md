---
name: AI Usage
description: Native quota overview for multiple AI accounts
spacing:
  tight: "4px"
  related: "8px"
  card: "10px"
rounded:
  card: "9px"
  tab: "8px"
---

## Overview

A compact native instrument panel. The overview compares accounts; detail keeps
all reported windows and accessory data. Identity and freshness stay visible.
Use the incumbent Noctalia language rather than a separate dashboard theme.

## Colors

Colors are runtime Noctalia roles, not fixed swatches. Use `on_surface` for primary
text, `on_surface/0.8` for supporting text, `primary` for selection and healthy
meters, `secondary` for high consumption and `error` for critical usage or failure.
Cards use `surface_container/0.34` and a subtle `outline_variant` border. Severity
continues to follow consumption when percentages show remaining quota.

## Typography

Inherit the shell font. Panel title: 14px bold; account identity: 12px semibold;
readings: 12px bold; secondary data: 10–11px. Names may truncate to one line but
retain their full value in a tooltip. Never replace provider names with icons alone.

## Layout

Fixed header, a bounded scrolling account overview or detail body,
and supporting freshness information. Use a content-aware viewport within the manifest's
maximum, with scrolling for overflow. Keep one panel entry. Opening the panel—including from a bar capsule—starts with the overview and highlights the tracked account. Detail navigation has at most five
account tabs, with previous/next controls for larger lists.

## Elevation & Depth

Use quiet tonal cards and native controls. Layer-shell placement and exterior
shadows belong to the shell. Avoid decorative shadows, gradients or custom blur.

## Shapes

Preserve the existing 9px card and 8px tab radii. Meters are thin and linear.

## Components

The overview renders at most four account cards per page, with an explicit range
and previous/next controls. Each card identifies an account, shows up to three supplied quota windows
(or all reported windows and model pools grouped by family for Antigravity) with a compact reset badge, pace trend icon, usage bar, and elapsed-time track, or its balance, and offers a detail action. Extra windows are disclosed explicitly.
The detail view retains model groups, credits and optional CLI priorities. Use
native provider glyphs, clock, refresh, settings, navigation and status icons.
Unknown providers keep a readable name and neutral glyph. Bar provider/model
marks use a consistent 16px glyph in an 18px slot; bar reset metadata uses a separate
11px clock/text group shown when usage is near 100% (`>= 90%`) or critical.

## Do's and Don'ts

- Keep account selection, update age and stale state understandable without color.
- Put uncommon account filters and cosmetic controls under native Advanced settings.
- Keep missing values unknown and calendar windows free of invented pacing.
- Preserve native keyboard focus; support arrows, Enter, O, R and Escape.
- Do not add login flows, custom fonts, alert engines or a second quota collector.
