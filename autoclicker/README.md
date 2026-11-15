# Auto Clicker

A [Noctalia](https://docs.noctalia.dev) plugin that repeats a [ydotool](https://github.com/ReimuNotMoe/ydotool) command on an interval. There are no settings: the IPC payload is just ydotool's own arguments, plus one loop option. Works with any ydotool command: `click`, `key`, `type`, `mousemove`.

## Plugin

| Field   | Value                                    |
| ------- | ---------------------------------------- |
| ID      | `amirfarzamnia/autoclicker`              |
| Entries | Bar widget: `widget`; service: `service` |

## Requirements

- Noctalia v5+ (plugin API 24 or newer)
- `ydotool` installed on `PATH`, with the `ydotoold` daemon running.

## Usage

1. Enable **Auto Clicker** in Settings → Plugins.
2. Add the widget to your bar.
3. Bind a compositor hotkey (see examples below).

The bar widget is visible only while running (click it to stop).

## IPC

```sh
noctalia msg plugin amirfarzamnia/autoclicker:service all <event> "[-i <ms>] [ydotool args...]"
```

### Events

| Event    | Behavior                                                                                                 |
| -------- | -------------------------------------------------------------------------------------------------------- |
| `toggle` | Stop if running, otherwise start with the payload.                                                       |
| `start`  | Start with the payload. If already running, replace the command live (an empty payload changes nothing). |
| `stop`   | Stop.                                                                                                    |

### Payload Options & Parsing

The payload is `[-i,--interval <ms>] [ydotool args...]`:

- `-i,--interval <ms>`: time between runs. Default `100`, minimum `10`. Must come first.
- Everything after it is passed to `ydotool` unchanged, exactly as you would type it after `ydotool` on the command line.
- With no command, it runs `click 0xC0` (left click).
- The payload is split like a minimal shell: whitespace separates words, `'...'` and `"..."` group, and `\` escapes the next character. Quote the whole payload so Noctalia receives it as one argument.

### Examples

```sh
# Left click every 100 ms (the default)
noctalia msg plugin amirfarzamnia/autoclicker:service all toggle

# Left click every 50 ms
noctalia msg plugin amirfarzamnia/autoclicker:service all toggle "-i 50"

# Right click every 100 ms (0xC1 = right button, down then up)
noctalia msg plugin amirfarzamnia/autoclicker:service all toggle "click 0xC1"

# Middle click, with ydotool's own delay option
noctalia msg plugin amirfarzamnia/autoclicker:service all toggle "-i 200 click -d 10 0xC2"

# Double click: repeat the left click twice per run
noctalia msg plugin amirfarzamnia/autoclicker:service all toggle "-i 500 click -r 2 0xC0"

# Hammer Space (key code 57) every 50 ms
noctalia msg plugin amirfarzamnia/autoclicker:service all toggle "-i 50 key 57:1 57:0"

# Type text repeatedly
noctalia msg plugin amirfarzamnia/autoclicker:service all toggle "-i 1000 type 'hello world'"

# Wiggle the mouse
noctalia msg plugin amirfarzamnia/autoclicker:service all toggle "-i 200 mousemove 5 0"

```

### Compositor Bindings

**Hyprland:**

```conf
bind = SUPER, F8, exec, noctalia msg plugin amirfarzamnia/autoclicker:service all toggle
bind = SUPER SHIFT, F8, exec, noctalia msg plugin amirfarzamnia/autoclicker:service all toggle "-i 50 click 0xC1"
```

**Sway:**

```swayconfig
bindsym $mod+F8 exec noctalia msg plugin amirfarzamnia/autoclicker:service all toggle
```

**Niri:**

```kdl
Mod+F8 { spawn "noctalia" "msg" "plugin" "amirfarzamnia/autoclicker:service" "all" "toggle"; }
Mod+Shift+F8 { spawn "noctalia" "msg" "plugin" "amirfarzamnia/autoclicker:service" "all" "toggle" "-i 50 click 0xC1"; }
```

### Mouse Buttons and Key Codes

Buttons follow ydotool's `click` format: a button number with `0x40` (down) and/or `0x80` (up) OR-ed in. `0xC0` is a full left click.

| Button  | Click (down + up) |
| ------- | ----------------- |
| Left    | `0xC0`            |
| Right   | `0xC1`            |
| Middle  | `0xC2`            |
| Side    | `0xC3`            |
| Extra   | `0xC4`            |
| Forward | `0xC5`            |
| Back    | `0xC6`            |
| Task    | `0xC7`            |

Key codes are the `KEY_*` values in `/usr/include/linux/input-event-codes.h` (Enter `28`, Space `57`, Left Ctrl `29`, Left Shift `42`). To see what your own keyboard sends, run `sudo libinput record`. See `man ydotool` for the full argument reference of each command.

## Notes

### How It Works

- A background **service** owns the on/off state and runs `ydotool <your args>` once per interval. A run is skipped if the previous one has not finished yet, so slow commands never pile up. Stopping terminates the in-flight `ydotool` process (SIGTERM, then SIGKILL after 1 s), and a restart waits until that process is gone before launching a new one.
- The **widget** only shows or hides itself based on the service's state, so multiple bars never start duplicate clickers.
- If `ydotool` exits with an error (bad arguments, `ydotoold` not running), the plugin stops and shows ydotool's error output instead of looping silently.
- Invalid payloads (bad `-i` value, unterminated quote) show an error and nothing starts.
- Nothing keeps running if Noctalia exits.
- Because stop kills the running command, a long `click -r N` can be cut off between a button's down and up events; if a button ever seems held, send `ydotool click 0x80` (left up), `0x81` (right up), etc.

### Troubleshooting

- **"ydotool was not found on PATH"**: install ydotool and make sure it is on the `PATH` Noctalia runs with.
- **"ydotool failed, stopped"**: read the message for ydotool's error. Usually the arguments are wrong, `ydotoold` is not running, or `YDOTOOL_SOCKET` points to the wrong place in Noctalia's environment.
- **Widget never appears**: confirm the plugin is enabled and the bar entry uses plugin's widget.
- **Hotkey does nothing**: run the `noctalia msg plugin ...` command in a terminal to check it works outside your compositor config.
