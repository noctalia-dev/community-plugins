# Mini Docker

Mini Docker manages Docker containers, images, volumes, and networks from
Noctalia. Its bar widget shows Docker availability and the number of running
containers, while its panel provides common management actions.

## Plugin

| Field | Value |
| --- | --- |
| ID | `8bury/mini-docker` |
| Entries | Bar widget: `mini-docker`; panel: `manager`; service: `docker-service` |

## Requirements

Install the Docker `docker` CLI and make sure your user can connect to the
Docker daemon. Test that `docker info` succeeds without unexpected prompts.

## Usage

Add the `mini-docker` widget to a bar. Left-click it to open the management
panel and right-click it to refresh Docker state immediately.

Open the panel directly with:

```sh
noctalia msg panel-toggle 8bury/mini-docker:manager
```

The panel has four tabs:

- **Containers:** start, stop, restart, and remove containers.
- **Images:** run images with an optional name, network, published port, and
  environment variables; remove images that are not in use.
- **Volumes:** inspect and remove volumes.
- **Networks:** inspect and remove non-default networks.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_interval` | `int` | `5` | Seconds between Docker state refreshes. |
| `default_network` | `string` | `bridge` | Network initially selected when running an image. |
| `show_count` | `bool` | `true` | Shows the running-container count in the widget. |
| `glyph_color` | `select` | `on_surface` | Theme color used for the Docker glyph. |
| `status_mode` | `select` | `always` | Shows the status dot always, only while running, or never. |
| `active_color` | `select` | `tertiary` | Status color when a container is running. |
| `inactive_color` | `select` | `error` | Status color when no containers are running. |

## Notes

Mini Docker runs the local Docker CLI with your user's existing daemon access.
Destructive actions require confirmation in the panel. It does not request
elevated privileges, store Docker credentials, mount host paths, or expose
ports unless you explicitly configure a port while running an image.
