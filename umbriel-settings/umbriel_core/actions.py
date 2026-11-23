"""Umbriel keybind action catalog."""

import shlex

ACTION_DOCS = """
[Apps]
spawn <cmd...> | Run a command (through the shell) with a launch activation token
[Noctalia shell (spawn presets)]
spawn noctalia msg panel-toggle launcher | Toggle the Noctalia launcher
spawn noctalia msg panel-toggle control-center | Toggle the control center
spawn noctalia msg panel-toggle clipboard | Toggle the clipboard panel
spawn noctalia msg panel-toggle wallpaper | Toggle the wallpaper picker
spawn noctalia msg panel-toggle session | Toggle the session (power) menu
spawn noctalia msg plugin alexander/screen-toolkit:service all toggle | Toggle the Screen Toolkit panel (color picking, OCR, scanning, annotation, and recording)
spawn noctalia msg session lock | Lock the current session
spawn noctalia msg session suspend | Suspend the system without locking first
spawn noctalia msg session lock-and-suspend | Lock the session, then suspend
spawn noctalia msg session logout | Log out of the graphical session
spawn noctalia msg session reboot | Reboot the system
spawn noctalia msg session reboot-uefi | Reboot into UEFI firmware setup
spawn noctalia msg session shutdown | Shut down the system
spawn noctalia msg settings-toggle | Toggle the Noctalia settings window
spawn noctalia msg screenshot-region | Take a region screenshot
spawn noctalia msg screenshot-fullscreen | Capture the focused monitor
spawn noctalia msg screenshot-fullscreen pick | Open the display picker, or capture immediately on a single monitor
spawn noctalia msg screenshot-fullscreen DP-2 | Capture a specific output (replace DP-2 with its connector name)
spawn noctalia msg screenshot-fullscreen all | Capture all monitors in one combined image
spawn noctalia msg screenshot-window | Capture the focused window
spawn noctalia msg screenshot-annotate | Freeze the screen and open the screenshot annotation editor
spawn noctalia msg annotate | Open the live-screen drawing overlay
spawn noctalia msg annotate ~/Pictures/shot.png | Annotate an image file
spawn noctalia msg window-switcher hold | Alt+Tab style window switcher (hold to keep it open)
spawn noctalia msg volume-up | Raise volume (shows the OSD)
spawn noctalia msg volume-down | Lower volume (shows the OSD)
spawn noctalia msg volume-mute | Mute or unmute (shows the OSD)
spawn noctalia msg media toggle | Play or pause media
spawn noctalia msg media next | Next track
spawn noctalia msg media previous | Previous track
spawn noctalia msg brightness-up | Raise brightness (shows the OSD)
spawn noctalia msg brightness-down | Lower brightness (shows the OSD)
[Screencasting]
screencast-clear | Pause the screencast and stop following
screencast-follow-output | Follow the focused output
screencast-follow-stop | Stop following and keep the current target
screencast-follow-window | Follow the focused window
screencast-set-output [<output>] | Share the focused output, or the selected output
screencast-set-window [<window-id>] | Share the focused window, or the selected window
[Focus]
column-focus-first | Focus the first column in the workspace
column-focus-last | Focus the last column in the workspace
column-focus-tab <index> | Focus a tab of the focused tab group by its position
column-focus-tab-next | Focus the next tab in the focused tab group
column-focus-tab-previous | Focus the previous tab in the focused tab group
output-focus-down | Focus the output below
output-focus-left | Focus the output to the left
output-focus-next | Focus the next output, wrapping around
output-focus-previous | Focus the previous output, wrapping around
output-focus-right | Focus the output to the right
output-focus-up | Focus the output above
window-focus <window-id> | Focus a window, revealing it from a hidden scratchpad
window-focus-down | Focus the next window down in the column
window-focus-last | Focus the previously focused window
window-focus-left | Focus the window to the left
window-focus-next | Focus the next window in layout order
window-focus-or-output-down | Focus down, or the output below at the edge
window-focus-or-output-left | Focus left, or the output left at the edge
window-focus-or-output-right | Focus right, or the output right at the edge
window-focus-or-output-up | Focus up, or the output above at the edge
window-focus-or-workspace-down | Focus down, or the next workspace at the edge
window-focus-or-workspace-up | Focus up, or the previous workspace at the edge
window-focus-previous | Focus the previous window in layout order
window-focus-right | Focus the window to the right
window-focus-switch-floating | Focus the last window of the opposite floating state
window-focus-up | Focus the next window up in the column
window-focus-warp <window-id> | Focus or reveal a window and warp the cursor to it
workspace-focus-last | Focus the previously active workspace
[Move & size]
column-center | Center the focused column in the viewport
column-move-left | Move the focused column one position left
column-move-right | Move the focused column one position right
column-move-to-first | Move the focused column to the first position
column-move-to-last | Move the focused column to the last position
column-move-to-output-down | Move the focused column to the output below
column-move-to-output-left | Move the focused column to the output left
column-move-to-output-right | Move the focused column to the output right
column-move-to-output-up | Move the focused column to the output above
layout-master-count-decrease | Demote the last master window to the stack
layout-master-count-increase | Promote the first stack window to master
layout-scroll-down | Scroll the strip toward its end
layout-scroll-drag | Pan the strip while the bound button is held
layout-scroll-left | Scroll the strip toward its start
layout-scroll-right | Scroll the strip toward its end
layout-scroll-up | Scroll the strip toward its start
layout-toggle-split | Toggle the focused tile's dwindle split direction
window-center | Center the focused floating window on its output
window-consume-from-left | Pull the left column's window into the focused column
window-consume-from-right | Pull the right column's window into the focused column
window-consume-left | Stack the focused window into the column left
window-consume-or-expel-left | Split the window out, or stack it into the column left
window-consume-or-expel-right | Split the window out, or stack it into the column right
window-consume-right | Stack the focused window into the column right
window-cycle-primary-extent | Cycle the focused area's primary extent through presets
window-cycle-primary-extent-back | Cycle the primary extent presets in reverse
window-cycle-secondary-extent | Cycle the focused area's secondary extent through presets
window-cycle-secondary-extent-back | Cycle the secondary extent presets in reverse
window-modify-height-down <delta> | Resize the focused window from its bottom edge
window-modify-height-up <delta> | Resize the focused window from its top edge
window-modify-primary-extent <delta> | Change the focused area's primary extent by a fraction
window-modify-secondary-extent <delta> | Change the focused area's secondary extent by a fraction
window-modify-width-left <delta> | Resize the focused column from its left edge
window-modify-width-right <delta> | Resize the focused column from its right edge
window-move-by <delta-x> <delta-y> [--window <window-id>] | Move the floating window by logical pixels
window-move-down | Move down in its column, or a float to the bottom edge
window-move-left | Move the focused window left, or a float to the left edge
window-move-or-output-down | Move down, or the column to the output below
window-move-or-output-left | Move the column left, or to the output left
window-move-or-output-right | Move the column right, or to the output right
window-move-or-output-up | Move up, or the column to the output above
window-move-or-workspace-down | Move down, or to the next workspace at the edge
window-move-or-workspace-up | Move up, or to the previous workspace at the edge
window-move-right | Move the focused window right, or a float to the right edge
window-move-to <anchor> <x> <y> [--window <window-id>] | Move the floating window to an anchored position
window-move-to-output-down | Move the focused window to the output below
window-move-to-output-left | Move the focused window to the output left
window-move-to-output-next | Move the focused window to the next output
window-move-to-output-previous | Move the focused window to the previous output
window-move-to-output-right | Move the focused window to the output right
window-move-to-output-up | Move the focused window to the output above
window-move-up | Move up in its column, or a float to the top edge
window-set-primary-extent <fraction> | Set the focused area's primary extent fraction (0.1 to 4.0)
window-set-secondary-extent <fraction> | Set the focused area's secondary extent fraction
window-set-region left | Stacking layout: place the window in the left half
window-set-region right | Stacking layout: place the window in the right half
window-set-region top | Stacking layout: place the window in the top half
window-set-region bottom | Stacking layout: place the window in the bottom half
window-set-region top_left | Stacking layout: place the window in the top-left quarter
window-set-region top_right | Stacking layout: place the window in the top-right quarter
window-set-region bottom_left | Stacking layout: place the window in the bottom-left quarter
window-set-region bottom_right | Stacking layout: place the window in the bottom-right quarter
window-clear-region | Restore the window's normal position and size after window-set-region
window-swap-down | Swap with the window below
window-swap-left | Swap with the window to the left
window-swap-next | Swap with the next window in layout order
window-swap-previous | Swap with the previous window in layout order
window-swap-right | Swap with the window to the right
window-swap-up | Swap with the window above
[Windows]
column-hide-tab-bar | Hide the focused tab group's bar; its tabs take the space
column-move-tab-next | Move the focused tab one place later among its tabs
column-move-tab-previous | Move the focused tab one place earlier among its tabs
column-set-display normal | Show the rows around the focused window stacked
column-set-display tabbed | Show the rows around the focused window as tabs
column-show-tab-bar | Show the focused tab group's bar
column-toggle-tab-bar | Show or hide the focused tab group's bar
column-toggle-tabbed | Tab the rows around the focused window, or stack its tabs
window-close [<window-id>] | Close the focused window, or the given window
window-kill [<window-id>] | Kill the process owning the window (can lose unsaved work)
window-minimize [<window-id>] | Minimize the focused floating window, or the given window
window-restore-minimized | Restore the latest minimized window on this workspace
window-toggle-floating [<window-id>] | Float or tile the focused window (tiling layouts only; stacking windows already float)
window-toggle-fullscreen | Toggle fullscreen or exit a window covering the focus
window-toggle-maximize | Toggle full width for the focused column
window-toggle-maximize-to-edges | Toggle maximize without gaps, struts, or borders
window-toggle-pinned | Pin the focused window above other windows
[Scratchpad]
scratchpad-focus-next [<scratchpad>] | Focus the next visible scratchpad window
scratchpad-toggle [<scratchpad>] | Show or hide the selected scratchpad windows
scratchpad-window-show-next [<scratchpad>] | Show only the next scratchpad window
scratchpad-window-show-previous [<scratchpad>] | Show only the previous scratchpad window
window-move-to-scratchpad [<scratchpad>] | Move the focused window into a scratchpad
window-restore-from-scratchpad [<scratchpad>] | Return a scratchpad window to its saved workspace
window-toggle-scratchpad [<scratchpad>] | Move the focused window to or from a scratchpad
[Workspaces]
column-move-to-workspace <workspace> [--output <output>] | Move the focused column to the selected workspace
column-move-to-workspace-next | Move the focused column to the next workspace
column-move-to-workspace-previous | Move the focused column to the previous workspace
window-move-to-workspace <workspace> [--output <output>] | Move the focused window to the selected workspace
window-move-to-workspace-next | Move the focused window to the next workspace
window-move-to-workspace-previous | Move the focused window to the previous workspace
window-move-to-workspace-silent <workspace> [--output <output>] | Move the focused window to a workspace without following
window-move-to-workspace-silent-next | Move the focused window to the next workspace silently
window-move-to-workspace-silent-previous | Move the focused window to the previous workspace silently
workspace-move-down | Move the focused workspace down the list
workspace-move-to-output <destination> [<workspace>] [--output <output>] | Move the active or selected workspace to an output
workspace-move-to-output-down | Move the workspace to the output below
workspace-move-to-output-left | Move the workspace to the output left
workspace-move-to-output-next | Move the workspace to the next output
workspace-move-to-output-previous | Move the workspace to the previous output
workspace-move-to-output-right | Move the workspace to the output right
workspace-move-to-output-up | Move the workspace to the output above
workspace-move-up | Move the focused workspace up the list
workspace-next | Switch to the next workspace on this output
workspace-previous | Switch to the previous workspace on this output
workspace-set-layout scrolling | Set the active workspace's layout to scrolling
workspace-set-layout dwindle | Set the active workspace's layout to dwindle
workspace-set-layout master | Set the active workspace's layout to master
workspace-set-layout stacking | Set the active workspace's layout to stacking (windows float freely)
workspace-set-layout toggle | Cycle scrolling, dwindle, master, stacking
workspace-set-layout toggle scrolling master | Cycle only the listed layouts (edit the list; two or more, each once)
workspace-swap-active-output-down | Swap active workspace windows with the output below
workspace-swap-active-output-left | Swap active workspace windows with the output left
workspace-swap-active-output-next | Swap active workspace windows with the next output
workspace-swap-active-output-previous | Swap active workspace windows with the previous output
workspace-swap-active-output-right | Swap active workspace windows with the output right
workspace-swap-active-output-up | Swap active workspace windows with the output above
workspace-switch <workspace> [--output <output>] | Switch to the selected workspace
workspace-toggle-show-desktop | Minimize or restore the workspace's floating windows
[Overview]
overview-close | Close the workspace overview
overview-open | Open the workspace overview
overview-toggle | Open or close the workspace overview
[System]
cheatsheet-close | Hide the keybind cheatsheet
cheatsheet-open | Show the keybind cheatsheet
cheatsheet-toggle | Show or hide the keybind cheatsheet
config-reload | Reload the configuration file
cursor-hide | Hide the cursor until pointer activity
cursor-show | Show the cursor and restart its inactivity timeout
dpms-off [<output>] | Power off one output, or every output when bare
dpms-on [<output>] | Power on one output, or every output when bare
keyboard-layout-next | Switch one keyboard to its next configured layout
output-disable <output> | Remove an output from the desktop
output-enable <output> | Add an output to the desktop
output-sdr-white <nits> [--output <output>] | Set an output's live SDR reference white in cd/m2
output-toggle <output> | Add or remove an output from the desktop
session-quit | Quit the session (asks for confirmation first)
session-quit skip-confirmation | Quit the session immediately
shortcuts-inhibit-toggle | Toggle shortcuts inhibition for the focused surface
submap <name> | Enter a submap layer
submap reset | Leave the current submap layer
[Effects]
effect-border-cycle [<pool>] [--window <window-id>] | Cycle the current or named border pool
effect-border-reset [<window-id>] | Clear runtime state and resolve configuration
effect-border-set <name> [--window <window-id>] | Select a border preset/pool, or suppress with off
effect-border-toggle [<window-id>] | Toggle border-slot suppression
effect-cursor-cycle [<pool>] | Cycle the current or named cursor pool
effect-cursor-reset | Clear runtime state and resolve configuration
effect-cursor-set <name> | Select a cursor preset/pool, or suppress with off
effect-cursor-toggle | Toggle cursor-slot suppression
effect-screen-cycle [<pool>] [--output <output>] | Cycle the current or named screen pool
effect-screen-reset [<output>] | Clear runtime state and resolve configuration
effect-screen-set <name> [--output <output>] | Select a screen preset/pool, or suppress with off
effect-screen-toggle [<output>] | Toggle screen-slot suppression
effect-window-cycle [<pool>] [--window <window-id>] | Cycle the current or named window pool
effect-window-reset [<window-id>] | Clear runtime state and resolve configuration
effect-window-set <name> [--window <window-id>] | Select a window preset/pool, or suppress with off
effect-window-toggle [<window-id>] | Toggle window-slot suppression
"""

