# Packages frontend

![Made with AI](https://img.shields.io/badge/Made%20with-AI-76ddcf)

Bundled Python-standard-library frontend using existing fzf, pacman and your
choice of compatible AUR helper (paru by default).
It has no daemon, package database, automatic scanner installation or automatic
Traur gate. The parent [plugin README](../README.md) documents dependencies,
controls, transactions, network access and privacy limitations.

Use **Packages** in System Menu, or run this file from its directory:

```sh
python3 -I app.py
python3 -I app.py --aur-helper yay
python3 -I app.py --aur-helper /absolute/path/to/compatible-helper
python3 -I app.py --list repos
python3 -I app.py --list installed
python3 -I app.py --list aur pacseek
python3 -I app.py --aur-helper yay --list aur pacseek
python3 -B -m unittest discover -s . -p 'test_*.py' -v
```

Put `--aur-helper EXECUTABLE` before other options. The helper must support the
paru/yay-style search, install and update CLI described under
[Configuration](../README.md#configuration). It is an executable name/path,
not a shell command or alias; no extra arguments or shell expansion are applied.
The plugin passes its configured helper automatically and fzf callbacks retain it.

Search RPC is read-only. AUR search results are not Traur scan results.
Optional Alt+T invokes `traur scan NAME --json`; missing, failed or invalid
reports provide no safety verdict. No local scanner fork, makepkg wrapper or
helper configuration is distributed. Installations preserve the user's existing
helper configuration, which may or may not include an automatic audit gate.

The Omarchy-inspired fzf multi-selection and package preview workflow retains
its original MIT notice in `LICENSE-OMARCHY`.

## AI assistance

**Made with AI.** This project was developed with AI assistance, including code, documentation, and testing.
