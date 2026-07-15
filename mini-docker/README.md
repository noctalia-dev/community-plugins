# Mini Docker

Mini Docker is a Noctalia v5 plugin for managing Docker from the shell. The bar widget shows Docker availability and the running-container count. Its management panel can start, stop, restart, and remove containers; run and remove images; and inspect or remove volumes and networks.

This Luau implementation migrates the Noctalia v4 Mini Docker plugin originally written by [MannuVilasara](https://github.com/MannuVilasara).

## Requirements

- Noctalia 5.0.0 or newer
- Docker CLI and a reachable Docker daemon
- Permission for the current user to access Docker

## Usage

Enable `8bury/mini-docker`, then add its `mini-docker` widget to a bar. Click the widget to open the management panel. Right-click it to refresh Docker state immediately.

The panel has four tabs:

- Containers: start, stop, restart, or remove a selected container
- Images: run an image with optional name, network, port, and environment variables, or remove an unused image
- Volumes: inspect and remove volumes
- Networks: inspect and remove non-default networks

Settings control the refresh interval, default run network, running count, icon color, and status indicator.

## Security

Mini Docker invokes only the local `docker` CLI. Subprocess arguments are shell-quoted, and user-entered container names, ports, and environment-variable keys are validated before execution.

## License

MIT. Attribution to the original v4 author is retained above.
