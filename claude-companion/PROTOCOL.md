# The Pulse Protocol

An agent-agnostic contract for driving the `pulse-svc` service aggregator (and everything
downstream of it: the pulse bar widget, the presence orb, tooltips, `claude.pulse` subscribers). The
service knows nothing about Claude Code — it consumes **events** and an optional
**telemetry payload** over noctalia's plugin IPC. Eight of those events describe agent
lifecycle; three more (`consent_request`, `ask`, `presence`) are control events and are
documented separately below. Any coding agent that can run
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
model,in,out,cacheCreate,cacheRead,session[,pid]
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
- `pid` (field 7, optional, digits only) is the agent process whose exit ends the
  session. If the service can read `/proc/<pid>/stat` when the pid first arrives,
  it retires the slot within ~5 s of that process exiting, or of the pid being
  reused (its start time changes). Send it only when you can name that process
  exactly: a wrapper that exits early (`timeout`, `env`, a shell) retires a live
  session. Omit it from another host or PID namespace. Claude's adapter sends it
  only when `~/.claude/sessions/<pid>.json` on the hook's ancestry names the session.
- No commas or whitespace inside fields.

**Minimum viable adapter:** fire bare events with just a session id —
`?,0,0,0,0,<sid>`. State tracking, urgency priority, multi-session tooltip all
work; you only lose the burn readout.

## Session semantics (what the service guarantees)

- One slot per `session` id; re-sending updates the slot in place.
- The service aggregates the **most urgent** state across all live slots (priority
  table above) into `claude.pulse`; widgets render this rollup and the tooltip lists
  every session, most recent first, with a Σ burn total.
- `session_end` retires the slot, and so does the liveness sweep once the `pid` a
  slot's events carried has exited. Nothing else does — a session without a `pid`
  may sit at `idle` or `turn_end` indefinitely and stays listed.
- Because only the `session` field (6) is read for routing, a `session_end`
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
`?`/`0`; omitting `session` sends a bare (default-slot) event. A `session` of `-`
reads hook JSON on stdin and uses its first `"session_id"` (Codex and other
Claude-style hooks). Env: `PULSE_PID` adds the `pid` field (digits only — see
Payload for when a pid is safe to send), `PULSE_TARGET` overrides the dispatch id,
`PULSE_DRYRUN=1` prints the command instead of running it. Examples:

```sh
pulse-emit turn_start mysess                 # state only
pulse-emit turn_end mysess gpt-5 12000 800   # with burn figures
pulse-emit session_end mysess                # retire the slot
long_build && pulse-emit needs_attention ci  # non-agent uses work too
pulse-emit tool_start - < hook.json          # session id from hook JSON
PULSE_PID=$PPID pulse-emit turn_end aider-$PPID  # retire when that process exits
```

## Ready-made adapters

