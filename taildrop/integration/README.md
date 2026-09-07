# File-manager integrations

`noctalia-taildrop` is triggered by running the bridge helper with one or more
absolute paths:

```sh
noctalia-taildrop /abs/path [...more paths]
```

The bridge validates every path, sends a single `taildrop_send` request to the
plugin, and opens the send dialog (`msg panel-open`). It is **file-manager
agnostic** — you only need to invoke it with the right placeholders.

Two patterns matter:

- **One invocation per selected file** (HyprFM, Thunar, and any manager that runs
  the command once per item). The plugin coalesces requests that arrive together
  into one dialog, so multi-select still works — it just fires a helper per file.
- **One invocation for all selected files** (Nautilus, Dolphin `%F`). This is the
  cleanest: a multi-select becomes a single request and a single dialog.

Each example assumes the helper is at `~/.local/bin/noctalia-taildrop`. Adjust
the path if you installed it elsewhere.

---

## HyprFM

Append the block from [`hyprfm/context-menu.toml`](./hyprfm-context-menu.toml) to
`~/.config/hyprfm/config.toml`:

```toml
[[context_menu.actions]]
name = "Send via Taildrop…"
command = "/home/you/.local/bin/noctalia-taildrop %f"
types = ["*"]
```

Restart HyprFM. HyprFM runs one action per selected file; the plugin merges them.

## Nautilus (GNOME Files)

Install the script and log out/in:

```sh
mkdir -p ~/.local/share/nautilus/scripts
cp nautilus/Taildrop ~/.local/share/nautilus/scripts/Taildrop
chmod +x ~/.local/share/nautilus/scripts/Taildrop
```

Right-click → **Scripts** → **Taildrop**. Nautilus passes all selected paths in
`$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS` (one per line), so a multi-select is one
dialog.

## Dolphin (KDE)

Install the service menu:

```sh
mkdir -p ~/.local/share/kio/servicemenus
cp dolphin/taildrop.desktop ~/.local/share/kio/servicemenus/taildrop.desktop
```

Right-click → **Actions** → **Send via Taildrop**. `%F` passes all selected files
in one invocation.

> If a version of Dolphin only exposes `%f` (single file), it still works — the
> plugin coalesces concurrent requests into one dialog.

## Thunar (XFCE)

Merge the `<action>` block from [`thunar/uca-entry.xml`](thunar/uca-entry.xml)
into `~/.config/Thunar/uca.xml` (inside the top-level `<actions>` element):

```xml
<actions>
  <action>
    <icon>send</icon>
    <name>Send via Taildrop</name>
    <command>/home/you/.local/bin/noctalia-taildrop %F</command>
    <description>Send the selected file(s) to a device via Taildrop</description>
    <patterns>*</patterns>
    <image-files/>
    <text-files/>
    <audio-files/>
    <video-files/>
    <other-files/>
  </action>
</actions>
```

Restart Thunar. `%F` passes all selected files; the plugin coalesces per-file
invocations too.

## Adding your own manager

Find your manager's "run command" / "custom action" / "external tool" entry and
wire it to:

```sh
/home/you/.local/bin/noctalia-taildrop <selected-files-placeholder>
```

If the manager has a single-file placeholder (`%f`, `{file}`, …, `%n`), point it
at the manager's multi-file placeholder (`%F`, `$selected-file-paths`, …) where
possible. The bridge accepts any number of paths and sends one request.
