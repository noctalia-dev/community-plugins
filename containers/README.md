# Containers

Noctalia bar widget + panel that shows your Docker and Podman containers *and*
the services running directly on your machine, and opens the ones with a web UI
straight in your browser.

## Plugin

| Field | Value |
| --- | --- |
| ID | `davinci13/containers` |
| Entries | Bar widget: `bar`, Panel: `panel`, Shortcut: `shortcut`, Service: `service` |

## Usage

1. Open Noctalia Settings.
2. Go to **Bar**, add a widget, and select **Containers** (`davinci13/containers:bar`).
3. Optionally add the tile in **Control Center** (`davinci13/containers:shortcut`).
4. Click the bar widget or control-center tile to open the panel, or toggle it via IPC:
   ```sh
   noctalia msg panel-toggle davinci13/containers:panel
   ```

## What it does

- Discovers containers from **both** runtimes every few seconds. A missing
  `docker` or `podman` binary is reported as *not installed* in the panel rather
  than breaking the plugin — either runtime on its own is enough.
- Also lists **host services**: your own listening TCP ports, one row per
  process, named after its systemd unit when there is one.
- Shows a `web UIs / total` counter on the bar and the same count as a
  control-center tile.
- Lists every container grouped by runtime, with its image, live status, and its
  published ports. Containers with no published port are shown too, but they are
  not clickable.
- **Click a container** to open its first published port. **Click a port chip** to
  open that specific port. **Right click a chip** to copy the URL.
- Newest data always comes from the service, so the panel is never stale.

## The panel

- **Compact rows.** Each service is two lines: name plus port chips, then the
  image/description plus its status. Padding is 6 px and the chips are `sm`, so a
  typical row is ~34 px tall.
- **Separated by source.** Every runtime gets its own band — a filled, outlined
  header with its glyph, name and count — and a rule sits between two of them,
  so Docker, Podman and Host never read as one list. Running rows are solid
  `surface_variant`, stopped ones are outlined, so the state stays visible
  without a translucent fill.
- **Scrolls.** The declared height is a viewport, not a cap: the list takes the
  free space between the header and the footer (`flexGrow`) and scrolls inside
  it, so fifty services cost you a scrollbar, not a broken panel.

## Host services

One `ss` probe finds the listening sockets and systemd names the ones it owns:

| Socket | Row |
|---|---|
| `LISTEN … 0.0.0.0:4321 … users:(("MainThread",pid=85882))` with `MainPID=85882` on `nginx.service` | **nginx** — *A high performance web server* |
| `LISTEN … 127.0.0.1:18000 … users:(("ssh",pid=52931))` with no unit | **ssh** — *pid 52931* |
| `LISTEN … 0.0.0.0:51911 …` six times on six addresses | one **qbittorrent** row with a single port chip |

- One row per **process**, not per socket, so a service bound to `0.0.0.0`,
  `127.0.0.1`, `192.168.1.4` and `[::1]` is one row with one chip per port.
- Names come from the unit (`.service` dropped) and the description goes on the
  second line; without a unit the process name and its pid are used instead.
