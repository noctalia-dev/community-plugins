--!nonstrict
-- Crashes panel: recent coredumps of this user, newest first. Per row:
-- one-click AI diagnosis in a terminal and a per-program mute toggle.
-- Pure renderer over "crashes_state"; mutes and refresh go through
-- "crashes_request" so the service stays the single writer of its files.
-- Open via IPC: noctalia msg panel-toggle umedbazarov/crashes:panel

local STATE_KEY = "crashes_state"
local REQUEST_KEY = "crashes_request"

local snapshot = nil
local launching = {} -- pid -> true while a diagnosis terminal is being spawned

local view = "crashes" -- crashes|journal
-- Level selector index -> journald priority (see syslog(3)).
local LEVELS = { 3, 2, 1, 0 }
local levelIndex = 0 -- 0-based, like ui.select's selectedIndex

local render

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function cfg(key, fallback)
    -- getConfig returns nil until the setting is materialized in
    -- settings.toml; the manifest default is NOT substituted by the runtime.
    -- An empty string is a real value (an intentionally empty terminal_cmd).
    local value = noctalia.getConfig(key)
    if value == nil then
        return fallback
    end
    return value
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function request(action, name, level)
    local prev = noctalia.state.get(REQUEST_KEY)
    local nonce = (type(prev) == "table" and tonumber(prev.nonce) or 0) + 1
    noctalia.state.set(REQUEST_KEY, { nonce = nonce, action = action, name = name, level = level })
end

-- The level selector's onChange receives (index, label).
function onLevel(index, _label)
    levelIndex = tonumber(index) or 0
    request("journal", nil, LEVELS[levelIndex + 1])
end

local function crashList()
    if snapshot == nil or type(snapshot.crashes) ~= "table" then
        return {}
    end
    return snapshot.crashes
end

-- ── Diagnosis ───────────────────────────────────────────────────────────────

-- Runs the agent with a prompt in a terminal. terminal_cmd wraps agent_cmd;
-- an empty terminal_cmd means the agent command opens its own window. The
-- prompt rides as one quoted argument. PATH: the shell environment here has
-- neither ~/.local/bin nor the npm bin dir, which is exactly where these
-- agents usually live - without this the click silently does nothing.
local function launchAgent(key, prompt)
    if launching[key] == true then
        return
    end
    launching[key] = true
    render()

    -- User-supplied text appended to every prompt (answer language, house rules).
    local extra = tostring(cfg("extra_prompt", ""))
    if extra:gsub("%s", "") ~= "" then
        prompt = prompt .. "\n" .. extra .. "\n"
    end

    -- No agent_cmd set: use the first installed well-known agent (each has
    -- its own way of taking a prompt). $0 is the prompt.
    local agent = tostring(cfg("agent_cmd", ""))
    if agent:gsub("%s", "") == "" then
        agent = 'if command -v claude >/dev/null; then claude "$0"; '
            .. 'elif command -v opencode >/dev/null; then opencode --prompt "$0"; '
            .. 'elif command -v codex >/dev/null; then codex "$0"; '
            .. 'elif command -v grok >/dev/null; then grok -- "$0"; '
            .. 'else echo "No AI agent found (claude/opencode/codex/grok) — set one in the plugin settings."; read -r _; fi'
        agent = "bash -c " .. shellQuote(agent)
    end
    local terminal = tostring(cfg("terminal_cmd", "kitty -e"))
    local wrapped = agent .. " " .. shellQuote(prompt)
    if terminal:gsub("%s", "") ~= "" then
        wrapped = terminal .. " " .. wrapped
    end
    local launch = 'export PATH="$HOME/.local/bin:$HOME/.local/share/npm/bin:$PATH"; ' .. wrapped

    noctalia.runAsync("setsid bash -c " .. shellQuote(launch) .. " >/dev/null 2>&1 &", function()
        launching[key] = nil
        render()
    end)
end

