# Claude Companion

![Claude Companion — a Claude Code companion for Noctalia: pulse, orb, and answer panel](thumbnail.webp)

A Noctalia v5 plugin that puts [Claude Code](https://claude.com/claude-code)'s live status on your desktop — a **pulse** on the bar, a breathing **orb** on the desktop, and an **answer panel** for quick questions.

![version](https://img.shields.io/badge/version-1.5.0-blue) ![license](https://img.shields.io/badge/license-MIT-informational) ![noctalia](https://img.shields.io/badge/noctalia-5.0.0-blueviolet)

Claude Code is a brilliant agent trapped in a text box. It can't see the windows you have open, can't tap you on the shoulder when it hits a wall, and gives you nothing to glance at while it churns. So you sit there watching a terminal, or you wander off and miss the moment it needed you.

This plugin gives it a body. It wires Noctalia into Claude's lifecycle so a **pulse** on your bar tracks every session, an **orb** on your desktop breathes along with the work, and an **answer panel** catches one-shot replies before they scroll away. The terminal keeps doing the actual thinking — permissions, tools, MCP, all native. This is just the nervous system that lets the rest of your desktop feel it.

Don't run Claude Code? The signal bus is agent-agnostic — any agent, CI job, or shell script that can run a command on its own lifecycle can light up the same bar. See [Wiring up other agents](#wiring-up-other-agents).

## Plugin

| Field | Value |
| --- | --- |
| ID | `lowcache/claude-companion` |
| Entries | Services: `pulse-svc`, `claude-ask`; bar widget: `pulse`; desktop widget: `orb`; panels: `answer`, `sessions`, `consent`, `ask`; launcher: `claude` |
| Launcher Prefix | `/claude` |

Built and live-tested against Noctalia 5.0.0 (build `623210223c`), with an offline widget spec suite keeping the state machine honest.

## See it

![The bar pulse and desktop orb breathing through a Claude session's lifecycle](assets/pulse.gif)

One session, start to finish: the **pulse** on the bar and the **orb** on the desktop breathe through idle, thinking, a tool run, done, and needs-you.

![A quick question answered in the answer panel](assets/question.gif)

Ask something quick with `/claude ?` and the whole answer waits for you in the panel, instead of scrolling off the top of the terminal.

## How it works

**Perceive.** `shim/noctalia-mcp.py` is a stdio MCP shim that hands Claude a live read on your machine: `niri msg -j` for the windows you have open, `playerctl` for what's playing, `noctalia msg status` for the state of the shell itself. Nothing to wire up by hand. Launch through `/claude` and it attaches itself.

**Practice.** Everything on the backend funnels through `claude.luau`, the `/claude` launcher and the one door in. It normalizes the event vocabulary, throws `notify-send` toasts, and calls `noctalia msg` to move panels around. One chokepoint on purpose — so when something acts up, there's exactly one place to go look. That file is registered twice: as the `/claude` launcher, and as a `[[service]]` under `claude-ask`. A launcher entry can't receive IPC, so the ask panel's poke needs the second registration to have somewhere to land — same file either way, so the read-only flags for a quick-ask still live in exactly one place.

**Pulse.** `pulse-svc.luau` is a headless `[[service]]` that runs the show. Hook events land here over IPC at `lowcache/claude-companion:pulse-svc`, and from there it does the rest: tracks every session at once, surfaces whichever one's most urgent, and publishes a rollup to shared state under `claude.pulse` for subscribers to read.

And downstream is where the surfaces live. `pulse.luau` on the bar and `orb.luau` on the desktop are independent subscribers that only render. Both watch `claude.pulse` — `pulse.luau` breathes the accent color and shows per-session tooltips, while `orb.luau` breathes the same state frame by frame, glyph and opacity riding a sine wave, tempo picking up as things get urgent. Neither holds hooks or logic of its own. `answer.luau` is the `answer` panel that catches a `/claude ?` reply and holds the whole thing: wrapped, scrollable, all the parts a toast lops off the end.

## Requirements

- **Noctalia 5.0.0** on a supported Wayland compositor — **niri**, **Hyprland**, or **Sway**. The shim detects which one is running and speaks its IPC; the widgets themselves are compositor-agnostic. You only need the CLI for the compositor you actually run — `niri`, `hyprctl` (Hyprland), or `swaymsg` (Sway) — not all three.
- **[Claude Code](https://claude.com/claude-code)** — the `claude` agent being visualized. Optional if you're driving the widgets from another agent via [PROTOCOL.md](PROTOCOL.md).
- **`python3`** for the MCP shim (stdlib only, no pip installs)
- On the PATH as the shim's senses need them: `playerctl`, `nmcli`, `notify-send`, `ps`
- For the generic shell adapter (`hooks/pulse-emit`, only used when driving the widgets from a non-Claude agent): `tr` is required; `timeout` is optional — the adapter falls back to a direct dispatch when it's absent.

## Install

```sh
# clone and symlink into the plugins dir
ln -s "$PWD" ~/.local/share/noctalia/plugins/claude-companion

# enable the plugin
noctalia msg plugins enable lowcache/claude-companion
```

Then, in order:

1. **(Optional) Put the `pulse` widget on a bar** (Settings → Bar) for the glanceable dot — capture no longer depends on it; the headless `pulse-svc` service does the listening.
2. Add the `orb` desktop widget if you want the ambient presence.
3. Merge `hooks/settings.snippet.json` into `~/.claude/settings.json` so Claude's lifecycle hooks actually drive the pulse.
4. Point Claude at `shim/noctalia-mcp.py` with `--mcp-config` to hand it the senses and hands. (Sessions you launch through `/claude` do this for you.)
5. (Optional) Turn on the consent gate — see [Approving tools from the desktop](#approving-tools-from-the-desktop). It ships off; the hook in step 3 is inert until you set `consent_mode`.

Prove it works:

```sh
noctalia msg plugin lowcache/claude-companion:pulse-svc all needs_attention   # bar icon → red bell
noctalia msg plugin lowcache/claude-companion:pulse-svc all idle              # back to robot
```

> [!WARNING]
> **`pulse` no longer has to stay on a bar.** The sole aggregator is now the headless `pulse-svc` service, which starts with the shell and listens whether or not any widget is placed — so pulling the `pulse` dot off a bar just hides the glanceable icon; the orb keeps updating and hooks/IPC still land. This retires the old **D10** requirement, made possible by the `[[service]]` entry kind added in the Noctalia 5 beta.

## Usage

`/claude <task>` opens a real Claude Code session in your terminal, shim already wired in. Bare `/claude` picks up where you left off (`claude --continue`). And `/claude ? <question>` is the quick one — a read-only ask that comes back as a toast and lands, in full, in the answer panel.

That panel opens however you like it: click the pulse, use the "Show last answer" row under `/claude`, or toggle it from the CLI:

```sh
noctalia msg panel-toggle lowcache/claude-companion:answer
```

Leave it open and it refreshes live while suppressing the toast, so you're never reading the same answer twice. A click outside or Esc puts it away.

Hover the bar and the tooltip tells you where each session stands and what it's burning — input, output, cache reads. Run a few at once and you get a line per session plus a Σ total, with the icon always showing whichever one needs you most.

**Middle-click the pulse** to ask a one-off question without the launcher. Type, press Enter, done — no `/claude`, no `?` prefix to remember. It runs the same read-only quick-ask path as `/claude ? …`, and the answer arrives the same way: the answer panel plus a toast.

```sh
noctalia msg panel-toggle lowcache/claude-companion:ask
```

**Right-click the pulse** for the sessions panel — the same rollup, but you can act on it. A tooltip disappears on the way to it; this doesn't. One row per live session with its state, model and burn, and a **Retire** button on each.

Retire is there for the one failure mode you'll actually hit: a session whose `SessionEnd` hook never fired — terminal killed, hook interrupted mid-distill — sits at idle forever and keeps inflating the count. Retiring it corrects the tally from the shell, without going back to a terminal. It adds no new protocol: a retire is the ordinary `session_end` event carrying that session's id, exactly what `hooks/pulse.py` sends.

```sh
noctalia msg panel-toggle lowcache/claude-companion:sessions
```

## Settings

The plugin declares four user settings, read via `noctalia.getConfig(<key>)`:

| Setting | Type | Range | Step | Default | Description |
| --- | --- | --- | --- | --- | --- |
| `breath_speed` | double | 0.25–3.0 | 0.05 | 1.0 | Phase-rate multiplier for the breathing animation on both the bar dot and the desktop orb. Higher = faster. |
| `pulse_glow_floor` | double | 0.0–0.9 | 0.05 | 0.45 | How dim the bar dot gets at the trough of its breath. 0 = dims to black, higher = stays brighter. |
| `orb_swell` | double | 0.0–3.0 | 0.05 | 1.0 | How far the desktop orb glyph magnifies as it breathes. 0 = static size, higher = a bigger swing. |
| `consent_mode` | select | off / learn / enforce | — | `off` | The tool-consent gate. See [Approving tools from the desktop](#approving-tools-from-the-desktop). |

There are no color settings — both surfaces follow the active theme palette via accent role names (`secondary`, `primary`, `error`).

## Approving tools from the desktop

Everything above is observation: the pulse tells you Claude is blocked, and you go
find the terminal. The **consent gate** closes that loop — Claude asks, you answer on
the desktop, and the tool runs or doesn't. You never leave what you were doing.

It is **off by default** and should stay off until you have read this section, because
unlike the rest of the plugin it sits in the critical path of a tool call.

Set `consent_mode` in the plugin's settings:

| Mode | What happens |
| --- | --- |
| `off` | The hook exits immediately. Identical to not having it installed. |
| `learn` | Records what Claude runs. Never blocks, never prompts. |
| `enforce` | Anything not already allowlisted opens the consent panel and waits. |

**Start in `learn` for a few days of normal work.** It writes one line per gated tool
call to `$XDG_RUNTIME_DIR/claude-companion/learn.jsonl`, which is how the allowlist
gets seeded from traffic you actually produce instead of from anyone's guess about
what is safe. When it has seen enough:

```sh
python3 hooks/consent.py promote   # fold every observed command into the allowlist
```

Then switch to `enforce`. The commands you already run are silent from the first
enforced session; only something new stops to ask.

**What gets gated.** Only the mutating tools — the matcher in
`hooks/settings.snippet.json` is `Bash|Write|Edit|NotebookEdit`. Reads, greps and
globs are never gated and never invoke the hook at all. Widen or narrow it by editing
that matcher; it is your `settings.json`, not the plugin's.

**The panel** leads with Claude's own description of what the command is for, then the
command itself, then the cwd and session. Three answers: **Allow once**, **Always
allow** (appends to the allowlist), **Deny**. It opens itself when a request arrives and
closes when you answer; opening it by hand shows whatever is pending, or an empty state
when nothing is:

```sh
noctalia msg panel-toggle lowcache/claude-companion:consent
```

**Nothing here classifies anything.** The allowlist ships empty and only ever grows by
your explicit click, keyed on the *exact* command string. There is no pattern matching
and no shipped safelist, because a pattern is a security policy and shell composition
(`git status && rm -rf ~`) defeats one in a single line.

**If anything goes wrong, the gate gets out of the way.** Printing nothing is Claude
Code's "no decision, proceed normally", and every failure route takes it: Noctalia
offline (detected on dispatch, so it fails fast rather than waiting), no answer inside
the hook's 110s deadline, a response that doesn't echo the request nonce, a malformed
payload, an unhandled exception. In all of them Claude Code asks in the terminal
exactly as it did before. `tests/consent_spec.py` pins every one of those paths.

**Forgery.** Requests and responses live in `$XDG_RUNTIME_DIR` (0700, tmpfs, per-user)
at 0600, and each response must echo a nonce from its request. Without
`XDG_RUNTIME_DIR` the gate disables itself rather than fall back to a world-writable
`/tmp`, where any local process could drop an `allow` of its own.

> [!NOTE]
> The allowlist lives at `$XDG_STATE_HOME/noctalia/claude-companion/allow.jsonl` and is
> meant to persist. On an impermanent root, make sure that path is on your persist list
> or you will re-approve everything after each boot.

## Wiring up other agents

None of this is Claude-specific under the hood. The pulse speaks a plain event format and doesn't care who's talking — any agent, CI job, or shell script that can run a command on its own lifecycle can light up the same bar. [PROTOCOL.md](PROTOCOL.md) has the full eight-event vocabulary, the CSV payload, session semantics, and the adapter contract. The reference emitter, `hooks/pulse-emit`, is plain POSIX sh and needs nothing but `noctalia` on your PATH:

```sh
hooks/pulse-emit turn_start mysess
hooks/pulse-emit turn_end mysess gpt-5 12000 800
hooks/pulse-emit session_end mysess
```

## Rough edges

A few things worth knowing before they surprise you:

- Plugin panels render at `Layer::Top`, so an overlay window — a notification, a quake terminal, a polkit prompt — can sit on top of the answer panel. The answer's still there; clear the overlay and you'll see it. There's an upstream ask in for panel layer control.
- Eight-digit hex alpha is ignored by bar widgets — brightness is done by scaling RGB toward black. (Earlier builds didn't fire `state.watch` on bars, so the pulse polled; the Noctalia 5 beta fires it, so the bar dot is now event-driven like the orb.)
- Builtin and wallpaper-generated palettes have no on-disk JSON, so those fall back to fixed accent colors. Custom and community palettes are followed live, rechecked every ~8 s.
- Quick-ask rides headless `claude -p`, which doesn't refresh an expired OAuth login token — only an interactive session does ([upstream](https://github.com/anthropics/claude-code/issues/53063)). The plugin checks the token's expiry before launching and, instead of burning the request on a guaranteed 401, tells you to open a terminal Claude session first; a failure it couldn't predict gets the same message in place of the raw API error.
- The MCP shim is a Python prototype. A compiled port is the intended endgame.
- The shim's memory tool drops notes into `~/.memory/inbox` for the memd curator to pick up. No memd, no reader — the files get written and simply sit there. It follows memd's Inbox Protocol v1.0 (`INBOX-PROTOCOL.md` in the memd repo).

## License

MIT — see [LICENSE](LICENSE).
