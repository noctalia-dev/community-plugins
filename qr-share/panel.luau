--!nonstrict
-- QR Share — a panel with two tabs, Wi-Fi and Clipboard, each showing its own
-- QR code. Nothing is shared between them: switching tabs does not move a QR
-- from one tab to the other.
--
-- Deliberately no service entry: every action runs inside a runAsync callback
-- triggered by a button press, so nothing polls. A polling service would hit
-- Noctalia's CPU-budget guard (noctalia-dev/noctalia#3893), which disables the
-- plugin runtime silently.
--
-- Generated PNGs live in $XDG_RUNTIME_DIR (a 0700 tmpfs) and are deleted in
-- onClose(), so a Wi-Fi password never survives the panel on disk.

local MAX_TEXT = 1000          -- safe upper bound for QR payload length (bytes)

local tab      = "wifi"        -- "wifi" | "clipboard"
local busy     = false
local errMsg   = nil

-- per-tab state
local wifi = { ssid = nil, security = nil, qr = nil, loaded = false }
local clip = {
    source  = nil,     -- "clipboard" | "manual" (where the text came from)
    text    = nil,     -- text currently encoded as a QR code
    preview = nil,     -- short snippet, kept for reference
    qr      = nil,     -- path to the QR PNG
    tooLong = false,
}
local clipInput = ""   -- contents of the manual input box

-- ── Util ──────────────────────────────────────────────────────────────────────
local function outDir()
    local d = noctalia.getenv("XDG_RUNTIME_DIR")
    if d == nil or d == "" then return "/tmp" end
    return d
end

local function qrPath(which)
    return outDir() .. "/noctalia-qr-" .. which .. ".png"
end

local function rmFile(p)
    if p ~= nil then
        pcall(noctalia.removeFile, p)
    end
end

