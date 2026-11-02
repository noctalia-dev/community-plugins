# Umbriel Submap

Explain in one or two sentences what the plugin does and why someone would use
it.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ezio-noir/umbriel-submap` |
| Entries | Bar widget: `widget`; service: `service` |

## Requirements

Noctalia plugin API 43 or newer.

Install `umbriel` on `PATH` and running an `umbriel` session.

## Usage

Add the widget into bar and (or) enable OSD.

## Settings


| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `enable_osd` | `bool` | `false` | Display OSD on submap changed |
| `show_glyph` | `bool` | `false` | Show widget glyph (horizontal bar only) |
| `custom_labels` | `string_map` | `{}` | Key-value pairs to change display name for submaps (useful for vertical bar) |

