# Provider brand marks

Coverage is the 29 quota provider IDs in Token Monitor **0.68.0**
([catalog source](https://github.com/Javis603/token-monitor/blob/v0.68.0/src/shared/limits/providers.js)).
This is the quota catalog, not the separate usage-client catalog.
`providers.json` records the IDs, shared brands, aliases and third-party adapters.

| Provider ID | Display name | Brand asset |
| --- | --- | --- |
| `claude` | Claude | `claude.svg` |
| `codex` | Codex | `openai.svg` |
| `opencode` | OpenCode | `opencode.svg` |
| `cursor` | Cursor | `cursor.svg` |
| `antigravity` | Antigravity | `antigravity.svg` |
| `cline` | Cline | `cline.svg` |
| `factory` | Factory Droid | `factory.svg` |
| `kimi` | Kimi | `kimi.svg` |
| `grok` | Grok | `grok.svg` |
| `copilot` | GitHub Copilot | `githubcopilot.svg` |
| `zed` | Zed | `zed.svg` |
| `commandcode` | Command Code | `commandcode.svg` |
| `mimo` | Xiaomi MiMo | `xiaomi.svg` |
| `zai` | GLM | `zai.svg` |
| `zaiteam` | GLM Team | `zai.svg` |
| `kiro` | Kiro | `kiro.svg` |
| `workbuddy` | WorkBuddy | `workbuddy.svg` |
| `qoder` | Qoder | `qoder.svg` |
| `deepseek` | DeepSeek | `deepseek.svg` |
| `devin` | Devin | `devin.svg` |
| `minimax` | Minimax | `minimax.svg` |
| `typesafe` | TypeSafe | `typesafeai.svg` |
| `openrouter` | OpenRouter | `openrouter.svg` |
| `volcengine` | Volcengine | `volcengine.svg` |
| `ollama` | Ollama | `ollama.svg` |
| `trae` | Trae CN | `trae.svg` |
| `alibaba` | Alibaba Cloud | `alibabacloud.svg` |
| `stepfun` | StepFun | `stepfun.svg` |
| `thirdparty` | Third-party APIs | Native `plug-connected` glyph |

Third-party accounts keep `provider: thirdparty`; the documented `adapterId`
selects New API (`newapi-account` / `newapi-token`) or Sub2API (`sub2api`).
Custom, absent or unrecognized adapters retain the generic plug. This follows
Token Monitor's [provider presentation](https://github.com/Javis603/token-monitor/blob/v0.68.0/src/electron/renderer/limits/providerPresentation.js)
and the field retained by its public limits response. Adapter selection never
changes the provider/account identity or request destination.

The presentation aliases `droid → factory`, `zcode → zai`, `qodercn → qoder`,
`dsh → deepseek`, and `mcode → minimax` come from the same upstream catalog.
Aliases do not rewrite Hub payloads. Unknown future provider IDs keep their
original label and the native cloud fallback.

## Sources and licensing

26 unmodified monochrome SVGs come from
[Lobe Icons](https://github.com/lobehub/lobe-icons) revision
`4a8f668e23d98759555288505aec3c895a539b2f`, under the included
`LOBE-ICONS-LICENSE.txt` (MIT).

Factory Droid, Zed and Xiaomi come from
[Token Monitor v0.68.0](https://github.com/Javis603/token-monitor/tree/v0.68.0/assets/icons),
under `TOKEN-MONITOR-LICENSE.txt` (MIT). MiMo uses the Xiaomi symbol used by
Token Monitor; its text logo is unreadable in the small bar slot. GitHub Copilot
uses the GitHub robot, and GLM / GLM Team share Z.ai's mark.
`newapi.svg` and `sub2api.svg` are also Lobe assets.

`sources.json` records the exact source path, revision and SHA256 for each of
29 original SVGs. Brand names and trademarks remain their respective owners'
property; the source licenses do not grant trademark rights. Antigravity's
silhouette also matches Google's [one-color press mark](https://www.antigravity.google/press).

## Native rendering

`provider-icons-<fingerprint>.ttf` contains 29 brand glyphs plus an empty missing-glyph slot.
Noctalia's native image control cannot tint SVGs; a small local font allows the
marks to follow the existing theme and quota-warning colors. Both bar (15px)
and card (20px) retain fixed square slots and ink-centered vertical alignment.
Original square viewBoxes and shape proportions are preserved; cubic curves
become quadratic font outlines within 0.5/1000 em. Opacity and source color are
flattened into a single theme color (including Qoder, Volcengine and Zed).

DeepSeek and Antigravity retain U+E001 and U+E002. The reviewed static mapping
is `lib/providers.luau`; both the filename and family include a source fingerprint. Noctalia caches
registered fonts by path, so changing only the family does not refresh an
already registered file. A new filename distinguishes changed font content
during plugin updates. The plugin loads the bundled font through Noctalia's process-local `loadFont` API. No runtime asset
download, font installation, generation, dependency or extra write is needed.

Regenerate with Python and `fontTools`:

```sh
python3 tools/build-provider-font.py
```

The development environment uses the pinned Nix `python3.withPackages
(p: [ p.fonttools ])`. Output is byte-identical for unchanged source and tool
versions. Font and SVGs ship with the plugin; unrelated interface icons remain
Noctalia's native glyphs.
