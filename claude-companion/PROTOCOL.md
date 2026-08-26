# The Pulse Protocol

An agent-agnostic contract for driving the `pulse-svc` service aggregator (and everything
downstream of it: the pulse bar widget, the presence orb, tooltips, `claude.pulse` subscribers). The
service knows nothing about Claude Code — it consumes **events** and an optional
**telemetry payload** over noctalia's plugin IPC. Eight of those events describe agent
lifecycle; one (`consent_request`) is a control event and is documented separately
below. Any coding agent that can run
a shell command on its lifecycle hooks (gemini-cli, codex, opencode, aider, a
CI job, a cron script) can light up the same bar dot.

Two adapters ship in `hooks/`:

| Adapter | For | Telemetry |
|---|---|---|
| `pulse.py` | Claude Code (reads hook JSON on stdin, parses the session transcript) | live token burn, O(delta) |
| `pulse-emit` | anything else (plain POSIX sh, args only) | whatever you pass, or none |

## Transport

```
noctalia msg plugin <target> all <event> [payload]
```

- `<target>` is the plugin dispatch id: `<plugin-id>:<entry>` —
  `lowcache/claude-companion:pulse-svc` (the headless aggregator service) for this
  install. Adapters must treat it as configurable (`pulse-emit` reads `$PULSE_TARGET`).
- `all` addresses every monitor's widget instance. (`focused` or a bare
  connector errors when the widget sits on multiple bars.)
- `[payload]` is a **single positional token** — noctalia's msg CLI splits on
  whitespace, so the payload must be space-free. That's why it's a CSV, not
  JSON.
- Fire-and-forget. The dispatch returns `ok: dispatched N` or an error string;
  adapters ignore both (see the fail-open contract below).

## Event vocabulary

Eight events. Priority decides which session the bar shows when several are
active; "resting" matters for the default-slot rule below.

| Event | Meaning | Priority | Resting |
|---|---|---|---|
| `needs_attention` | agent is blocked on the human (permission prompt, question) | 6 | no |
| `error` | hard failure | 5 | yes |
| `tool_start` | executing a tool / command | 4 | no |
| `turn_start` | thinking — a turn has begun | 3 | no |
| `text` | streaming a response | 3 | no |
| `turn_end` | turn finished — output ready for the human | 2 | yes |
| `idle` | session alive, nothing happening | 1 | yes |
| `session_end` | session is over — **retires** its slot | — | — |

Unknown events render as idle-with-the-event-kept-as-state-word; stick to the
vocabulary. Glyph, accent color, and breath animation are widget-side concerns
(see `VISUAL` in `pulse.luau`, and the `breath_speed`, `pulse_glow_floor`, and
`orb_swell` user settings in `README.md`) — the protocol only fixes the *semantics*.

## Payload

```
model,in,out,cacheCreate,cacheRead,session
```

- `session` (field 6) is the only field that changes behavior: it keys the
  per-session slot, so every event from the same agent session must carry the
  same short id (Claude's adapter uses the first `-` segment of the session
  UUID; any stable `[A-Za-z0-9_-]+` token works).
- `model` is a display string; use `?` when unknown.
- Token fields are lifetime-cumulative for the session, not per-turn deltas.
  The widget displays *input* as `in + cacheCreate` (full-rate work) and shows
  `cacheRead` separately. All-zero telemetry is fine — the burn line is simply
  omitted (`model` of `?` or zero in+out hides it).
- No commas or whitespace inside fields.

**Minimum viable adapter:** fire bare events with just a session id —
`?,0,0,0,0,<sid>`. State tracking, urgency priority, multi-session tooltip all
work; you only lose the burn readout.

## Session semantics (what the service guarantees)

- One slot per `session` id; re-sending updates the slot in place.
- The service aggregates the **most urgent** state across all live slots (priority
  table above) into `claude.pulse`; widgets render this rollup and the tooltip lists
  every session, most recent first, with a Σ burn total.
- `session_end` retires the slot. Nothing else does — a real session may sit
  at `idle` or `turn_end` indefinitely and stays listed.
- Because only the trailing `session` field is read for routing, a `session_end`
  whose payload populates *only* that field is a well-formed retire for one
  session and nothing else: `,,,,,<session>`. The `sessions` panel's Retire
  control emits exactly that, which is why manual retirement needs no new verb —
  anything that can send `session_end` can already clear a stuck slot.
- **Payload-less events** (no CSV at all — e.g. a manual
  `noctalia msg plugin … all needs_attention` poke from a terminal) land in a
  single shared `default` slot. To keep CLI pokes from leaving a phantom
  session, any **resting** event (`idle`, `turn_end`, `error`) retires the
  `default` slot instead of updating it. Consequence for adapters: *always
  send a session id*; the default slot is a test surface, not a home.

## Adapter contract

1. **Fail-open, always.** Exit 0 no matter what — noctalia offline, binary
   missing, malformed input. An adapter runs inside an agent's hook path and
   must never block or error the agent. Swallow stdout/stderr, cap the
   dispatch with a timeout (~3 s).
2. **Tag everything with the session id** (see above).
3. **Send cumulative telemetry or none** — don't send per-turn deltas.
4. Don't invent events; map your agent's lifecycle onto the eight above.

