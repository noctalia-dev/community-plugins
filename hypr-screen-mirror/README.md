# Hypr Screen Mirror

This plugin allows you to easily toggle screen mirroring in Hyprland.

## Plugin

<!-- Copy ids exactly from plugin.toml. Remove rows that do not apply. -->

| Field   | Value                                                              |
| ------- | ------------------------------------------------------------------ |
| ID      | `profidev/hypr-screen-mirror`                                      |
| Entries | Bar widget: `widget`; panel: `<panel-id>`; service: `<service-id>` |

## Requirements

<!-- Required when plugin.toml declares dependencies. Mention every dependency
     using its exact manifest name, for example `example-cli`. Include any
     authentication, hardware, service, or compositor requirements too. Remove
     this section only when the plugin has no requirements. -->

Install `example-cli` on `PATH`.

## Usage

Explain how to add or access every user-facing entry and describe the normal
workflow. Use exact labels and ids. For a panel, include its copy-pasteable IPC
command:

```sh
noctalia msg panel-toggle <author>/<plugin>:<panel-id>
```

For a launcher provider, explain what to type after `/<prefix>` and what
activating a result does. For a shortcut, say where users add it in Settings.

## Settings

<!-- Required when plugin.toml declares settings. Describe behavior and units,
     especially for settings whose effect is not obvious from the label. A
     table like the official plugin READMEs is recommended. -->

| Setting           | Type   | Default | Description                      |
| ----------------- | ------ | ------- | -------------------------------- |
| `example_setting` | `bool` | `false` | What changing this setting does. |

## IPC

<!-- Optional unless the plugin exposes actions beyond opening a panel. List
     exact commands and explain their arguments and effects. -->

```sh
noctalia msg plugin <author>/<plugin>:<entry-id> all <event> [payload]
```

## Notes

<!-- Optional. Document important side effects and limitations: network access,
     files written, commands spawned, sensitive data, compositor support, and
     useful debugging information. -->
