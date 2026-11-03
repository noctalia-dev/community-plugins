# Noctalia 5.4 integration

Reviewed on 2026-10-30: AI Triage 1.8.2, plugin_api = 43, installed Noctalia 5.4.0.
Version 1.8.2 auto-resolves bundled session priming (`bin/ai-kickstart`) via
`noctalia.pluginDir()` with fallback to `PATH`. Panel geometry and runtime
contract remain unchanged.

## Panel contract

| Field | Value |
| --- | --- |
| width | 1520 |
| height | "content" |
| max_height | 560 |
| placement / position | attached / auto |
| open_near_click | true |

Noctalia measures content height and limits it to the declared maximum. This
does not make the fixed width responsive. Dimensions are logical pixels; the
physical result depends on scale and available space. The visual confirmation
covers Miguel's machine, not every resolution, scale or a separate niri session.

The three columns retain independent scrolling for longer lists. Keep the
accepted maximum of 560; do not restore the initial migration's 780 limit or
remove internal scrolling merely to shrink the panel.

## Colors and API compatibility

The plugin uses surface_container and outline_variant. on_surface_variant
remains a valid role. variant = "outline" is a button style and must not be
renamed. The review found no remaining surface_variant or outline color roles.

Layer surfaces, idle watches, calendar access, drag and drop and pixel streams
are optional capabilities, not dependencies of this panel. Desktop scripts use
OSD separately; persistent results and errors keep their notification behavior.
A compatible plugin does not need to adopt every new API.

## Verification and sources

Both noctalia plugins lint and noctalia config validate passed. The running
shell lists 1.8.1 as an enabled local plugin. Its symlink points to this checkout;
shared dotfiles reference the plugin without copying its source into their repos.
All twelve tests/*_test.lua suites passed with TZ=America/New_York. Mocked UI
tests validate widget trees and behavior, not actual Wayland pixel geometry.

The catalog mismatch found in the initial review was fixed in 1.8.1. The
selector, three translated catalogs, glyph/dashboard mappings and recorded
1.44 catalog now include Droid; the strict guard covers all 31 provider IDs.
Regressions cover pinning Droid alongside another provider, Standard 5h/weekly
quotas, monthly/Core supplementary data and the poller-to-bar/panel path.
The original twelve suites and both additional timezone checks pass.

Droid is not configured on this machine, so its rendering was checked with
synthetic schema-1 reports, not an authenticated Factory quota response. The
shared report remains focused on short/weekly triage rather than implementing
every provider-specific monthly/Core view. See the
[compatibility audit](ai_usagebar_compatibility.md#factory-droid-and-the-144-catalog-in-181).

Official references:

- [Noctalia 5.4.0 release notes](https://github.com/noctalia-dev/noctalia/releases/tag/v5.4.0).
- [Manifest and minimum API contract](https://docs.noctalia.dev/noctalia/plugins/development/manifest/).
- [Runtime API](https://docs.noctalia.dev/noctalia/plugins/development/runtime-api/).

As of 2026-10-27, 5.4.0 is the only published release in the 5.4.x series.
Check release notes and validate again for future versions; this review cannot
certify unpublished changes.
