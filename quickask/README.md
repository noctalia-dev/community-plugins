# QuickAsk

A small, keyboard-first text panel for streaming responses through OpenCode Go.
Each opening is one independent question: close and reopen to start fresh.
The panel uses Noctalia's native controls, theme, Markdown and clipboard support.

## Plugin

| Field | Value |
| --- | --- |
| ID | `yusuferdemyamali/quickask` |
| Entries | Panel: `panel` |
| License | MIT |

## Requirements

- Native Noctalia v5 with **Plugin API 24 or later**. This is a Luau plugin, not a legacy QML/Quickshell plugin. API 24 is needed for safe argv-form process execution; the panel and Markdown use earlier APIs.
- **`secret-tool`** on `PATH` (provided by `libsecret` on Arch Linux).
- A running, unlocked Linux Secret Service, such as GNOME Keyring, KWallet with Secret Service enabled, or KeePassXC with Secret Service integration.
- An OpenCode Go subscription/key with access to **DeepSeek V4.1 Flash**. In Go Console, **Settings → Privacy → Regions → Global** must allow this model. QuickAsk does not change account privacy settings.
- A Wayland compositor supported by Noctalia. Tested on Hyprland; the shortcut below is optional and compositor-specific.

### Provider suitability

[OpenCode Go's documentation](https://github.com/anomalyco/opencode/blob/dev/services/www/src/docs/content/console/go.mdx#where-can-i-use-it) describes Go as intended for OpenCode and other coding agents, and asks clients to send typical coding-agent traffic.
QuickAsk is a standalone question-and-response panel, **not** a coding agent or an OpenCode-validated client.
Technical API compatibility and a user's personal confirmation do not establish blanket permission for general-purpose chat or an endorsement by OpenCode.
Verify that your intended use is permitted for your account before sending a question. Provider clarification for public general-purpose use remains outstanding; no alternative provider, client impersonation or restriction bypass is included.

### Store your key

Run this command in your own terminal and enter the key at the hidden prompt:

```sh
secret-tool store --label='QuickAsk OpenCode Go' application quickask provider opencode-go
```

Keep the key out of command arguments, shell history, configuration, `.env` files, screenshots and bug reports. Unlock your keyring first. QuickAsk has no password input field.
To delete the stored key:

```sh
secret-tool clear application quickask provider opencode-go
```

The lookup attributes are unchanged from the local MVP, so an existing QuickAsk key can be reused.

## Usage

Install and enable **QuickAsk** from Noctalia's community plugin store once it is published. This submission has not been merged or published yet.

For a checkout before publication, run this from its repository root. The symlink name must be unused; `ln -sT` refuses to overwrite an existing installation:

```sh
plugin_root="${XDG_DATA_HOME:-$HOME/.local/share}/noctalia/plugins"
mkdir -p "$plugin_root"
ln -sT "$PWD/quickask" "$plugin_root/quickask-publication"
noctalia msg config-reload
noctalia msg plugins enable yusuferdemyamali/quickask
```

Open or close the panel:

```sh
noctalia msg panel-toggle yusuferdemyamali/quickask:panel
```

The 520×380 logical-pixel panel appears at the bottom center of the focused monitor. Input receives focus automatically.

- **Enter** sends; **Shift+Enter** inserts a new line. Empty or whitespace-only input is rejected.
- A response streams as Markdown, including code blocks. The bounded answer area follows new output until you scroll away.
- **Stop** cancels the active operation and preserves received text. **Copy response** copies only the assistant's raw text/Markdown after completion, error or stop.
- **Retry** manually retries the same question after an error. There is no automatic retry or conversational continuation.
- **Escape**, an outside click or the close button closes the panel and cancels the operation. Reopening starts blank. Opening alone makes no network request.

All UI and error strings use `noctalia.tr` with an English catalog. Other locales can be maintained through Noctalia Translate; this submission includes only `translations/en.json`.

### Optional Hyprland shortcut

Check for an existing **SUPER+A** binding before adding one. Back up your configuration; keep existing bindings and theme settings.
For Hyprland's Lua configuration, add:

```lua
hl.bind("SUPER + A", hl.dsp.exec_cmd("noctalia msg panel-toggle yusuferdemyamali/quickask:panel"))
```

On the tested Hyprland version, reload with `hyprctl reload config-only` and inspect `hyprctl configerrors`.
For a system actually using the traditional configuration instead:

```ini
bind = SUPER, A, exec, noctalia msg panel-toggle yusuferdemyamali/quickask:panel
```

If upgrading the local MVP, replace its old `local/quickask:panel` shortcut target with the published ID, and disable the old plugin after verifying the new one. Do not add a second binding for the same key.

## IPC

```sh
noctalia msg panel-toggle yusuferdemyamali/quickask:panel
noctalia msg panel-close yusuferdemyamali/quickask:panel
```

There are no additional IPC events, settings, widgets, services or launcher providers.

## Notes

### Network, processes and privacy

Each explicit question or manual retry sends one HTTPS POST to:

```text
https://opencode.ai/inference/go/openai/v1/chat/completions
```

The fixed model is `deepseek-v4.1-flash`, with top-level `thinking: {"type":"disabled"}` for non-reasoning mode. Requests contain a short system instruction, the entered question and `stream: true`. No previous questions, clipboard contents, files, images or desktop context are sent.
QuickAsk sends its own `User-Agent: quickask/0.1.1`, the bearer credential, and a new `x-opencode-session` per independent question (stable for manual retries). It does not impersonate a validated client. TLS verification remains enabled; redirects are not followed.

The only spawned command is the direct argv form of `secret-tool lookup application quickask provider opencode-go`; no shell is used. Captured stdout/stderr are never logged or shown. Credentials are held only as short-lived in-memory references. HTTP error bodies and headers are not surfaced or logged.

There are no plugin filesystem reads/writes apart from Noctalia loading the shipped scripts/catalog, and no on-disk conversation history. Secret Service manages credential persistence. Copying uses Noctalia's clipboard API; your clipboard manager can independently retain copied text. The Noctalia host may persist plugin enablement/settings as usual.

Only one request is active per panel. Generation checks ignore callbacks after stop, close or retry. There is a 45-second inactivity watchdog, a 180-second total watchdog and a 256 KiB answer limit. Partial responses survive interrupted streams while the panel remains open. Missing/locked credentials, HTTP failures and connection errors show local, actionable messages without raw provider output.

### Validation and limitations

- 44 deterministic tests execute the actual shipped Luau modules against a mocked Noctalia host, including serialized model/thinking fields, Unicode/escaping, SSE, HTTP errors, cancellation races, credential failures and clipboard failures.
- Tested native host: Noctalia 5.3.0 / API 34 on Hyprland. Native panel focus, keyboard behavior, dismissal, two-monitor placement and the English publication panel were checked. The screenshot shows the actual English idle panel; it is not a rendered mockup or an inference result.
- Prior local MVP validation included one successful GLM live stream. **The current DeepSeek model has not been live-tested.** Publication preparation sends no inference requests and does not read a real credential.
- Prior clipboard, long-answer scrolling and stop UI checks used deterministic data inside the native host. Real HTTP cancellation/fault/timeout cases and callback races are covered by mocks, not claimed as complete native validation.
- Light theme, fractional scaling and other compositors have not been validated.

Development checks (Python 3.11+ and official Luau CLI are test tools only):

```sh
noctalia plugins lint quickask
luau-compile --null quickask/panel.luau quickask/lib/api.luau quickask/lib/credentials.luau
python3 quickask/tests/run.py --runtime /path/to/luau
```

The test-only JSON codec is rxi/json.lua 0.1.2, commit `dbf4b2dd2eb7c23be2773c89eb059dadd6436f94`, MIT; its notice is in `tests/vendor/LICENSE`. Production uses `noctalia.json`. The test harness injects module globals and English translations; it does not prove the native loader/JSON codec or access the network/keyring.

### Troubleshooting and removal

- Plugin held back: update native Noctalia to API 24+; do not lower `plugin_api` or substitute a shell-based credential lookup.
- Key not found: check `secret-tool`, Secret Service availability/unlocked state and the exact store attributes above. Never print the lookup result for debugging.
- HTTP 401/403: check the key, subscription, model region permissions and permitted use; 429: wait before manually retrying.
- No panel: confirm the plugin is enabled and use the exact IPC ID above. Check shortcut conflicts separately.
- A stopped or interrupted answer remains copyable. Close/reopen for another question.

To remove QuickAsk, close the panel, disable/uninstall `yusuferdemyamali/quickask` in Noctalia and remove only the shortcut you added. For a development installation, remove only the `quickask-publication` symlink you created; keep the source checkout. Clearing the Secret Service entry is optional and also affects a local MVP using the same attributes. No system packages or theme changes are required by this plugin.

![QuickAsk running in Noctalia](screenshot.png)
