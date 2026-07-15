# IdeaPad Conservation Mode
![IdeaPad Conservation Mode thumbnail](thumbnail.webp)

**IdeaPad Conservation Mode** is a Control Center shortcut plugin for [Noctalia](https://docs.noctalia.dev) (v5) that toggles **Conservation Mode** — capping charging around ~60% to preserve battery health — via the `ideapad_acpi` kernel driver's `conservation_mode` sysfs attribute. That driver covers Lenovo IdeaPad and Legion laptops alike, not just Legion.

Writing that attribute needs root by default. The first time you click the tile and the write fails, the plugin opens a terminal and runs a bundled one-time setup script with `sudo`. It creates a `lenovoctl` group, adds you to it, and installs a udev rule so future writes are unprivileged. Log out and back in once afterward; every click after that just works, with no further prompts.
