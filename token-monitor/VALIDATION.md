# Validation and development

Current source as of 2026-10-28 is 0.1.2 and requires API 43, retaining
the upstream API 43 theme-role migration. The standalone Luau suites pass
with the duplicate-history and shared session-model budget regressions below.
Native publication stress and focused session-detail UI acceptance also pass
on Noctalia 5.4.0 (`d8d6616`) with private headless Sway 1.12.

The historical acceptance described below ran on 2026-10-25 with
Noctalia 5.3.0 (`0c192f8`), API 32 and a host supporting APIs 3–39; it does
not establish native acceptance of the current API 43 revision.
Token Monitor 0.68.0 supplies the read-only Hub contract.

## 2026-10-28 review fixes

History normalization resolves duplicate daily/monthly dates in source order
before applying retention, keeping the last source row. Counts refer to distinct
dates, so repeated dates cannot consume retention slots or inflate list counts.
Repeated cache restores preserve both selected values and truncation metadata.

Session model detail shares 512 rows across today's and this month's retained
sessions. Each period still retains up to 200 sessions, and each period's model
aggregate retains up to 128 models. The detail allowance is distributed over
remaining sessions, so a full today list cannot consume all of month's detail.
Session and period totals are preserved. Each session keeps its source model
count, and expanded detail reports omitted models and local truncation. Cache
restoration reapplies the same bound and preserves source counts.

The combined native test observed the actual published state: 512 quota windows,
384 period-model rows, 400 sessions, 512 session-model rows, 370 daily and 1200
monthly history buckets, and 4096 history-attribution rows. Initial processing
and cache work drained in 46.759 seconds; a subsequent small stats refresh with
the same full history drained in 12.245 seconds. There were no plugin processing
or CPU-budget errors. An analytics-only maximum case also passed and accepted
the subsequent small refresh. These are synthetic Hub inputs, not live account
or network performance measurements.

All 9 standalone Luau suites passed, including last-row duplicate resolution,
retention of distinct dates, shared detail allocation, unchanged totals and
three repeated cache restores. Lint reports 0 errors / 0 warnings, and the
current upstream manifest validator accepts the plugin.

The focused native UI test expands a session whose source has 130 models and
confirms both "122 additional models are not shown" and the local truncation
notice. It checks the real rendered tree and native child limits; it does not
claim a complete new visual acceptance of every view. An earlier broad UI run
was interrupted without a final evidence file and is not counted as passed.

Evidence (local, synthetic data only):

- `/tmp/noctalia-fixes-20261028/token-analytics/evidence.json`
- `/tmp/noctalia-fixes-20261028/token-combined-final/evidence.json`
- `/tmp/noctalia-fixes-20261028/token-ui-focused/evidence.json`

The native budget harness is in the outer maintenance workspace at
`tests/token-monitor/runtime_analytics_budget.py`. The focused UI command uses
this plugin's `tests/runtime_probe.py --exercise-ui --session-model-overflow
--no-screenshot`. Private Sway/Noctalia process groups, configuration, fixture
credentials and loopback HTTP servers are cleaned up. The plugin only reads
the loopback fixture in these tests; Noctalia's unrelated currency component
may independently attempt its public CDN. No desktop source, real Hub account,
GitHub data or installed plugin was modified.

Accepted core SHA-256:

```text
lib/analytics.luau      f89126770747efb1905b15f6c92d504b74c41cc93e15c67374ec554c48b608aa
lib/analytics_view.luau 9de71f4754121b75f8cb32cf8d832d1039125ef8eb100394114e700fa83065bd
```

## Checks

The PR preparation run also captured the [native session-detail notice](docs/screenshots/synthetic-session-model-truncation.png)
with synthetic data on Noctalia 5.4.0 / Sway 1.12. The copied test panel uses the
native `revealKey` scrolling property to bring the existing notice into view;
production text, layout, data and source files are unchanged. The focused
acceptance passes with capture enabled as well as with `--no-screenshot`.

The two target plugin manifests pass the current upstream validator. Full-tree
validation at upstream `0b8e15a23954c77c3539b84a4ad5ba93e5320206` fails in the
unmodified `honor-earbuds/panel.luau` at lines 51, 157 and 188 because it still
uses the retired `outline` role; this is also reproduced on the clean base.

## Historical checks (2026-10-25)

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