-- Escape for the WIFI: payload format ( \; \, \: \" and backslash ).
local function esc(s)
    return (s:gsub("([\\;,\":])", "\\%1"))
end

-- Run argv (no shell) and call cb(result). Dynamic values always travel as argv
-- entries, so quoting and injection are non-issues.
local function run(argv, cb)
    noctalia.runAsync(argv, function(res)
        cb(res or {})
    end)
end

-- ── Render ────────────────────────────────────────────────────────────────────
local render

local function tabButton(id, label)
    return ui.button({
        text    = label,
        variant = (tab == id) and "primary" or "ghost",
        onClick = (id == "wifi") and "onTabWifi" or "onTabClip",
    })
end

local function qrBlock(path, hint)
    if path == nil then return nil end
    return ui.column({ align = "center", gap = 6 }, {
        ui.image({ path = path, width = 260, height = 260, radius = 12, onClick = "onCopyQr" }),
        ui.label({ text = hint, fontSize = 11, color = "on_surface/0.7" }),
    })
end

local function wifiBody()
    local rows = {}

    if wifi.ssid == nil then
        table.insert(rows, ui.label({ text = noctalia.tr("wifi.empty"), color = "on_surface/0.8" }))
    else
        table.insert(rows, ui.column({ gap = 2, align = "center" }, {
            ui.label({ text = noctalia.tr("wifi.ssid", { ssid = wifi.ssid }),
                       fontSize = 14, fontWeight = "bold" }),
            ui.label({ text = noctalia.tr("wifi.security", { security = wifi.security or "-" }),
                       fontSize = 12, color = "on_surface/0.75" }),
        }))
    end

    local qb = qrBlock(wifi.qr, noctalia.tr("qr.hint"))
    if qb ~= nil then table.insert(rows, qb) end

    table.insert(rows, ui.row({ gap = 6, justify = "center" }, {
        ui.button({ text = noctalia.tr("wifi.reload"), glyph = "refresh", controlSize = "sm",
                    onClick = "onLoadWifi", enabled = not busy }),
        ui.button({ text = noctalia.tr("qr.copy"), glyph = "copy", variant = "secondary",
                    controlSize = "sm", onClick = "onCopyQr", enabled = wifi.qr ~= nil }),
    }))

    return ui.column({ gap = 10, align = "center" }, rows)
end

-- Clipboard tab: take the latest clipboard text, or type it manually.
local function clipBody()
    local rows = {}

    -- Manual input box. A fixed `key` keeps already-typed text across re-renders.
    table.insert(rows, ui.column({ gap = 6 }, {
        ui.input({
            key         = "clip-input",
            value       = clipInput,
            placeholder = noctalia.tr("clip.placeholder"),
            multiline   = true,
            height      = 56,
            onChange    = "onClipInputChange",
            onSubmit    = "onClipInputSubmit",
        }),
        ui.row({ gap = 6, justify = "center" }, {
            ui.button({
                text = noctalia.tr("clip.take"), glyph = "clipboard",
                controlSize = "sm", onClick = "onTakeClipboard", enabled = not busy,
            }),
            ui.button({
                text = noctalia.tr("clip.generate"), glyph = "qrcode", variant = "primary",
                controlSize = "sm", onClick = "onClipInputSubmit", enabled = not busy,
            }),
        }),
    }))

    -- Where the text currently on screen came from.
    if clip.text ~= nil and clip.text ~= "" then
        local key = (clip.source == "clipboard") and "clip.chars_from_clipboard"
                    or "clip.chars_from_manual"
        table.insert(rows, ui.label({
            text = noctalia.tr(key, { count = #clip.text }),
            fontSize = 11, color = "on_surface/0.6", textAlign = "center",
        }))

        if clip.tooLong then
            table.insert(rows, ui.label({
                text = noctalia.tr("clip.too_long", { max = MAX_TEXT }),
                fontSize = 11, color = "error", textAlign = "center",
            }))
        end

        local qb = qrBlock(clip.qr, noctalia.tr("qr.hint"))
        if qb ~= nil then table.insert(rows, qb) end

        if clip.qr ~= nil then
            table.insert(rows, ui.button({
                text = noctalia.tr("qr.copy"), glyph = "copy", variant = "secondary",
                controlSize = "sm", onClick = "onCopyQr",
            }))
        end
    else
        table.insert(rows, ui.label({
            text = noctalia.tr("clip.empty"),
            fontSize = 12, color = "on_surface/0.7", textAlign = "center",
        }))
    end

    return ui.column({ gap = 10, align = "center" }, rows)
end

render = function()
    local header = ui.row({ align = "center", justify = "space_between", gap = 8 }, {
        ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
        ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    })

    local tabs = ui.row({ gap = 6 }, {
        tabButton("wifi", noctalia.tr("tab.wifi")),
        tabButton("clipboard", noctalia.tr("tab.clipboard")),
    })

    local status
    if errMsg ~= nil then
        status = ui.label({ text = errMsg, fontSize = 12, color = "error" })
    elseif busy then
        status = ui.label({ text = noctalia.tr("status.working"), fontSize = 12, color = "on_surface/0.7" })
    else
        status = ui.label({ text = " " , fontSize = 12 })
    end

    local body = (tab == "wifi") and wifiBody() or clipBody()

    -- The body sits in a ui.scroll with flexGrow=1 so content taller than the
    -- panel scrolls instead of spilling past the panel bounds.
    panel.render(ui.column({ gap = 10, flexGrow = 1 }, {
        header,
        tabs,
        status,
        ui.scroll({ flexGrow = 1 }, { body }),
    }))
end

-- ── QR generation ─────────────────────────────────────────────────────────────
-- Every QR request bumps `qrGen`. If the panel is closed (or another QR is
-- requested) while qrencode is still running, the callback sees a stale
-- generation and deletes the file it just produced. Without this, a PNG could
-- "come back to life" right after onClose() cleaned up.
local qrGen = 0

-- path  : destination PNG
-- payload: QR contents (already formatted)
-- done  : callback(ok, stale)
local function makeQr(path, payload, done)
    qrGen += 1
    local gen = qrGen

    rmFile(path)
    run({ "qrencode", "-s", "8", "-m", "2", "-o", path, payload }, function(res)
        local ok = (res.exitCode or 1) == 0 and noctalia.fileExists(path)

        if gen ~= qrGen then
            -- Stale: discard the file, leave the UI alone.
            rmFile(path)
            done(false, true)
            return
        end

        if not ok then
            done(false, false)
            return
        end
        done(true, false)
    end)
end

-- ── Loaders ───────────────────────────────────────────────────────────────────
function onLoadWifi()
    if busy then return end
    busy, errMsg = true, nil

    -- Delete the old file BEFORE rendering: the other order leaves the freshly
    -- rendered tree pointing at a path that is about to vanish, which logs
    -- "image failed to load".
    rmFile(wifi.qr); wifi.qr = nil
    render()

    if not noctalia.commandExists("nmcli") then
        busy, errMsg = false, noctalia.tr("wifi.missing_nmcli")
        render(); return
    end

    -- Find the active Wi-Fi connection name (no user input involved).
    run({ "nmcli", "-t", "-f", "NAME,TYPE", "connection", "show", "--active" }, function(res)
        local ssid = nil
        for line in (res.stdout or ""):gmatch("[^\r\n]+") do
            local name, typ = line:match("^(.*):([^:]+)$")
            if typ == "802-11-wireless" and name ~= nil and name ~= "" then
                ssid = name
                break
            end
        end

        if ssid == nil then
            busy, errMsg = false, noctalia.tr("wifi.empty")
            render(); return
        end

        wifi.ssid = ssid

        -- Read the PSK (argv, so an odd SSID cannot break the call).
        run({ "nmcli", "-s", "-g", "802-11-wireless-security.psk",
              "connection", "show", "id", ssid }, function(r2)
            local psk = (r2.stdout or ""):gsub("%s+$", "")
            local payload
            if psk == "" then
                wifi.security = noctalia.tr("wifi.open")
                payload = "WIFI:T:nopass;S:" .. esc(ssid) .. ";;"
            else
                wifi.security = "WPA"
                payload = "WIFI:T:WPA;S:" .. esc(ssid) .. ";P:" .. esc(psk) .. ";;"
            end

            local path = qrPath("wifi")
            makeQr(path, payload, function(ok, stale)
                busy = false
                if stale then return end    -- panel closed / another QR requested
                if ok then
                    wifi.qr = path
                    wifi.loaded = true
                else
                    errMsg = noctalia.tr("wifi.failed")
                end
                render()
            end)
        end)
    end)
end

-- Build a QR code from a text (used by both sources: clipboard and manual).
local function makeClipQr(text, source)
    if busy then return end
    busy, errMsg = true, nil

    rmFile(clip.qr); clip.qr = nil
    clip.text, clip.source, clip.tooLong = text, source, false

    if text == nil or text == "" then
        busy = false
        render(); return
    end

    -- Snippet kept for reference; the full text is never put on screen.
    local p = text:gsub("\n", "⏎")
    if #p > 160 then p = p:sub(1, 160) .. "…" end
    clip.preview = p

    if #text > MAX_TEXT then
        busy, clip.tooLong = false, true
        render(); return
    end

    render()
    local path = qrPath("clip")
    makeQr(path, text, function(ok, stale)
        busy = false
        if stale then return end        -- panel closed / another QR requested
        if ok then
            clip.qr = path
        else
            errMsg = noctalia.tr("clip.failed")
        end
        render()
    end)
end

-- "Take from Clipboard" button: read the latest clipboard entry.
function onTakeClipboard()
    if busy then return end
    local text = noctalia.clipboardText()
    if text == nil or text == "" then
        errMsg = noctalia.tr("clip.empty_clipboard")
        render(); return
    end
    clipInput = text          -- also show it in the input box, so it can be edited
    makeClipQr(text, "clipboard")
end

function onClipInputChange(value)
    clipInput = value or ""
end

-- "Generate" button (or Ctrl+Enter in the input box): encode the input box.
function onClipInputSubmit(value)
    local text = value
    if text == nil or text == "" then text = clipInput end
    text = tostring(text or "")

    if text == "" then
        errMsg = noctalia.tr("clip.empty_input")
        render(); return
    end

    clipInput = text
    makeClipQr(text, "manual")
end

-- Clear the clipboard QR (used when switching tabs / closing the panel).
local function resetClip()
    rmFile(clip.qr); clip.qr = nil
    clip.text, clip.preview, clip.source, clip.tooLong = nil, nil, nil, false
end

-- ── Handlers ──────────────────────────────────────────────────────────────────
function onTabWifi()
    tab, errMsg = "wifi", nil
    render()
    onLoadWifi()
end

function onTabClip()
    tab, errMsg = "clipboard", nil
    render()
end

-- IPC for testing and automation:
--   noctalia msg plugin abuamar142/qr-share:panel all tab wifi|clipboard
--   noctalia msg plugin abuamar142/qr-share:panel all reload
--   noctalia msg plugin abuamar142/qr-share:panel all copyqr
--   noctalia msg plugin abuamar142/qr-share:panel all take            # from clipboard
--   noctalia msg plugin abuamar142/qr-share:panel all text <text>     # QR from text
function onIpc(event, payload)
    local p = tostring(payload or "")
    if event == "tab" then
        if p == "wifi" then onTabWifi() else onTabClip() end
    elseif event == "reload" then
        if tab == "wifi" then onLoadWifi() end
    elseif event == "copyqr" then
        onCopyQr()
    elseif event == "take" then
        onTakeClipboard()
    elseif event == "text" then
        if p ~= "" then
            clipInput = p
            makeClipQr(p, "manual")
        end
    end
end

function onCopyQr()
    local path = (tab == "wifi") and wifi.qr or clip.qr
    if path == nil then return end

    local bytes = noctalia.readFile(path)
    if bytes == nil then
        errMsg = noctalia.tr("qr.read_failed")
        render(); return
    end

    local ok = noctalia.copyToClipboard(bytes, "image/png")
    if not ok then
        errMsg = noctalia.tr("qr.copy_failed")
    else
        errMsg = nil
        noctalia.notify(noctalia.tr("qr.copied_title"), noctalia.tr("qr.copied_body"))
    end
    render()
end

function onCloseClicked()
    panel.close()
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────
function onOpen(_context)
    errMsg = nil
    busy = false

    -- QR files from the previous session were deleted in onClose(); make sure no
    -- state still points at a missing path, or ui.image fails to load.
    wifi.qr, clip.qr = nil, nil
    wifi.ssid = nil
    resetClip()

    render()
    -- Load only the active tab (keeps the callback budget small).
    if tab == "wifi" then
        onLoadWifi()
    end
end

function onClose()

    -- Cancel any QR still being generated: its callback will discard the file
    -- that just appeared, so no PNG "comes back to life" after this cleanup.
    qrGen += 1

    -- Remove the PNGs so no Wi-Fi password or clipboard content stays on disk.
    rmFile(wifi.qr); wifi.qr = nil
    resetClip()
    wifi.ssid, wifi.loaded = nil, false
    errMsg, busy = nil, false

    -- Re-render after deleting the files: otherwise the old tree still points at
    -- paths that no longer exist and Noctalia logs "image failed to load" the
    -- next time the panel opens.
    render()
end
