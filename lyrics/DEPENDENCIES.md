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

# NixOS (configuration.nix)
environment.systemPackages = with pkgs; [ playerctl python3 coreutils ];
```

Check:

```sh
sh scripts/setup-deps.sh --check
python3 -c 'import ssl; print(ssl.OPENSSL_VERSION)'
```

The second command must print an OpenSSL version. A Python build without the
`_ssl` module cannot fetch HTTPS lyrics; on NixOS use `pkgs.python3`, not
`pkgs.python3Minimal`.

Omit `--check` to install automatically after detecting the package manager.

On NixOS, the Noctalia process must inherit the same `PATH` as the shell where
these commands are available. After adding packages to a running session,
restart Noctalia or log in again. If the lyrics service logs
`python3 ... process failed`, confirm `command -v python3` works from the
process that starts Noctalia; the plugin does not bundle Python.

Flatpak permissions on the music player only affect MPRIS metadata. Lyrics are
fetched by the plugin process on the host, so network permissions inside the
player sandbox do not control lyric requests.
