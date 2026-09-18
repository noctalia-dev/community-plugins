# Nix Status

Nix Status is a Noctalia plugin that monitors the active NixOS generation, compares system closures, reports when a configured system differs from the active system, and updates configured flake inputs.

## Plugin

| Field | Value |
| --- | --- |
| ID | `mindnbytes/nix-status` |
| Entries | Bar widget: `status`; panel: `details`; service: `service` |

## Requirements

Nix Status is intended for NixOS and requires `nix` and `readlink` on `PATH`. Configured-system checks and input updates also require a Nix flake.

## Usage

1. Enable **Nix Status** in Noctalia and add the `status` widget to a bar.
2. Open the `details` panel by clicking the widget.
3. Open the plugin settings from the panel and set **Flake directory** to the directory containing your `flake.nix`.
4. To monitor whether switching would activate a different system, set **NixOS configuration** to the matching `nixosConfigurations` name from that flake, such as `vm`.

An empty **Flake directory** disables input updates and configured-system checks. Generation checks and closure comparisons continue to work. An empty **NixOS configuration** disables only the configured-system check.

Open the panel directly with:

```sh
noctalia msg panel-toggle mindnbytes/nix-status:details
```

The widget displays:

- `↻` when `/run/booted-system` differs from `/run/current-system`, indicating that a reboot would activate the current generation.
- `⇧` when the evaluated configured system differs from `/run/current-system`, indicating that a different system could be built and switched to.
- Both markers when both conditions apply.

The logo separately reflects the most recent flake-input update status. The widget uses Noctalia's built-in `snowflake` glyph by default, so no logo files or template configuration are required.

The panel provides controls to:

- Refresh the generation status.
- Compare the booted and current system closures on demand.
- Refresh the configured-system comparison.
- Update the configured flake's inputs.
- Open the plugin settings.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `flake_dir` | `folder` | Empty | Directory containing `flake.nix`. Required for input updates and configured-system checks. |
| `nixos_configuration` | `string` | Empty | Attribute name under `nixosConfigurations` to evaluate, such as `vm`. An empty value disables configured-system checks. |
| `use_themed_logos` | `bool` | `false` | Uses optional cache-rendered NixOS logo templates instead of the built-in `snowflake` glyph. |

After upgrading from a manifest version without these settings, disable and re-enable the plugin if they do not appear.

## Optional themed NixOS logos

The bundled templates preserve Noctalia palette colors: `on_surface` for normal status, `primary` for updated inputs, and `error` for failed updates.

1. Copy `assets/nix-logo.toml` into the root of your Noctalia configuration directory, normally `~/.config/noctalia/`.
2. Copy the three SVG files from `assets/templates/` into `$XDG_CONFIG_HOME/noctalia/templates/`, normally `~/.config/noctalia/templates/`. Preserve existing customized files rather than overwriting them blindly.
3. Apply the registered templates:

   ```sh
   noctalia msg templates-apply
   ```

4. Enable **Use themed NixOS logos** in the plugin settings.

Noctalia normally loads all root-level `*.toml` configuration files automatically. If you use `[include]` with `autoload = false`, explicitly include `nix-logo.toml` in your existing configuration. If Noctalia's configuration directory is outside `XDG_CONFIG_HOME`, adjust the TOML input paths accordingly.

The registration file renders logos under `$XDG_CACHE_HOME/noctalia/`, falling back to `~/.cache/noctalia/`. The widget watches the selected SVG for changes, so applying templates refreshes its colors. If a selected logo is missing, empty, or a directory, the widget falls back to the state-colored `snowflake` glyph and checks again during subsequent updates. A nonempty malformed SVG cannot be detected by this fallback; regenerate it or disable themed logos.

The plugin never installs template files or runs `templates-apply` automatically. Disabling **Use themed NixOS logos** returns to the built-in glyph on the next widget update without removing the user's template setup.

## Notes

### Processes, network access, and filesystem behavior

The service runs the following commands:

- `readlink -f /run/booted-system /run/current-system` to compare the booted and current generations.
- `nix store diff-closures` to compare their closures.
- `readlink -f /run/current-system` followed by `nix eval --raw --no-update-lock-file` to compare the active system with the configured flake output.
- `nix flake update --flake FLAKE_DIR` when the user explicitly requests an input update.

Generation and configured-system checks read `/run/booted-system`, `/run/current-system`, and the configured flake. Automatic evaluation uses `--no-update-lock-file` and does not intentionally modify `flake.lock`. Nix evaluation may still access substituters or flake sources according to the user's Nix configuration.

An explicit input update may access the network and modifies the configured flake's `flake.lock`; it therefore requires write access to the flake directory. The plugin parses the command output to report changed inputs. Running it again with no newer inputs reports that all inputs are up to date.

The optional logo integration reads SVGs rendered into Noctalia's cache. The plugin itself does not write those files or modify Noctalia's configuration.

### Refresh behavior

After the initial generation check succeeds, the plugin automatically compares the booted and current system closures so retained output cannot describe paths from before a service reload, switch, or reboot. Closure comparisons can also be requested manually.

The configured-system check runs at startup, every 15 minutes, when its configuration changes, on manual refresh, and after a successful flake input update. “Switch available” means the evaluated and active store paths differ; it does not claim that the target has been built or that switching will succeed.

Duplicate requests for a workflow that is already running are discarded rather than queued.

### Known limitations

NixOS configuration names are currently limited to unquoted identifier-style attributes containing letters, numbers, underscores, or hyphens. Quoted names such as `host.example.com` are not yet supported.

## Tests

Run the configuration, icon, parser, and service workflow tests with the standalone Luau interpreter:

```sh
nix shell nixpkgs#luau -c ./scripts/test
```

If `luau` is already available, run `./scripts/test` directly.

## License

The plugin source code is available under the [MIT License](LICENSE).

The optional NixOS logo templates are licensed separately under CC BY 4.0. See the [asset attribution](assets/ATTRIBUTION.md) and bundled [artwork license](assets/CC-BY-4.0.txt). The plugin is not an official NixOS product. Follow the official [NixOS branding guidance](https://nixos.org/branding/) when reusing the artwork.
