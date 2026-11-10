# Packages frontend

Bundled Python-standard-library frontend using existing fzf, pacman and paru.
It has no daemon, package database, automatic scanner installation or automatic
Traur gate. The parent [plugin README](../README.md) documents dependencies,
controls, transactions, network access and privacy limitations.

Use **Packages** in System Menu, or run this file from its directory:

```sh
python3 -I app.py
python3 -I app.py --list repos
python3 -I app.py --list installed
python3 -I app.py --list aur pacseek
python3 -B -m unittest discover -s . -p 'test_*.py' -v
```

Search RPC is read-only. AUR search results are not Traur scan results.
Optional Alt+T invokes `traur scan NAME --json`; missing, failed or invalid
reports provide no safety verdict. No local scanner fork, makepkg wrapper or
paru configuration is distributed. Installations preserve the user's existing
helper configuration, which may or may not include an automatic audit gate.

The Omarchy-inspired fzf multi-selection and package preview workflow retains
its original MIT notice in `LICENSE-OMARCHY`.

---

Built with AI assistance using OpenCode. AI assistance is not a security audit.