- Skipped: sockets you cannot see the owner of (another user's), link-local
  addresses, and the runtime helpers (`docker-proxy`, `conmon`, …) that only
  forward a port the container list already has.
- Only TCP is listed, because only TCP can serve a web UI.

> Non-root `ss` cannot see which process owns another user's socket, so
> `systemd-resolved` or `cups` stay hidden until you set **Command prefix** to
> `sudo -n`. That prefix applies to every lookup the plugin runs.

## Install

Drop this directory into your Noctalia plugin data dir and enable it:

```sh
cp -r containers ~/.local/share/noctalia/plugins/
noctalia msg plugins enable davinci13/containers     # note: needs WAYLAND_DISPLAY set
noctalia msg plugins list                           # -> davinci13/containers [local] 1.2.0 enabled
```

Then add the widget to a bar in **Settings → Bar** (look for
`davinci13/containers:bar`), and the tile in **Settings → Control Center**
(`davinci13/containers:shortcut`). The plugin is not usable from the launcher until
the widget is placed — the panel is opened by the widget or the tile.

### Editing

- `.luau` edits hot-reload on save; the file watcher reloads the owning entry.
- `translations/*.json` is read when the plugin loads, so cycle the plugin after
  changing one: `noctalia msg plugins disable davinci13/containers` then `enable`.
  Skipping the cycle makes `noctalia.tr(key)` warn `plugin translation key ... not
  found` while still returning the key.

For development, point a path source at your working copy instead — the data-dir
copy above always wins over sources, so edit in place there for iteration:

```sh
noctalia msg plugins source add local-dev path ~/Projects/noctalia_container_services/containers
```

## Settings

| Setting | Default | Notes |
|---|---|---|
| Refresh interval | `5` s | Seconds between lookups. |
| Include stopped containers | off | Adds `-a`, so exited containers show up too. |
| Include host services | on | Also lists your own services listening on a TCP port. |
| Host used for links | `localhost` | Used when a port is published on every interface (`0.0.0.0`, `::`, empty) or bound to loopback. Ports bound to a specific address keep that address — `192.168.1.50:3000` links to `192.168.1.50`. |
| Command prefix | empty | Runs every lookup as-is. Set `sudo -n` if your user has no daemon socket, or to let `ss` see other users' ports. |
| Browser command | empty | Empty uses `xdg-open`, i.e. your default browser. |

The bar widget also has its own icon, counter toggle, and hide-when-empty toggle
under **Settings → Bar → the widget**.

## How links are built

| Published as | Link |
|---|---|
| `127.0.0.1:8888->8888/tcp` | `http://localhost:8888` |
| `0.0.0.0:8080->80/tcp` | `http://localhost:8080` |
| `0.0.0.0:443->443/tcp` | `https://localhost:443` |
| `:::9090->9090/tcp`, `[::]:9090->9090/tcp` | `http://localhost:9090` |
| `192.168.1.50:3000->3000/tcp` | `http://192.168.1.50:3000` |
| host socket `*:8080` or `127.0.0.1:8080` | `http://localhost:8080` |

Only TCP is offered — a UDP-only publish cannot serve a web UI. Published port
ranges (`8000-8005->80/tcp`) are expanded and each port is its own chip, capped at
64 to keep the state message small. HTTPS is only assumed on port 443; anything
else that speaks TLS opens as `http://`, so let your browser retry.

## Container-only ports

A container can listen on a port it never publishes. `surrealdb-local` here
publishes nothing, so `docker ps` shows an empty `Ports` column — yet it serves
SurrealDB on `0.0.0.0:8000` *inside* its own network namespace, reachable from the
host on its bridge IP.

Those ports are found by reading the container's `/proc/<pid>/net/tcp` for
listening sockets and pairing each with the container IP from `docker inspect`.
Only wildcard binds count: a `127.0.0.1` bind inside the namespace is not reachable
from the host.

| | Published | Container-only |
|---|---|---|
| Link | `http://localhost:8888` | `http://172.17.0.2:8000` |
| Chip style | filled | outlined |
| Tooltip | the URL | the URL + "inside the container" |

They are shown after a real published port, never instead of one, so a container
that publishes 8888 keeps its `localhost` link. If you would rather not have
these probed at all, disable host services — the probe runs with the same
`command_prefix` as the rest of your lookups.

## Layout

```
plugin.toml          manifest: identity, settings schema, four entries
service.luau         headless discovery: docker, podman and host ports, publishes "snapshot"
widget.luau          bar tile: counter, click opens the panel, right click refreshes
panel.luau           the list; every click opens or copies a URL
shortcut.luau        control-center tile, same count and toggle
translations/en.json settings labels and every UI string
```

Only the service talks to `docker`, `podman`, `ss` and `systemctl`; the other
entries read the `snapshot` it publishes through `noctalia.state`, so nothing is
parsed twice and no two entries can disagree.

## Development

`update()` in the service ticks once a second and refreshes on the interval
above. A refresh in flight makes the next one a no-op, so a slow daemon cannot
pile up processes. Force one from the shell:

```sh
noctalia msg plugin davinci13/containers:service all refresh
noctalia msg panel-toggle davinci13/containers:panel
```

## Requirements

Every source is optional on its own — the plugin works with any of them:

- `docker` (and a reachable daemon for your user)
- `podman`
- `ss` (from iproute2) for host services; `systemctl` is optional and only makes
  the host rows carry unit names instead of process names
- `xdg-open` (or set a browser command)