# Hints for argument placeholders, shown under the table for the selected action.
ARG_HELP = {
    "cmd": "command line, run through the shell, e.g. spawn kitty or spawn firefox",
    "name": "preset/pool name (effects) or submap name",
    "workspace": "1-based position (digits) or a name; use --name <name> to force a name; add --output <output> to scope",
    "output": "connector or monitor name from `umbriel outputs`",
    "window-id": "window id from `umbriel windows`; leave out for the focused window",
    "delta": "signed -0.9 to 0.9; clamps to 0.1 and the layout's maximum",
    "fraction": "0.1 to 4.0 of the column (scrolling), or 0.1 to 1.0 of the usable area for floats",
    "nits": "SDR reference white in cd/m2, 80 to 1000",
    "index": "tab position from 1; negative counts from the last tab (-1)",
    "anchor": "an anchor such as top_left, center, bottom_right, then x and y pixel offsets",
    "delta-x": "signed pixel offsets: delta-x delta-y (e.g. window-move-by 40 -20)",
    "destination": "output to move the workspace to (connector or monitor name from `umbriel outputs`)",
    "scratchpad": "scratchpad name; leave out for the default scratchpad",
    "pool": "pool name; leave out for the current pool",
}


def parse_actions(text):
    """Parse ACTION_DOCS into [(category, [(template, description), ...]), ...]."""
    cats, cur = [], None
    for line in text.strip().splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]") and "|" not in line:
            cur = (line[1:-1], [])
            cats.append(cur)
        else:
            action, _, desc = line.partition(" | ")
            cur[1].append((action.strip(), desc.strip()))
    return cats


