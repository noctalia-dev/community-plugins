# Changelog

## 0.2.0

- Replace generated animation packs with the shared native procedural vector orb renderer across the bar, panel, and desktop widget. No first-run frame generation or image-asset cache is required; reduced-motion and presentation settings remain supported.
- Add bounded tool-activity feeds with recorded operation results and explicit unknown states when completion cannot be established.
- Add verified owning-terminal focus for Niri and Hyprland, with same-user process/window ownership checks and explicit unavailable or ambiguous results instead of duplicate launches.
- Add removable file and full-screen screenshot drafts to writable panel and desktop chat, with bounded attachment sizes and negotiated ACP context support. Attachments are submitted only with Send.
- Expose actual ACP permission requests and structured questions in managed turns, with request-bound responses and explicit decline/cancel controls. Terminal-owned sessions, recent activity, and attention views remain read-only.
- Discover six harnesses: Oh My Pi, Hermes Agent, Claude Agent, Codex, Gemini CLI, and OpenCode. Gate actions on installation and supported capabilities; authentication and negotiated features depend on each installed harness.
- Document entry roles, optional commands, compositor and harness limits, local state/cache writes, and provider/network delegation. Agentik has no hosted backend or telemetry; harnesses and OMP quota queries may contact configured providers.

The plugin ID remains `notfinaldev/agentik`; minimum Noctalia plugin API remains 24.
