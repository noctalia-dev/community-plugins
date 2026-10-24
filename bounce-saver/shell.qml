// bounce-saver: OLED screensaver, a logo bouncing on pure black, every output.
// Own idle timer, so it runs with Noctalia caffeine on; Noctalia still does
// lock / screen-off. Run: qs -p /path/to/bounce-saver/shell.qml
// (the Noctalia plugin's service.luau does this for you).
// BOUNCE_LOGO=/abs/path.svg picks another logo (white art tints best),
// BOUNCE_TIMEOUT=<seconds> the idle time (default 120).
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    // Idle: show, unless that screen has a fullscreen window (video). Inhibitors are
    // ignored: a static music page inhibits too, and X11 players cannot inhibit at all.
    IdleMonitor {
        id: idle
        timeout: Number(Quickshell.env("BOUNCE_TIMEOUT")) || 120 // seconds without input
        respectInhibitors: false
    }

    // Outputs showing a fullscreen window, from niri IPC. Quickshell's ToplevelManager
    // lists no windows under niri, and niri has no fullscreen flag, so a window whose
    // size equals its output's logical size on an active workspace counts as fullscreen.
    // No niri (or IPC error): empty list, so the screensaver shows. OLED-safe default.
    property var fullscreenOutputs: []
    property bool probed: false
    readonly property bool idleNow: idle.isIdle
    onIdleNowChanged: idleNow ? fsProbe.running = true : probed = false

    function parseFullscreen(text) {
        const [outputs, workspaces, windows] = text.trim().split("\n").map(l => JSON.parse(l))
        const found = []
        for (const ws of workspaces) {
            const out = outputs[ws.output]
            if (!ws.is_active || !out || !out.logical) continue
            if (windows.some(w => w.workspace_id === ws.id
                    && Math.abs(w.layout.window_size[0] - out.logical.width) <= 1
                    && Math.abs(w.layout.window_size[1] - out.logical.height) <= 1))
                found.push(ws.output)
        }
        return found
    }

    Process {
        id: fsProbe
        command: ["sh", "-c", "niri msg -j outputs && niri msg -j workspaces && niri msg -j windows"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.fullscreenOutputs = root.parseFullscreen(text) }
                catch (e) { root.fullscreenOutputs = [] }
                root.probed = true            }
        }
        onExited: code => { if (code !== 0) { root.fullscreenOutputs = []; root.probed = true } }
    }
    Timer {
        interval: 2000
        repeat: true
        running: root.idleNow
        onTriggered: fsProbe.running = true
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            visible: root.idleNow && root.probed
                && !root.fullscreenOutputs.includes(win.modelData.name)
            color: "black"
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "bounce-saver"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            // Like the old DVD players: 45° diagonal, constant speed, new colour per wall hit.
            property real hue: Math.random()
            property real vx: 150 // px per second
            property real vy: 150

            Image {
                id: logo
                source: Quickshell.env("BOUNCE_LOGO") ? "file://" + Quickshell.env("BOUNCE_LOGO") : "logo.svg"
                sourceSize.width: Math.round(win.modelData.width / 6) // height follows the art's aspect
                visible: false
            }
            MultiEffect {
                id: shown
                source: logo
                width: logo.width
                height: logo.height
                colorization: 1.0
                colorizationColor: Qt.hsva(win.hue, 1, 1, 1)
            }

            // New hue at least 1/6 turn away, so every hit is a visible change.
            function bounce() {
                win.hue = (win.hue + 1 / 6 + Math.random() * 2 / 3) % 1
            }

            onVisibleChanged: if (visible) {
                shown.x = Math.random() * Math.max(win.width - shown.width, 0)
                shown.y = Math.random() * Math.max(win.height - shown.height, 0)
            }

            FrameAnimation {
                running: win.visible
                onTriggered: {
                    const dt = Math.min(frameTime, 0.1)
                    const maxX = win.width - shown.width, maxY = win.height - shown.height
                    let x = shown.x + win.vx * dt, y = shown.y + win.vy * dt, hit = false
                    // Mirror reflection: overshoot past a wall is folded back, no energy lost.
                    if (x < 0 || x > maxX) { win.vx = -win.vx; x = x < 0 ? -x : 2 * maxX - x; hit = true }
                    if (y < 0 || y > maxY) { win.vy = -win.vy; y = y < 0 ? -y : 2 * maxY - y; hit = true }
                    if (hit) win.bounce()
                    shown.x = x
                    shown.y = y
                }
            }
        }
    }
}