### Lifecycle mapping guide

The Claude Code mapping (from `hooks/settings.snippet.json`) doubles as the
template for any agent:

| Agent moment | Event |
|---|---|
| session starts / process launches | `idle` |
| prompt submitted / turn begins | `turn_start` |
| about to run a tool or shell command | `tool_start` |
| tool finished, agent resumes thinking | `turn_start` |
| response streaming to the user | `text` |
| waiting on permission / a question for the human | `needs_attention` |
| turn complete, output delivered | `turn_end` |
| unrecoverable failure | `error` |
| session exits (however it exits) | `session_end` |

If your agent only exposes a subset (say, just "done" notifications), map what
you have — a session that only ever sends `turn_end`/`session_end` still
renders correctly.

### The generic emitter

```
hooks/pulse-emit <event> [session] [model] [in] [out] [cacheCreate] [cacheRead]
```

POSIX sh, no dependencies beyond `noctalia` on PATH. Omitted fields default to
`?`/`0`; omitting `session` sends a bare (default-slot) event. Env:
`PULSE_TARGET` overrides the dispatch id, `PULSE_DRYRUN=1` prints the command
instead of running it. Examples:

```sh
pulse-emit turn_start mysess                 # state only
pulse-emit turn_end mysess gpt-5 12000 800   # with burn figures
pulse-emit session_end mysess                # retire the slot
long_build && pulse-emit needs_attention ci  # non-agent uses work too
```

## Control events (not lifecycle)

Everything above describes the eight **lifecycle** events, which say what an agent is
doing. `consent_request` is different in kind: it does not describe a state, it names
an outstanding question, and only the consent gate emits it.

```
noctalia msg plugin <target> all consent_request "<request-id>,<session-id>"
```

- `request-id` matches a file at
  `$XDG_RUNTIME_DIR/claude-companion/consent/<request-id>.req` — the request itself is
  never carried in the payload, because the payload must stay space-free and a shell
  command is not a place to put one.
- `session-id` is the ordinary short session id, so the service can drive that session
  to `needs_attention` while the prompt is outstanding. Pass an empty field to publish
  the request without touching the session table.

The service mirrors the id to `claude.consent` and opens the consent panel. There is
**no matching resolve event**: the request file is the source of truth, the panel
re-reads it on each tick, and the ordinary `turn_start` from the agent's next
lifecycle hook moves the session off `needs_attention` on its own.

`ask` is the other control event, and it is addressed to the `claude-ask` entry:

```
noctalia msg plugin <plugin-id>:claude-ask all ask
```

A bare poke, no payload. The question is written to
`$XDG_RUNTIME_DIR/claude-companion/ask` first, for the same reason as above — a
question has spaces and a payload does not. It exists so the ask panel can reach the
quick-ask backend without owning a second copy of its read-only flags.

`claude-ask` is a `[[service]]` pointed at `claude.luau`, the same file the `claude`
launcher entry uses. It exists because a `[[launcher_provider]]` is **not
IPC-addressable**: dispatching to `<plugin-id>:claude` answers `no plugin entry
matched` on every target (`all`, `focused`, a bare connector), so this event had no
receiver at all until 1.5.0 and quick-ask from the bar silently did nothing. Pointing a
service at the same file gives the poke an addressable receiver while keeping ONE copy
of the read-only flags in `backend_command()`. The file declares only locals and
callbacks, so the second instance does no work until it is poked.

An adapter for another agent can emit `consent_request` if that agent has a blocking
approval hook of its own, but nothing downstream requires it — an agent that never
emits it simply never raises a prompt.

## Downstream: the `claude.pulse` state mirror

The headless `pulse-svc` **service** is the **single aggregator**; subscribers (the
bar dot, the orb, or any future surface) never parse events themselves. On every
event — never from a timer — it publishes a rollup snapshot to noctalia shared state
under `claude.pulse` (top-level fields below, plus a `sessions` array of per-session
`{sid,state,model,tin,tout,cr}` for multi-session tooltips):

```lua
{ state = <most-urgent event name>,   -- "idle" when no sessions
  count = <live session count>,
  model = <model or "?">,             -- single-session only
  tin   = <in + cacheCreate>,         -- one session's, or the Σ across all
  tout  = <output tokens>,
  cr    = <cacheRead; 0 when count > 1> }
```

Both desktop and bar widgets receive it via `noctalia.state.watch("claude.pulse",
cb)` — state.watch fires across all of a plugin's runtimes as of the Noctalia 5 beta
(the earlier "bars must poll" limitation is gone).

## Deployment (retired invariant)

The aggregator is the headless `pulse-svc` **`[[service]]`** — it starts at shell
launch and runs with no surface, so event capture never depends on any widget being
placed. (Historically the aggregator lived in the `pulse` bar widget: if that widget
wasn't on a bar, every event was silently dropped and all subscribers froze — the
**D10** fragility. Retired by the `[[service]]` entry kind added in the Noctalia 5
beta; requires `plugin_api >= 3` on a service-capable build.) The bar dot and orb are
now pure subscribers of `claude.pulse`, so placing them is purely cosmetic.
