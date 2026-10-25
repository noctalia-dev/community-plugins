# Validation and development

Validated on 2026-10-25 with Noctalia 5.3.0 (`0c192f8`).
The plugin requires API 32; the tested host supports APIs 3–39.
Token Monitor 0.68.0 supplies the read-only Hub contract.

## Checks

- Standalone Luau suites cover quota semantics, credential discovery, bounded
  JSON decoding, source changes, stale callbacks, caching, stable account pins,
  analytics, time conversion and heatmap values.
- Isolated native Sway checks use a synthetic authenticated HTTP Hub. They cover
  connection setup/rotation/failure recovery, the five panel views, pagination,
  account pinning, name hiding, heatmap/trends and a structured response over 1.5 MiB.
- The native settings editor uses a flat list and its built-in Advanced toggle.
  The original 26 setting keys, types, defaults and dependent visibility rules
  are preserved; 14 less-used settings are advanced.
- The provider icon suite checks 29 provider IDs and three third-party adapter
  variants: actual cards, fixed 15px bar and 20px panel slots, precise glyphs,
  names and pin selection. Font family and filename are versioned for reload.
- Local Hyprland testing reads the user's configured Hub without triggering
  provider collection. The automated real-Hub probe retains counts/errors and
  disables screenshots.
- The public screenshot contains synthetic history. The 960×540 WebP thumbnail
  was exported using the official Noctalia thumbnail generator.

## Review fixes

The native API audit checked the source used to build the tested executable,
including `docs/plugin-api.json`, the manifest schema, declarative controls,
service callbacks, HTTP/filesystem APIs and panel lifecycle. Container tooltips
require API 32 (introduced in Noctalia 5.2.0), so the previous API 23 declaration
was too low. The manifest now declares API 32; no legacy substitute is installed.
Noctalia 5.2.0 itself has not been runtime-tested.

Settings use only the native flat list, `advanced` and `visible_when`; there is
no custom grouping selector or separate settings file. Panel content uses the
public declarative UI, theme roles and bundled-font API. The fixed scrollbar
gutter is layout code, not a native setting or a guarantee of future dimensions.

Entering Sessions with All time selected now shows the existing unsupported-data
notice instead of silently changing the period to this month. Native Sway checks
verify the notice, absence of substituted session rows, explicit today/month
selection, and preservation of the all-time model period when switching back.
The fixture UI run passed with API 32 and no native runtime errors. Existing
service and maximum-quota results remain applicable to the unchanged data path.

Quota normalization and cache projection yield between bounded window groups.
The aggregate quota limit is 512 windows, with at most 128 accounts and 32 windows
per account. A larger snapshot fails explicitly with `too_large` and retains the
last successful data. This bounds the synchronous native state publication,
which cannot itself be split by the plugin.

The native maximum-quota suite uses 16 accounts × 32 windows with long labels,
then requests 513 windows to verify rejection, retained data and recovery.
The original 4096-window shape reproduced native budget failures, first in
normalization and then in publication; CLI success alone did not establish a fix.

Same-date activity selection now matches the heatmap's last-record-wins rule.
English keys use the community catalog's lowercase convention. The reviewed
provider mapping is static data; the development tool verifies that mapping
and builds only the font from the included, pinned SVG sources.

## Reproduce

Runtime dependencies: Noctalia, Sway, grim and Python 3 on PATH. Pass `--sway`
when the compositor is not on PATH. Tests create private runtime/config/state
folders and reap their own processes; they do not reload the desktop.

```sh
noctalia plugins lint .
python3 tests/run.py --luau /path/to/luau
python3 tests/runtime_probe.py --exercise-connection automatic --large-stats --output output/connection
python3 tests/runtime_probe.py --large-quotas --no-screenshot --timeout 60 --output output/quota-limits
python3 tests/runtime_probe.py --exercise-provider-icons --output output/provider-icons
python3 tests/runtime_probe.py --exercise-ui --settings-json '{"auto_refresh":false,"show_account_names":false,"percentage_mode":"used","accounts_per_page":1}' --output output/ui
```

The UI probe drives handlers through test-only IPC and observes native trees;
it is not physical pointer-click automation. Real-Hub mode requires `--hub-url`
and either `--credentials-file` or `--discover-credentials`, and always disables
screenshots. Ignored `output/` holds local evidence and private deployment backups.
No secrets, raw Hub responses or machine-specific deployment files are published.

These checks cover the documented workloads; they are not proof of every
combination of maximum analytics/history payloads on all machines. Keep future
performance changes tied to reproducible native cases.
