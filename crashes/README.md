# Crashes

Crash history for your desktop, read from systemd-coredump, with one-click AI
diagnosis. When one of *your* processes segfaults or dumps core you get a
critical notification, and the panel keeps the list around afterwards — so a
crash you missed while watching a video is still there when you come back to
it. A second tab shows the current boot's journal errors by severity.

## Plugin

| Field | Value |
| --- | --- |
| ID | `umedbazarov/crashes` |
| Entries | Panel: `panel`; service: `service` |

## Requirements

- `coredumpctl` (systemd-coredump) active and collecting — the default on
  Arch and most systemd distributions; verify with `coredumpctl list`.
- `jq`, required — filters the coredump list to your own crashes outside the
  plugin runtime.
- `notify-send` (libnotify), required for the crash notifications.
- `bash`, required — runs the diagnosis command.
- A terminal AI coding agent for the diagnosis buttons (Claude Code, Codex,
  opencode, grok, …). Without one the panel still works as a crash and error
  browser; the diagnosis button then explains what to install.

  Whichever of those are installed are tried in turn: before the window
  opens the agent is asked a throwaway question, and one that cannot answer
  — out of quota, logged out, offline — is skipped in favour of the next.
  You see which was chosen in the terminal itself. Turn that check off with
  **Check the agent can answer** if you would rather not spend the request,
  and set the order with **Agent order**. A configured **Agent command** is
  used on its own: its headless syntax is unknown, so it cannot be tested
  the same way.
- `gdb` and your distribution's debuginfod are optional, but the guide the
  agent follows uses them to symbolize a backtrace when they are available.

## Usage

The plugin has no bar widget. Open the panel from the plugin's row in
Settings, or bind it in your compositor:

```sh
noctalia msg panel-toggle umedbazarov/crashes:panel
```

**Crashes** lists the coredumps of your own processes, newest first: program,
signal, time, PID, and whether the core file still exists (rotated-away dumps
are marked and cannot be analyzed). Each row has two buttons:

- **Diagnose** (stethoscope) opens your agent in a terminal with the recorded
  facts and `diagnose.md`, an evidence-first investigation guide: read
  `coredumpctl info`, rule out OOM kills, correlate the timestamp with
  filesystem mtimes, the journal and recent package updates, symbolize the
  backtrace with gdb + debuginfod, and report honestly — including what the
  evidence does *not* show. The guide explicitly tells the agent to leave the
  system as it found it.
- **Mute** (bell) stops notifications for that one program; press it again to
  unmute. Mutes are kept in the plugin's data directory.

**Errors** shows this boot's journal entries at a chosen severity — `err` and
stricter by default, up to `emerg` only — with the same diagnosis button per
entry, which asks the agent to pull the surrounding journal context and
explain what the message means and how serious it is.

Only your own crashes are listed (matched by uid): a system daemon dumping
core is a sysadmin's problem, not a desktop notification.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `poll_seconds` | `int` | `20` | How often the coredump list is re-read. |
| `notify` | `bool` | `true` | Announce new crashes with a critical notification. Turn off if something else already announces them. |
| `agent_cmd` | `string` | *(empty)* | Command that receives the prompt as its last argument, e.g. `claude`, `codex`, `opencode --prompt`. Empty: pick from the known agents (see below). |
| `agent_order` | `string` | *(empty)* | Which known agents to try and in what order, e.g. `codex, claude`. Empty: claude, opencode, codex, grok. |
| `probe_agent` | `bool` | `true` | Check that the agent can answer before opening it, and move on to the next one if it cannot. |
| `extra_prompt` | `string` | *(empty)* | Text appended to every prompt — e.g. "Answer in German", or house rules for the agent. |
| `terminal_cmd` | `string` | `kitty -e` | Wrapper that opens the agent in a window. Leave empty if your agent command opens its own window. |
| `env_file` | `string` | *(empty)* | Sourced before the agent starts. For a proxy or an API key your shell profile sets but a panel click does not inherit. |

## IPC

```sh
noctalia msg plugin umedbazarov/crashes:service all refresh
```

Re-reads the coredump list immediately instead of waiting for the next poll.

## Notes

- **Commands spawned.** `coredumpctl list --json=short` piped through `jq`
  (the crash list), `id -u` once at startup (only your uid's crashes are
  shown), `journalctl -b -p <level> -o json` piped through `jq` for the
  Errors tab — and only when that tab is open, `notify-send` for
  notifications, and `setsid bash -c …` to launch the agent in a terminal
  when you press a diagnosis button. Nothing runs an agent on its own.
- **Files written.** Only in the plugin's data directory: `seen.json` (the
  newest crash already announced, so a restart does not re-announce old
  ones) and `mutes.json` (the per-program mute list).
- **No privileges.** Everything runs as your user; the plugin never modifies
  system configuration and never touches the dumps themselves.
- **What is sent to the agent.** The crash facts shown in the row (program,
  PID, binary path, signal, time) or the journal line you clicked, plus the
  path to the bundled guide. Whatever the agent then reads is up to it and
  your agent's own permissions — the guide keeps it to read-only
  investigation, and warns that a core dump is a verbatim copy of process
  memory that may contain secrets.
- **Budget-friendly.** Filtering happens in `coredumpctl`/`jq` outside the
  Luau runtime, at most 30 rows are parsed per poll, and the Errors tab is
  only queried on request.

## License

MIT.
