# Obsidian Vault Switcher

Find and switch between your registered Obsidian vaults from the Noctalia launcher.

## Plugin

| Field | Value |
| --- | --- |
| ID | `0b10headedcalf/obsidian-vault-switcher` |
| Entries | Launcher provider: `vaults` |
| Launcher Prefix | `/vault` |

## Requirements

Install `xdg-open` on `PATH` and install Obsidian with its `obsidian://` URI handler registered. Open each vault in Obsidian at least once so it appears in its vault list.

## Usage

Enable the plugin, open the Noctalia launcher, and type part of a vault name or path to find it in the global results. You can also type `/vault` to list all registered vaults, or narrow the list with a query such as `/vault work`. Select a result to open that vault or focus its existing Obsidian window.

## Notes

The provider reads `$XDG_CONFIG_HOME/obsidian/obsidian.json`, or `~/.config/obsidian/obsidian.json` when `XDG_CONFIG_HOME` is unset or not absolute. It displays vault paths and refreshes the list on each query. Vaults removed or moved outside Obsidian can remain in the list until removed in Obsidian's vault manager. Selecting a vault starts `xdg-open` with its Obsidian vault ID; the plugin does not write vault files or make network requests.
