# Split Reset

A bar button for Hyprland's dwindle layout. One click puts every split on that bar's monitor back to 50/50, the way windows tile when they first open. Use it after you drag a divider to give one window more room and want the even layout back.

## Plugin

| Field | Value |
| --- | --- |
| ID | `soulmanyes/split-reset` |
| Entries | Bar widget: `bar` |

## Requirements

- Hyprland 0.56 or later with the Lua config (`hyprland.lua`). The plugin runs its code inside Hyprland's Lua through `hyprctl eval`.
- `hyprctl` on `PATH`. It ships with Hyprland.
- The workspace must use the dwindle layout.

## Usage

1. Install and enable `soulmanyes/split-reset`.
2. Add the `bar` widget to your bar.
3. Click the columns icon. Every split on the workspace shown on that bar's monitor goes back to 50/50.

For example: four windows in a 2×2 grid, with the middle divider dragged to one side. One click makes them four equal quarters again.

Each bar resets its own monitor, not the focused one. Focus and the cursor don't move.

### Keybind (optional)

`split_reset.lua` defines a function, `split_reset()`. To use it from a keybind too, copy the file into your Hyprland config, for example `~/.config/hypr/config/split_reset.lua`, and add this to `hyprland.lua`:

```lua
require("config.split_reset")
hl.bind("SUPER + equal", function() split_reset() end)
```

| Call | Resets |
| --- | --- |
| `split_reset()` | the active workspace |
| `split_reset({ monitor = "DP-1" })` | that monitor's active workspace |
| `split_reset({ workspace = "3" })` | workspace 3 |
| `split_reset({ snap = 0.05 })` | only dividers already within 5% of the center |

## Notes

- **How it works:** Hyprland has no "equalize" layout message. `layoutmsg splitratio 1 exact` only changes the split directly above the focused window, so it can't reach the middle divider of a 2×2 grid. Instead, `split_reset()` works out the split tree from the window positions. Then it moves each divider to the center with a relative resize on a window next to it. Resizes target windows by address.
- **Processes:** each click runs `hyprctl eval 'dofile("<plugin dir>/split_reset.lua"); split_reset({ monitor = "<this bar's output>" })'`. The plugin makes no network calls and writes no files.
- **Left alone:** floating windows, workspaces with a fullscreen window, and workspaces with a layout other than dwindle.
- **One case it can't fix:** a split whose two halves are both split the same way, like a row of four built as `(A|B)|(C|D)`. No window resize reaches that middle divider, so it is skipped. Every other divider still gets reset.
- Tested on Hyprland 0.56.2 with Noctalia 5.3.0, on a 2×2 grid and on 3- and 4-window dwindle spirals.

## License

CC0 1.0 (public domain), see `LICENSE`.