These setups call `pulse-emit` by name, so put it on your PATH once (catalog path shown; use your dev symlink if that's how you installed):

```sh
ln -s ~/.local/state/noctalia/plugins/materialized/community/claude-companion/hooks/pulse-emit ~/.local/bin/pulse-emit
```

Each one was checked against that project's current source on 2026-09-19; the opencode plugin was also run live, end to end. What you get differs by agent, because each exposes different hooks.

### Gemini CLI

`~/.gemini/settings.json`. Hooks are on by default, and Gemini expands `$GEMINI_SESSION_ID` (shell-escaped) before running the command. Keep these in your user settings: project-level hooks are blocked in untrusted folders.

```json
{
  "hooks": {
    "BeforeAgent":  [{ "hooks": [{ "type": "command", "command": "pulse-emit turn_start $GEMINI_SESSION_ID" }] }],
    "BeforeTool":   [{ "matcher": "*", "hooks": [{ "type": "command", "command": "pulse-emit tool_start $GEMINI_SESSION_ID" }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "pulse-emit needs_attention $GEMINI_SESSION_ID" }] }],
    "AfterAgent":   [{ "hooks": [{ "type": "command", "command": "pulse-emit turn_end $GEMINI_SESSION_ID" }] }],
    "SessionEnd":   [{ "hooks": [{ "type": "command", "command": "pulse-emit session_end $GEMINI_SESSION_ID" }] }]
  }
}
```

`Notification` only fires for tool-permission prompts, which is exactly the needs-you case.

### Codex CLI

`~/.codex/hooks.json` (Codex's Claude-style hooks, enabled by default in current builds). The session id arrives as JSON on stdin, which is what `pulse-emit`'s `-` session argument reads. Two things to know: Codex shows a **Hooks need review** prompt the first time and runs nothing until you trust them, and this file rejects unknown keys, so don't add comments.

```json
{
  "hooks": {
    "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "pulse-emit turn_start -" }] }],
    "PreToolUse":        [{ "hooks": [{ "type": "command", "command": "pulse-emit tool_start -" }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "pulse-emit needs_attention -" }] }],
    "Stop":              [{ "hooks": [{ "type": "command", "command": "pulse-emit turn_end -" }] }],
    "SessionEnd":        [{ "hooks": [{ "type": "command", "command": "pulse-emit session_end -" }] }]
  }
}
```

The older `notify = [...]` setting in `config.toml` still works, but it only fires at the end of a turn and passes JSON as an argument, so the hooks above are the better fit.

### opencode

a plugin at `~/.config/opencode/plugin/pulse.ts`. opencode has no hook for quitting, so the plugin hands over its own process id and the pulse retires the session when opencode exits.

```ts
// Drives the Noctalia pulse from opencode. pulse-emit must be on PATH.
export const Pulse = async ({ $ }) => {
  const emit = (event, sid) =>
    $`pulse-emit ${event} ${sid}`.env({ ...process.env, PULSE_PID: String(process.pid) }).quiet().nothrow()
  return {
    "chat.message": async (input) => { await emit("turn_start", input.sessionID) },
    "tool.execute.before": async (input) => { await emit("tool_start", input.sessionID) },
    "permission.ask": async (input) => { await emit("needs_attention", input.sessionID) },
    event: async ({ event }) => {
      const p = event.properties
      if (event.type === "session.idle") await emit("turn_end", p.sessionID)
      else if (event.type === "session.error" && p.sessionID) await emit("error", p.sessionID)
      else if (event.type === "session.deleted") await emit("session_end", p.info.id)
    },
  }
}
```

### aider

`~/.aider.conf.yml`. aider has one hook: a command it runs whenever it's your turn again (a reply finished, or it's asking you to confirm something). It passes no session id, but the command runs as a direct child of aider, so `$PPID` is aider itself: one session per aider, retired when it exits.

```yaml
notifications: true
notifications-command: "PULSE_PID=$PPID pulse-emit turn_end aider-$PPID"
```

Expect less here than elsewhere: a session appears once the first reply lands, there's no working state in between, and that one command can't tell "done" from "please confirm", so it reports done.

## Control events (not lifecycle)

Everything above describes the eight **lifecycle** events, which say what an agent is
doing. The three below are different in kind — they do not describe a state — and each
has its own emitter: `consent_request` (the consent gate), `ask` (the ask panel) and
`presence` (the MCP shim).

`consent_request` names an outstanding question rather than a state.

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

The service appends the id to a bounded queue published as `claude.consent`
(`{ id = <head>, ids = { … }, sid = … }`) and opens the consent panel. It is a queue
rather than a slot because an agent that issues tool calls in parallel produces prompts
in parallel; the panel shows them oldest-first. There is **no matching resolve event**:
the request file is the source of truth, so an id whose file has gone is dropped from
consideration on the next tick, and the ordinary `turn_start` from the agent's next
lifecycle hook moves the session off `needs_attention` on its own.

`ask` is the second control event, and it is addressed to the `claude-ask` entry:

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

`presence` is the third control event. It is the one channel where the agent says in
its own words what it is doing, rather than the service inferring a state from a
lifecycle edge:

```
noctalia msg plugin <target> all presence
```

A bare poke, no payload. The message is written first to
`$XDG_RUNTIME_DIR/claude-companion/presence`, for the same reason as the other two —
prose has spaces and a payload does not:

```json
{"message": "refactoring the auth middleware", "state": "", "session": "", "at": 1788000000}
```

Only `message` is read today; it surfaces as `claude.pulse.message`. `state` and
`session` are reserved so adding per-session attribution later is not a format change —
an emitter may set them, and must not depend on them being honoured. An **absent file
means no message**, so clearing presence is an unlink, not a sentinel value.

Presence attaches to the rollup, not to the session table: it can never inflate the
session count or outrank a real state. That also means it is **not attributable** while
more than one session is running, which is why the consent panel shows it only when
exactly one is — an unattributed claim must not caption a security decision.

An adapter for another agent can emit `consent_request` if that agent has a blocking
approval hook of its own, but nothing downstream requires it — an agent that never
emits it simply never raises a prompt. The same goes for `presence`.

## Downstream: the `claude.pulse` state mirror

The headless `pulse-svc` **service** is the **single aggregator**; subscribers (the
bar dot, the orb, or any future surface) never parse events themselves. On every
event, and on a 5 s tick only when the liveness sweep or session detection changed
something, it publishes a rollup snapshot to noctalia shared state under
`claude.pulse` (top-level fields below, plus a `sessions` array of per-session
`{sid,state,model,tin,tout,cr,nohooks?}` for multi-session tooltips; `nohooks` is
`true` for a session known only from Claude Code's session files, with no hook yet):

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
