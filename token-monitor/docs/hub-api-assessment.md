# Token Monitor 0.68.0 Hub API assessment

Verified 2026-10-23 against the installed application and the running local Hub.
This is a read-only assessment. No collector refresh, provider login, settings
change, ingestion, or other write endpoint was invoked.

## Evidence and boundary

Source contract: [Token Monitor v0.68.0](https://github.com/Javis603/token-monitor/tree/v0.68.0).

The authoritative source files are:

- `src/hub/server.js`: HTTP routing and aggregate responses.
- `src/shared/usage.js`: period, session, device, and history aggregation.
- `src/shared/history.js`: history shape, retention, preview, revision.
- `src/shared/syncPayload.js`: uploaded detail omissions and size budget.
- `src/shared/limits/core.js`: provider/window normalization and identity.
- `src/shared/sessionLive.js`: the application's session activity display rule.
- `src/electron/preload.js` and `src/electron/main.js`: Electron-only IPC and
  local history/session additions unavailable through Hub HTTP.

Authenticated `GET /api/health`, `/api/stats`, `/api/history`, `/api/devices`, and
`/api/sync/content` all returned HTTP 200 at `http://127.0.0.1:17321`.
Credentials were read in-process from the existing credential file; secrets
were never passed in command arguments or printed. No raw response was saved.
Only field types and aggregate counts are recorded below.

## First connection and Host terminology

Source inspection of 0.68.0 confirms `src/electron/renderer/index.html:1421-1484`
uses **Sync method** with **Local only**, **Connect to a hub**, and **Host hub on
this device**. Local is the default; only host starts the embedded HTTP Hub.
Host has **Port** and **Shared Secret** fields. Client has **Hub URL** and
**Secret** and forwards usage to a different host. These are Token Monitor's
settings, not additional Noctalia modes.

`main.js:3295-3314` generates and saves a host secret when needed.
`shared/credentialStore.js:17-20,256-260` stores it as
`credentials.hub.hostSecret` in `credentials.json` under Electron's userData
folder (`main.js:2370-2372`). Product name is **Token Monitor**, so the standard
Linux location is `~/.config/Token Monitor/credentials.json`, subject to the
application's configuration home. The separate shared-data directory controlled
by `TOKEN_MONITOR_SHARED_DIR` is not a credential-store override. Client secrets
use `credentials.hub.clientSecret`; the plugin's automatic lookup deliberately
uses only hostSecret and only for loopback endpoints.

The plugin's connection test uses the same two supported read-only endpoints,
validates fresh responses independently, and does not start collection or
change the mode. There is no new guessed detection endpoint.

## View and time support

| View | HTTP data | Time support | Important boundary |
| --- | --- | --- | --- |
| Quotas | `stats.limits.providers[]`, each provider's `windows[]`, balances and reset credits | Current provider snapshot and provider-defined reset windows | No historic quota time series or arbitrary date filter. Usage-period selection must not relabel current quota as historical quota. |
| Models | `stats.periods.{today,month,allTime}` model maps; `history.daily/monthly[].perModel` | Exact producer today/current calendar month/all-time aggregates; day/range/week selections can sum retained daily buckets; older full calendar months can sum monthly buckets | No hourly data or model throughput outside the fixed period maps. Do not invent component values when capability flags are false. |
| Sessions | `stats.periods.today.sessions`, `.month.sessions` maps | Fixed today/month usage counters with `startedAt`/`lastUsedAt`; classify or sort recent sessions by these timestamps | All-time sessions are deliberately excluded from sync uploads. Timestamp filtering selects sessions but cannot split a session's token/cost counters across an arbitrary interval. |
| Activity | `history.daily[]`, `summary` for heatmap/counts; session timestamps and `turnEnded` for recent-session display | Daily activity and retained-day summaries; recent/ended/idle can follow the application's display rule | No HTTP transcript activity/events or message-by-message timeline. An activity dot is a display inference, not proof of a live process. |
| Trends | Full `/api/history` daily/monthly tiers, `perClient`, `perModel` | Day-based trends within the rolling daily retention and uncapped monthly history | `stats.historyPreview` is only the last 30 days/12 months and drops attribution. It cannot replace full history. |

The Hub does not read date, range, cursor, offset, page, or limit query arguments
for these routes. There is no server-side pagination. Receive the full response,
then filter/page locally. No endpoint name was guessed or probed.

## Stats and model contract

`GET /api/stats` has:

```text
updatedAt: ISO string (Hub response construction time, not collection time)
periods: {today: Period, month: Period, allTime: Period}
devices: Device[]
projectsIncomplete: boolean
limits: {updatedAt: ISO string, providers: Provider[]}
staleAfterMs: number
historyPreview: {daily: PreviewDay[], monthly: PreviewMonth[], summary: Summary}
historyRevision: string
deviceHistoryRevision: string
subscriptionsUpdatedAt: string
syncSettingsRevisions: {modelAliases: number, customPricing: number}
sessionDetailsOmitted?: map<period, omitted count>
periodProjectsOmitted?: map<period, omitted count>
```

`Period` fixed fields:

```text
capabilities: {tokenComponents: boolean, throughput: boolean}
totalTokens, costUsd, cacheReadTokens, cacheWriteTokens, outputTokens,
unclassifiedTokens, timedTokens, timedOutputTokens, timedDurationMs: number
models, modelCosts, modelCacheReads, modelCacheWrites, modelOutputs,
modelUnclassifiedTokens: map<model, number>
modelThroughput: map<model, {timedTokens, timedOutputTokens, timedDurationMs}>
clients, clientCosts, clientCacheReads, clientCacheWrites, clientOutputs,
clientUnclassifiedTokens: map<client, number>
clientModels, clientModelCosts: map<client, map<model, number>>
projects: map<project key, {label: string, tokens: number, costUsd: number,
                            clients: map<client, number>}>
sessions: map<opaque session key, Session>
```

Optional unpriced-token fields can accompany usage totals and attribution maps.
Keep missing/unpriced amounts distinct from an authoritative zero cost.
`timedOutputTokens / (timedDurationMs / 1000)` is the timed output throughput;
zero duration means unavailable, not zero speed. Duration sums can overlap across
concurrent messages/sessions; they are not elapsed wall-clock time.

The public component model folds independent reasoning into output-family
tokens for clients with disjoint reasoning. Do not add session `reasoningTokens`
to an already inclusive output bucket. Input/cache-miss display needs the
application's component semantics, not an unconditional sum of every token field.

Period calendar boundaries are producer-owned. Each device may include:

```text
periodWindows: {today: {key, endsAt}, month: {key, endsAt}, timeZone: string}
```

The aggregate excludes expired fixed-period snapshots. Device `stale`, `ageMs`,
`updatedAt`, and `receivedAt` remain necessary for freshness; top-level
`updatedAt` alone does not establish recent collection. Cross-device calendar
periods may use different producer time zones.

## Session contract and completeness

`Session` observed field types (all values below are names/types, no user data):

```text
client, sessionId, projectId, projectLabel, title, sessionKind: string
startedAt, lastUsedAt: ISO string or empty string
totalTokens, costUsd, messageCount, inputTokens, outputTokens,
cacheReadTokens, cacheWriteTokens, reasoningTokens,
timedOutputTokens, timedDurationMs, contextTokens, contextWindow: number
models, modelCosts, providers: map
promptCache?: object
turnEnded?: boolean
archived?: boolean
```

The wire map key is `client + ':' + sessionId`; preserve it as an opaque key.
It is not an account ID. Sessions are period usage records, not activity events.
Context `0/0` normally means unavailable; the application's context helper
requires positive context tokens and a positive window size.

Actual response counts during this assessment: one device; 9 today sessions,
806 current-month sessions, zero all-time sessions; 3/7/7 model keys for the
three periods; 3 quota provider rows. Counts can change during normal collection.

`buildSyncPayload` unconditionally removes all-time session detail before upload.
This is not pagination and cannot be repaired by another HTTP page. The desktop
uses IPC `stats:allTimeSessions`, combining the Hub month records with local
full all-time sessions; a separate IPC `session:getDetail` reads local session
detail. Neither is a Hub HTTP route. Local-only Reasonix native sessions/projects
are also excluded from sync.

Today/month detail can be shortened to fit the upload budget (1 MiB request
ceiling minus 16 KiB margin = 1,032,192 bytes). The serializer first removes
optional model throughput, historical component detail, and all-time projects;
then keeps the most recently used month sessions, then today sessions if needed.
`sessionDetailsOmitted[period]` reports omitted rows; `periodProjectsOmitted`
and device `allTimeProjectsOmitted`/`allTimeProjectsIncomplete` report other gaps.
The fixed-period aggregate totals remain independent of retained session rows;
do not recalculate global totals by summing a possibly truncated list.

Session text is removed at sync boundaries unless title sharing is explicitly
enabled. Current `/api/sync/content.sessionTitles.enabled` is **false**.
An empty `title` field is expected and does not establish a lost title.
Transcript messages/previews never become a Hub timeline through this setting.

Application activity display rule (`sessionLive.js`): archived/deleted sessions
are idle; missing `lastUsedAt` is idle; activity within ten minutes with
`turnEnded === true` is ended; other activity within ten minutes is running;
older activity is idle. This is a bounded display rule.

## Quota contract and stable identity

```text
Provider = {
  provider, accountKey, accountLabel, planLabel, accountName, accountEmail,
  workspaceKind, status, source, sourceDetail, updatedAt, region: string,
  sourceDeviceId: string, stale: boolean, windows: Window[],
  balanceUsd: number|null, balance: object|null, resetCredits: object|null,
  adapterId?: string, accountKeyAliases?: string[], webAccountKey?: string,
  actionRequired?: object, usageSummary?: object
}
Window = {
  kind, label, resetDescription, detail: string,
  used, limit, remaining, usedPercent, remainingPercent: number|null,
  resetsAt: ISO string|null, windowMinutes: number|null,
  currency: string|null, showMeter: boolean,
  metric?: string, source?: string, limitId?: string,
  boundaryKind?: string, additional?: true
}
```

No normalized provider `accountId` field exists. Use the opaque `accountKey`,
not account label/email, as the normal account discriminator together with
`provider`. Preserve `region` as an additional discriminator (Alibaba plans can
share an account key). Anonymous Antigravity observations are scoped by
`sourceDeviceId`; an empty key is not stable account identity. Stable local row
identity must not collapse multiple accounts by provider name or display label.
Codex derives a key from email plus workspace/account identity when both are
available; its fallback can be a stored key/local identity. Antigravity keys are
portable only when normalized email proves identity. DeepSeek's key hashes the
API key, so credential rotation may change identity even for the same balance.
Do not advertise every provider key as an eternal user identity.

Preserve every window. `kind` and human `label` are not necessarily unique;
`limitId`, `metric`, `boundaryKind`, `additional`, and source must survive
normalization. Missing percentages/limits are unknown, not zero usage.
`showMeter === false` is an intentional display hint.

`balance` may contain amount/currency, today/week/month/all-time spend,
tracking start, partial-month marker, request count, plan amount/status,
gift/cash balance, expiry and tranches. Its normalized keys are `amount`,
`currency`, `todaySpend`, `weekSpend`, `monthSpend`, `allTimeSpend`,
`requestCount`, `quotaGroup`, `expiresAt`, `trackingSince`,
`monthSinceTracking`, `giftBalance`, `cashBalance`, `planUsed`, `planLimit`,
`planPercent`, `planStatus`, `todayTokenTotal`, `todayUsageDate`,
`latestModelUsageDate`, `todayUsageBasis`, `snapshotDate`, and optional
`tranches[]: {amount,currency,expiresAt}`. `resetCredits` has
`availableCount: number|null`, `nextExpiresAt: ISO string|null`, optional
`expirations: ISO string[]`, and optional `grants[]` with
`id,label,resetsLeft,resetsTotal,startsAt,endsAt,clears,usableNow,useRequiresLimit,paused`.
These are current provider-specific reports,
not a general daily quota history. Do not coerce currency amounts to USD.

## Full history contract and retention

```text
History = {daily: Day[], monthly: Month[], summary: Summary}
Day = {
  date: YYYY-MM-DD string,
  tokens, cost, messages, activeTimeMs: number,
  cacheReadTokens, cacheWriteTokens, outputTokens, unclassifiedTokens: number,
  tokenComponentsAvailable: boolean,
  perClient: map<client, {tokens,cost,messages, component fields?}>,
  perModel: map<model, {tokens,cost, component fields?}>,
  tokenIntensity, costIntensity, intensity: number,
  unpricedTokens?: number
}
Month = {
  month: YYYY-MM string, tokens,cost,activeTimeMs: number,
  perClient: map<client,{tokens,cost,messages}>,
  perModel: map<model,{tokens,cost}>, unpricedTokens?: number
}
Summary = {
  totalTokens,totalCost,activeDays,currentStreak,longestStreak,
  peakDayTokens,messages,activeTimeMs: number,
  favoriteModel: string, unpricedTokens?: number
}
```

Current full history has 22 daily rows and 2 monthly rows. Daily history is a
rolling 370-calendar-day window, not a promise of 370 populated rows; monthly
history is uncapped. Aggregate lifetime totals come from monthly buckets, while
active days/peak/streaks use the retained daily window. Do not recompute the
all-time token/cost headline from the 370-day tier.

Synced daily token-component detail is retained for the most recent 30 days and
can be removed sooner for payload size. Check `tokenComponentsAvailable` before
rendering component totals; older rows still carry aggregate tokens/cost.
Monthly buckets do not supply token components or throughput. Full history
contains client and model attribution but no project/session/date cross-product.

`historyRevision` is a content invalidation key for the full history;
`deviceHistoryRevision` additionally detects changes in device attribution.
Polling history when the relevant revision changes follows the desktop design.
SSE `/api/stats/stream` exists and starts with a snapshot event; it was inspected
in source but not opened in this assessment. Its stream carries aggregate
snapshots/freshness, not transcript activity events.

## Implementation consequence

The plugin can expose substantially richer quotas, models, period sessions,
daily activity and daily/monthly trends through the existing supported HTTP
contract. It cannot honestly reproduce the desktop's complete all-time session
list, transcript detail, native local-only sessions, arbitrary-hour slicing, or
historical quota snapshots through these routes. Surface those gaps explicitly;
do not add speculative endpoints, count truncated rows as complete, or combine
fixed-period session counters into fabricated arbitrary-range usage.