local function diagnose(entry)
    local guide = (noctalia.pluginDir() or ".") .. "/diagnose.md"
    local prompt = "A process crashed on this machine and I want to know why.\n\n"
        .. "What systemd-coredump recorded:\n"
        .. "  process:  " .. entry.name .. "\n"
        .. "  PID:      " .. entry.pid .. "\n"
        .. "  binary:   " .. entry.exe .. "\n"
        .. "  signal:   " .. entry.sigName .. "\n"
        .. "  time:     " .. entry.timeLabel .. "\n"
        .. "  core:     " .. (entry.core and "present" or "missing") .. "\n\n"
        .. "Read the investigation guide first and follow it:\n\n  " .. guide .. "\n"
    launchAgent(entry.pid, prompt)
end

local function analyzeJournal(entry, index)
    local prompt = "An error appeared in the systemd journal on this machine and I want to understand it.\n\n"
        .. "Journal entry:\n"
        .. "  source:   " .. entry.name .. "\n"
        .. "  priority: " .. entry.prioName .. "\n"
        .. "  time:     " .. (entry.timeIso or entry.timeLabel) .. "\n"
        .. "  message:  " .. entry.msg .. "\n\n"
        .. "Investigate from evidence, not guesswork: pull the surrounding journal context\n"
        .. "(journalctl -b with SYSLOG_IDENTIFIER/_COMM filters, and --since/--until a few\n"
        .. "minutes around that time), check whether it repeats across the boot, and\n"
        .. "correlate with related units and recent package updates. Then explain what the\n"
        .. "message means, how serious it is, and what — if anything — should be done.\n"
        .. "Separate clearly what the evidence proves from what you infer. Leave the\n"
        .. "system as you found it: diagnosis reads, it does not fix or reconfigure.\n"
    launchAgent("jrn-" .. index, prompt)
end

-- ── Render ──────────────────────────────────────────────────────────────────

local function crashRow(entry, index)
    local muted = entry.muted == true
    local nameColor = muted and "on_surface_variant" or "on_surface"

    return ui.row({ key = "crash-" .. entry.pid .. "-" .. index, gap = 8, align = "center" }, {
        ui.glyph({ glyph = "bug", size = 14, color = muted and "on_surface_variant" or "error" }),
        ui.column({ gap = 1, flexGrow = 1 }, {
            ui.label({ text = entry.name, fontSize = 13, fontWeight = "bold", color = nameColor, maxLines = 1 }),
            ui.label({
                text = entry.sigName .. " · " .. entry.timeLabel .. " · PID " .. entry.pid
                    .. (entry.core and "" or (" · " .. tr("no_core"))),
                fontSize = 10,
                color = "on_surface_variant",
                maxLines = 1,
            }),
        }),
        ui.button({
            key = "diag-" .. entry.pid .. (launching[entry.pid] and "-off" or ""),
            glyph = "stethoscope",
            variant = "ghost",
            enabled = launching[entry.pid] ~= true and entry.core,
            tooltip = entry.core and tr("tip_diagnose") or tr("tip_no_core"),
            onClick = function()
                diagnose(entry)
            end,
        }),
        ui.button({
            key = "mute-" .. entry.name .. "-" .. tostring(muted),
            glyph = muted and "bell-off" or "bell",
            variant = "ghost",
            tooltip = muted and tr("tip_unmute") or tr("tip_mute"),
            onClick = function()
                request(muted and "unmute" or "mute", entry.name)
            end,
        }),
    })
end

