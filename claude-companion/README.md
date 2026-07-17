# Claude Companion

![Claude Companion — a Claude Code companion for Noctalia: pulse, orb, and answer panel](thumbnail.webp)

A Noctalia v5 plugin that puts [Claude Code](https://claude.com/claude-code)'s live status on your desktop — a **pulse** on the bar, a breathing **orb** on the desktop, and an **answer panel** for quick questions.

![version](https://img.shields.io/badge/version-1.0.0-blue) ![license](https://img.shields.io/badge/license-MIT-informational) ![noctalia](https://img.shields.io/badge/noctalia-5.0.0-blueviolet)

Claude Code is a brilliant agent trapped in a text box. It can't see the windows you have open, can't tap you on the shoulder when it hits a wall, and gives you nothing to glance at while it churns. So you sit there watching a terminal, or you wander off and miss the moment it needed you.

This plugin gives it a body. It wires Noctalia into Claude's lifecycle so a **pulse** on your bar tracks every session, an **orb** on your desktop breathes along with the work, and an **answer panel** catches one-shot replies before they scroll away. The terminal keeps doing the actual thinking — permissions, tools, MCP, all native. This is just the nervous system that lets the rest of your desktop feel it.

Don't run Claude Code? The signal bus is agent-agnostic — any agent, CI job, or shell script that can run a command on its own lifecycle can light up the same bar. See [Wiring up other agents](#wiring-up-other-agents).

## Plugin

| Field | Value |
| --- | --- |
| ID | `lowcache/claude-companion` |
| Entries | Bar widget: `pulse`; desktop widget: `orb`; panel: `answer`; launcher: `claude` |
| Launcher Prefix | `/claude` |

Built and live-tested against Noctalia 5.0.0 (build `623210223c`), with an offline spec suite (`tests/shim_spec.py`) pinning the shim's compositor seam and its injection guards.

## See it

![The bar pulse and desktop orb breathing through a Claude session's lifecycle](assets/pulse.gif)

One session, start to finish: the **pulse** on the bar and the **orb** on the desktop breathe through idle, thinking, a tool run, done, and needs-you.

![A quick question answered in the answer panel](assets/question.gif)

Ask something quick with `/claude ?` and the whole answer waits for you in the panel, instead of scrolling off the top of the terminal.

## How it works

**Perceive.** `shim/noctalia-mcp.py` is a stdio MCP shim that hands Claude a live read on your machine: your compositor's IPC for the windows you have open (it detects and speaks niri, Hyprland, or Sway), `playerctl` for what's playing, `noctalia msg status` for the state of the shell itself. Nothing to wire up by hand. Launch through `/claude` and it attaches itself.

**Practice.** Everything on the backend funnels through `claude.luau`, the `/claude` launcher and the one door in. It normalizes the event vocabulary, throws `notify-send` toasts, and calls `noctalia msg` to move panels around. One chokepoint on purpose — so when something acts up, there's exactly one place to go look.

**Pulse.** `pulse.luau` sits on your bar and runs the show. Hook events land here over IPC, and from there it does the rest: tracks every session at once, surfaces whichever one's most urgent, breathes in your accent color, and mirrors the rollup into `noctalia.state` under `claude.pulse` for anyone downstream to read.

And downstream is where the quiet parts live. `orb.luau` is pure view. It subscribes to `claude.pulse` and breathes the same state frame by frame, glyph and opacity riding a sine wave, tempo picking up as things get urgent — no hooks, no logic of its own, just a reflection. `answer.luau` is the `answer` panel that catches a `/claude ?` reply and holds the whole thing: wrapped, scrollable, all the parts a toast lops off the end.

## Requirements

- **Noctalia 5.0.0** on a supported Wayland compositor — **niri**, **Hyprland**, or **Sway**. The shim detects which one is running and speaks its IPC; the widgets themselves are compositor-agnostic. You only need the CLI for the compositor you actually run — `niri`, `hyprctl` (Hyprland), or `swaymsg` (Sway) — not all three.
- **[Claude Code](https://claude.com/claude-code)** — the `claude` agent being visualized. Optional if you're driving the widgets from another agent via [PROTOCOL.md](PROTOCOL.md).
- **`python3`** for the MCP shim (stdlib only, no pip installs)
- On the PATH as the shim's senses need them: `playerctl`, `nmcli`, `notify-send`, `ps`

## Install

```sh
# clone and symlink into the plugins dir
ln -s "$PWD" ~/.local/share/noctalia/plugins/claude-companion

# enable the plugin
noctalia msg plugins enable lowcache/claude-companion
```

Then, in order:

1. **Put the `pulse` widget on a bar** (Settings → Bar). Read the warning below first — this one isn't optional.
2. Add the `orb` desktop widget if you want the ambient presence.
3. Merge `hooks/settings.snippet.json` into `~/.claude/settings.json` so Claude's lifecycle hooks actually drive the pulse.
4. Point Claude at `shim/noctalia-mcp.py` with `--mcp-config` to hand it the senses and hands. (Sessions you launch through `/claude` do this for you.)

Prove it works:

```sh
noctalia msg plugin lowcache/claude-companion:pulse all needs_attention   # bar icon → red bell
noctalia msg plugin lowcache/claude-companion:pulse all idle              # back to robot
```

> [!WARNING]
> **`pulse` has to stay on a bar.** It's the sole aggregator — the one piece that hears the hooks and publishes the state everything else reads. Noctalia only runs bar widgets while they're placed on a bar, so the moment you pull `pulse` off, the plugin goes dark. The hooks keep firing into the void, the orb freezes on its last breath, and IPC pokes do nothing. If that happens, the fix is always the same: put `pulse` back on a bar.

## Usage

`/claude <task>` opens a real Claude Code session in your terminal, shim already wired in. Bare `/claude` picks up where you left off (`claude --continue`). And `/claude ? <question>` is the quick one — a read-only ask that comes back as a toast and lands, in full, in the answer panel. Read-only is enforced, not assumed: the ask launches with no built-in tools, no MCP servers, and none of your Claude settings (so no hooks, plugins, or pre-authorized permissions), leaving it nothing but the model and your question.

That panel opens however you like it: click the pulse, use the "Show last answer" row under `/claude`, or toggle it from the CLI:

```sh
noctalia msg panel-toggle lowcache/claude-companion:answer
```

Leave it open and it refreshes live while suppressing the toast, so you're never reading the same answer twice. A click outside or Esc puts it away.

Hover the bar and the tooltip tells you where each session stands and what it's burning — input, output, cache reads. Run a few at once and you get a line per session plus a Σ total, with the icon always showing whichever one needs you most.

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
- Bar widgets don't fire `state.watch` callbacks in Noctalia 5.0.0, so the plugin polls instead. Eight-digit hex alpha is ignored too — brightness is done by scaling RGB.
- Builtin and wallpaper-generated palettes have no on-disk JSON, so those fall back to fixed accent colors. Custom and community palettes are followed live, rechecked every ~8 s.
- Quick-ask rides headless `claude -p`, which doesn't refresh an expired OAuth login token — only an interactive session does ([upstream](https://github.com/anthropics/claude-code/issues/53063)). The plugin checks the token's expiry before launching and, instead of burning the request on a guaranteed 401, tells you to open a terminal Claude session first; a failure it couldn't predict gets the same message in place of the raw API error.
- The MCP shim is a Python prototype. A compiled port is the intended endgame.
- The shim's memory tool drops notes into `~/.memory/inbox` for the memd curator to pick up. No memd, no reader — the files get written and simply sit there. It follows memd's Inbox Protocol v1.0 (`INBOX-PROTOCOL.md` in the memd repo).

## License

MIT — see [LICENSE](LICENSE).
