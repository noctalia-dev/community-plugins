# The Pulse Protocol

An agent-agnostic contract for driving the pulse bar widget (and everything
downstream of it: the presence orb, tooltips, `claude.pulse` subscribers). The
widget knows nothing about Claude Code — it consumes **events** and an optional
**telemetry payload** over noctalia's plugin IPC. Any coding agent that can run
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

- `<target>` is the plugin dispatch id: `<plugin-id>:<widget-entry>` —
  `lowcache/claude-companion:pulse` for this install. Adapters must treat it as
  configurable (`pulse-emit` reads `$PULSE_TARGET`).
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
vocabulary. Glyph, accent color, and breath tempo are widget-side concerns
(see `VISUAL` in `pulse.luau`) — the protocol only fixes the *semantics*.

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

## Session semantics (what the widget guarantees)

- One slot per `session` id; re-sending updates the slot in place.
- The bar renders the **most urgent** state across all live slots (priority
  table above); the tooltip lists every session, most recent first, with a
  Σ burn total.
- `session_end` retires the slot. Nothing else does — a real session may sit
  at `idle` or `turn_end` indefinitely and stays listed.
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

## Downstream: the `claude.pulse` state mirror

The widget is the **single aggregator**; subscribers (the orb, or any future
surface) never parse events themselves. On every event — never from the
animation timer — it publishes a rollup snapshot to noctalia shared state under
`claude.pulse`:

```lua
{ state = <most-urgent event name>,   -- "idle" when no sessions
  count = <live session count>,
  model = <model or "?">,             -- single-session only
  tin   = <in + cacheCreate>,         -- one session's, or the Σ across all
  tout  = <output tokens>,
  cr    = <cacheRead; 0 when count > 1> }
```

Desktop widgets receive it via `noctalia.state.watch("claude.pulse", cb)`; bar
widgets must poll `state.get` (watch doesn't fire on bars in noctalia 5.0.0).

## Deployment invariant

The aggregator lives in the `pulse` **bar widget** — bar widgets only run when
placed on a bar. If `pulse` isn't in a bar layout, every event is silently
dropped and all subscribers freeze. Noctalia 5.0.0 has no headless plugin
entry kind, so "pulse on a bar" is a hard install requirement.
