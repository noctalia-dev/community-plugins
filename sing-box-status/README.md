# Sing-Box Status

A bar widget that shows whether the sing-box proxy daemon is running. When
sing-box is up, the glyph becomes a connected link tinted with the accent color;
when it is not running, the glyph is a plain muted link.

## Plugin

| Field | Value |
| --- | --- |
| ID | `dpvpro/sing-box-status` |
| Entries | Bar widget: `status` |

## Requirements

- `pgrep`, from `procps`/`procps-ng`, on `PATH`.

## Usage

Add **Sing-Box Status** from **Settings → Bar**: pick a section and choose
**Sing-Box Status** in the widget list.

The widget checks `pgrep sing-box` once a second and renders:

- a `link-plus` glyph in the `tertiary` color while sing-box is running;
- a `link` glyph in the default color when it is not.

Hover the glyph for a tooltip that states whether sing-box is running.

## Notes

**Processes.** The widget runs `pgrep sing-box` once per second and reads only
its exit code.

**No network access. No filesystem reads or writes.** All state is kept in
memory.
