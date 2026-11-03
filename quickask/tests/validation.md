# QuickAsk 0.2.0 — OpenAI-compatible validation

Date: 2026-10-23 (Europe/Istanbul).

## Change and scope

OpenCode Go remains the default, using the existing endpoint, DeepSeek V4.1 Flash non-reasoning request and unchanged Secret Service attributes. An explicitly selected OpenAI-compatible mode adds a full HTTPS Chat Completions endpoint and user-selected model through Noctalia's native settings. Compatible requests use only model/messages/stream, Bearer authentication and SSE text deltas; Go-specific session/thinking fields are excluded. No provider is selected automatically after an error. General-chat permission for Go is not established by this project; catalog hosting implies no endorsement. The README retains this limitation and provider requirements.

Each compatible credential is looked up with application=quickask, provider=openai-compatible and endpoint=<exact full URL>. A changed URL requires a separately stored key. URLs reject HTTP, userinfo, query/fragment and control characters before any lookup. The connection displayed at opening is retained through submit/retry; changing settings requires reopening. Keys never enter plugin settings, argv values, UI errors, logs or files. The only subprocess is argv-based secret-tool lookup. No new runtime dependency, backend, daemon, history, audio, uploads or agent was added.

Version: 0.2.0. Minimum Plugin API: 24, unchanged. Native host: Noctalia 5.3.0 (5.3.0-1-dirty), CachyOS noctalia 5.3.0-1.1, host API34. Legacy noctalia-shell and system packages were not changed. Community ID: yusuferdemyamali/quickask; local ID: local/quickask.

## Automated results

- 81 production-source Luau mock cases passed in both the community and local workspace bundles. The original 44 regression cases remain covered. New coverage includes explicit provider selection, standard compatible JSON/headers, Go preservation, endpoint/model rejection, credential isolation per URL, no fallback, connection snapshots before submit and during async lookup/retry, cancellation on Settings, HTTP errors and timeout.
- English/Turkish catalogs have matching keys and interpolation placeholders; Turkish is a core-supported locale. English remains the fallback. Turkish strings were also inspected in the native interface; publisher language review is still needed for the PR attestation.
- All four production Luau files compiled with the official Luau CLI (temporary local build; no system install).
- Noctalia lint: 0 errors, 0 warnings for both IDs.
- Current upstream validation: 278 manifests passed; 101 workflow unit tests passed using the workflow's pinned PyGithub 2.9.1 in an isolated temporary venv. These unit tests simulate PR events; they did not change any remote PR.
- Impeccable static UI scan: no findings. git diff --check: clean.
- Real idle screenshot: 520x380. thumbnail.webp regenerated through Noctalia's official generator: 960x540. Screenshots contain no user question or credential. Publication paths and secret-pattern review found no personal paths or real keys.

## Native results and limits

- PASS: local/quickask 0.2.0 enabled and rendered on native Noctalia/Hyprland. Terminal panel-toggle opened a single native panel and closed it; status transitions were verified after the host processed the event.
- PASS: bottom-center 520x380 content, themed controls, input focus outline, provider/model status and Settings gear are visible. Host shadow produces an outer 548x410 surface on the scale1 HDMI monitor.
- PASS: settings-open-plugin opens the native QuickAsk settings dialog; Go provider label/description are localized.
- PASS (native configuration fixture): temporarily changing only the unsaved local manifest default exposed compatible URL/model fields and the safe missing-model error. This fixture did not read keys or make HTTP calls. The exact original manifest was restored afterwards.
- PASS: Noctalia's persistent settings bytes match the pre-upgrade backup. Existing theme, enabled plugins and shortcut configuration were preserved. Hyprland config errors are empty; Noctalia retains its same 7 pre-existing configuration warnings.
- PARTIAL: Settings-button cancellation, Enter/Shift+Enter, clipboard, scroll, late callbacks and transport faults are covered by source mocks; historical native evidence belongs to the previous version. These interactions were not all repeated on 0.2.0.
- BLOCKED / NOT RUN: no live OpenAI-compatible inference, real generic credential lookup, provider billing/model access, TLS failure or real transport cancellation was tested. No key was read and no live request was sent in this update. Do not treat mock/native-layout success as proof that a specific service/model accepts the request or permits the intended use.

## Artifacts and publication

Source, settings, English/Turkish translations, README, mocks, real screenshot and official thumbnail were updated. The community feature branch is feat/quickask-openai-compatible, based on upstream/main after PR1126 was merged. Only quickask/ is changed; catalog.toml and other plugins are untouched. No new push or pull request has been performed for this update. Publication requires the user's approval and truthful template attestations; live verification requires a separately authorized account/key/request.

References: https://docs.noctalia.dev/noctalia/plugins/development/manifest/ ; https://docs.noctalia.dev/noctalia/plugins/development/runtime-api/ ; https://docs.noctalia.dev/noctalia/plugins/development/plugin-api/ ; https://developers.openai.com/api/reference/resources/chat ; https://opencode.ai/docs/go/ .
