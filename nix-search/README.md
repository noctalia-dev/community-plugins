# Nix Search

Search nixpkgs, NixOS, Home Manager and NUR from the launcher via nix-search-tv

## Plugin

| Field | Value |
| --- | --- |
| ID | `knyrps/nix-search` |
| Entries | service: `nix-search-index`; launcher_provider: `nix-search-provider` |
| Launcher Prefix | `/nix` |

## Requirements

Install `nix-search-tv` and `fzf` on `PATH`. The *Open …* actions use `xdg-open` from `xdg-utils`.

## Usage

Type /nix [query] in the launcher to fuzzy-search every index your nix-search-tv installation provides. By default nixpkgs, NixOS options, Home Manager options and NUR. Each result shows the attribute or option name with its source underneath.

Press Enter on a result to open its action list:

- The first entry shows the description from `nix-search-tv preview`
- Copy the attribute or option name to the clipboard
- nix shell nixpkgs#… - opens a terminal with the package (nixpkgs results only)
- Open on search.nixos.org (nixpkgs results only)
- Copy an `environment.systemPackages` or `home.packages` snippet (nixpkgs results only)
- Open homepage, when the preview reports one

The key list is refreshed from nix-search-tv once a day in the background. Trigger a refresh manually with:

`noctalia msg plugin knyrps/nix-search:nix-search-index all refresh`

## IPC

```sh
noctalia msg plugin knyrps/nix-search:nix-search-index all refresh
```

## Notes

n/a