ACTION_CATEGORIES = parse_actions(ACTION_DOCS)
ACTION_TEMPLATES = [a for _, items in ACTION_CATEGORIES for a, _ in items]


def _action_index(categories):
    """({bare action name: (first template, description)}, actions that always need an argument)."""
    info, bare_ok = {}, set()
    for _, items in categories:
        for template, description in items:
            head, _, rest = template.partition(" ")
            info.setdefault(head, (template, description))
            if not rest or rest.lstrip().startswith("["):
                bare_ok.add(head)
    return info, {head for head in info if head not in bare_ok}


ACTION_INFO, REQUIRED_ARG_ACTIONS = _action_index(ACTION_CATEGORIES)


# Actions "Run now" refuses: they end the session, close or kill the focused window (in the app, the app
# itself), turn screens off or leave the keyboard in a submap. Luau gets the same lists through `meta`.
RUN_BLOCKED = {
    "session-quit": "Ends the session",
    "window-close": "Would close the focused window (this one)",
    "window-kill": "Would kill the focused window (this one)",
    "dpms-off": "Turns screens off",
    "output-disable": "Can remove the only output",
    "output-toggle": "Can remove the only output",
    "shortcuts-inhibit-toggle": "Would block shortcuts in this window",
}
RUN_BLOCKED_SPAWN = {"noctalia msg session": "Locks, suspends or ends the session"}
SUBMAP_REASON = "Would leave the keyboard in the submap"


def _words(action):
    """The words `umbriel msg` gets (quotes removed), or plain words when the quotes don't balance."""
    try:
        return shlex.split(action)
    except ValueError:
        return action.split()


def run_block_reason(action):
    """Why "Run now" refuses `action`, or None when it may run (checked on the words that run, so quoting an
    action doesn't get it past the list)."""
    words = _words(action)
    if not words:
        return "No action"
    head, rest = words[0], " ".join(" ".join(words[1:]).split())
    if head in RUN_BLOCKED:
        return RUN_BLOCKED[head]
    if head == "submap" and rest != "reset":
        return SUBMAP_REASON
    if head == "spawn":
        for phrase, reason in RUN_BLOCKED_SPAWN.items():
            if phrase in rest:
                return reason
    return None


def msg_argv(action):
    """`umbriel` arguments that run `action` once: `spawn` keeps its command as one word."""
    words = shlex.split(action)
    if words and words[0] == "spawn":
        parts = action.strip().split(None, 1)
        return ["msg", "spawn", parts[1].strip() if len(parts) > 1 else ""]
    return ["msg", *words]
