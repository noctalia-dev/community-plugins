# Lyrics Dependencies

The plugin requires these commands on `PATH`:

| Command | Purpose |
| --- | --- |
| `playerctl` | Read and play/pause MPRIS players |
| `python3` | Run the lyric-source adapter, standard library only |
| `cp`, `chmod`, `timeout` | Cache artwork, secure temporary credentials, bound player polling |

Install:

```sh
# Arch
sudo pacman -S playerctl python coreutils

# Fedora
sudo dnf install playerctl python3 coreutils

# Debian / Ubuntu
sudo apt install playerctl python3 coreutils
```

Check:

```sh
sh scripts/setup-deps.sh --check
```

Omit `--check` to install automatically after detecting the package manager.