local function journalRow(entry, index)
    -- 0..2 (emerg/alert/crit) get the error badge, err the plain one.
    local badgeColor = entry.prio <= 2 and "error" or "secondary"
    return ui.row({ key = "jrn-" .. index, gap = 8, align = "center" }, {
        ui.label({ text = entry.prioName, fontSize = 10, fontWeight = "bold", color = badgeColor }),
        ui.column({ gap = 1, flexGrow = 1 }, {
            ui.label({ text = entry.name .. " · " .. entry.timeLabel, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
            ui.label({ text = entry.msg, fontSize = 11, color = "on_surface", maxLines = 2 }),
        }),
        ui.button({
            key = "jdiag-" .. index .. (launching["jrn-" .. index] and "-off" or ""),
            glyph = "stethoscope",
            variant = "ghost",
            enabled = launching["jrn-" .. index] ~= true,
            tooltip = tr("tip_diagnose"),
            onClick = function()
                analyzeJournal(entry, index)
            end,
        }),
    })
end

local function renderCrashes(children)
    local list = crashList()
    if #list == 0 then
        table.insert(children, ui.spacer({ flexGrow = 1 }))
        table.insert(children, ui.label({ text = tr("empty"), color = "on_surface_variant" }))
        table.insert(children, ui.label({ text = tr("empty_hint"), fontSize = 11, color = "on_surface_variant", maxLines = 2 }))
        table.insert(children, ui.spacer({ flexGrow = 1 }))
    else
        local rows = {}
        for index, entry in ipairs(list) do
            if index > 1 then
                table.insert(rows, ui.separator({ key = "sep-" .. index }))
            end
            table.insert(rows, crashRow(entry, index))
        end
        table.insert(children, ui.scroll({ key = "crashes", flexGrow = 1, gap = 4 }, rows))
    end
end

local function renderJournal(children)
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = tr("level_label"), fontSize = 11, color = "on_surface_variant" }),
        ui.select({
            selectedIndex = levelIndex,
            options = { tr("level_err"), tr("level_crit"), tr("level_alert"), tr("level_emerg") },
            onChange = "onLevel",
            flexGrow = 1,
        }),
    }))

    local entries = {}
    if snapshot ~= nil and type(snapshot.journal) == "table" and type(snapshot.journal.entries) == "table" then
        entries = snapshot.journal.entries
    end
    if #entries == 0 then
        table.insert(children, ui.spacer({ flexGrow = 1 }))
        table.insert(children, ui.label({ text = tr("journal_empty"), color = "on_surface_variant" }))
        table.insert(children, ui.spacer({ flexGrow = 1 }))
    else
        local rows = {}
        for index, entry in ipairs(entries) do
            if index > 1 then
                table.insert(rows, ui.separator({ key = "jsep-" .. index }))
            end
            table.insert(rows, journalRow(entry, index))
        end
        table.insert(children, ui.scroll({ key = "journal", flexGrow = 1, gap = 4 }, rows))
    end
end

render = function()
    local children = {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ glyph = "bug", size = 18, color = "primary" }),
            ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
            ui.button({
                glyph = "refresh", variant = "ghost", tooltip = tr("tip_refresh"),
                onClick = function()
                    if view == "journal" then
                        request("journal", nil, LEVELS[levelIndex + 1])
                    else
                        request("refresh")
                    end
                end,
            }),
            ui.button({
                glyph = "close", variant = "ghost", tooltip = tr("tip_close"),
                onClick = function()
                    panel.close()
                end,
            }),
        }),
        -- Tab switch: crashes / journal errors by level.
        ui.row({ gap = 6, align = "center" }, {
            ui.button({
                key = "tab-crashes-" .. tostring(view == "crashes"),
                text = tr("tab_crashes"),
                variant = view == "crashes" and "primary" or "ghost",
                flexGrow = 1,
                onClick = function()
                    view = "crashes"
                    render()
                end,
            }),
            ui.button({
                key = "tab-journal-" .. tostring(view == "journal"),
                text = tr("tab_journal"),
                variant = view == "journal" and "primary" or "ghost",
                flexGrow = 1,
                onClick = function()
                    view = "journal"
                    render()
                    request("journal", nil, LEVELS[levelIndex + 1])
                end,
            }),
        }),
    }

    if snapshot ~= nil and snapshot.err ~= nil and snapshot.err ~= "" then
        table.insert(children, ui.label({ text = tostring(snapshot.err), fontSize = 11, color = "error", maxLines = 2 }))
    end

    if view == "journal" then
        renderJournal(children)
    else
        renderCrashes(children)
    end

    if snapshot ~= nil and snapshot.checkedAt ~= nil and snapshot.checkedAt ~= "" then
        table.insert(children, ui.separator({}))
        table.insert(children, ui.label({
            text = tr("caption_checked", { time = snapshot.checkedAt }),
            fontSize = 10, color = "on_surface_variant",
        }))
    end

    panel.render(ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, children))
end

function onOpen(_context)
    snapshot = noctalia.state.get(STATE_KEY)
    render()
    request("refresh")
end

noctalia.state.watch(STATE_KEY, function(value)
    if type(value) ~= "table" then
        return
    end
    snapshot = value
    render()
end)
