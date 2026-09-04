--!nonstrict

-- Owns one generated KDL file next to the configured Niri root. Manual rules
-- remain untouched; the editable model lives in the plugin data directory.

local DEFAULT_CONFIG = "~/.config/niri/config.kdl"
local INCLUDE_LINE = 'include "./cfg/noctalia-rules-studio.kdl"'
local CANDIDATE_INCLUDE_LINE = 'include "./cfg/.noctalia-rules-studio.candidate.kdl"'
local BEGIN_MARKER = "// BEGIN NIRI RULES STUDIO"
local END_MARKER = "// END NIRI RULES STUDIO"
local PANEL_ID = "setyvii/niri-rules-studio:panel"

local state = {
    page = "inspect",
    loading = false,
    status = "",
    error = nil,
    window = nil,
    openWindows = {},
    workspaces = {},
    outputs = {},
    rules = {},
    editing = nil,
    pendingDelete = nil,
    editorRevision = 0,
    windowQuery = "",
    reopenAfterPick = false,
    pendingPick = false,
    form = {
        appId = "",
        title = "",
        matchTitle = false,
        mode = "tiled",
        workspace = "",
        output = "",
        width = "",
        height = "",
    },
}

-- Paths, quoting, and exact-match helpers.
local function trim(value)
    return (value or ""):match("^%s*(.-)%s*$")
end

local function tr(key, values)
    return noctalia.tr(key, values)
end

local function pathDirname(path)
    local clean = tostring(path or ""):gsub("/+$", "")
    local parent = clean:match("^(.*)/[^/]*$")
    if not parent or parent == "" then return clean:sub(1, 1) == "/" and "/" or "." end
    return parent
end

local function pathJoin(base, child)
    if base == "/" then return "/" .. child end
    return base:gsub("/+$", "") .. "/" .. child
end

local function configuredPaths()
    local configured = noctalia.getConfig("niri_config")
    if type(configured) ~= "string" or trim(configured) == "" then configured = DEFAULT_CONFIG end
    local mainConfig = noctalia.expandPath(trim(configured))
    local niriDir = pathDirname(mainConfig)
    local cfgDir = pathJoin(niriDir, "cfg")
    return {
        mainConfig = mainConfig,
        niriDir = niriDir,
        cfgDir = cfgDir,
        managedRules = pathJoin(cfgDir, "noctalia-rules-studio.kdl"),
        candidateRules = pathJoin(cfgDir, ".noctalia-rules-studio.candidate.kdl"),
        candidateConfig = pathJoin(niriDir, ".noctalia-rules-studio.validate.kdl"),
        backupDir = pathJoin(niriDir, ".noctalia-rules-studio-backups"),
    }
end

local function kdlQuote(value)
    local text = tostring(value or "")
    text = text:gsub("\\", "\\\\")
    text = text:gsub('"', '\\"')
    text = text:gsub("\n", "\\n")
    return '"' .. text .. '"'
end

local REGEX_MAGIC = {
    ["\\"] = true, ["."] = true, ["^"] = true, ["$"] = true,
    ["|"] = true, ["?"] = true, ["*"] = true, ["+"] = true,
    ["("] = true, [")"] = true, ["["] = true, ["]"] = true,
    ["{"] = true, ["}"] = true,
}

local function exactRegex(value)
    local text = tostring(value or "")
    local escaped = {}
    for index = 1, #text do
        local char = text:sub(index, index)
        table.insert(escaped, REGEX_MAGIC[char] and ("\\" .. char) or char)
    end
    return "^" .. table.concat(escaped) .. "$"
end

-- Durable JSON model and generated KDL.
local function modelPath()
    local directory, err = noctalia.pluginDataDir()
    if not directory then
        return nil, err or tr("error_data_directory")
    end
    return directory .. "/rules.json"
end

local function loadRules()
    local path = modelPath()
    if not path then return end
    local raw = noctalia.readFile(path)
    if not raw or raw == "" then
        state.rules = {}
        return
    end
    local decoded, err = noctalia.json.decode(raw)
    if type(decoded) == "table" then
        state.rules = decoded
    else
        state.rules = {}
        state.error = tr("error_model_read", { error = tostring(err or "invalid JSON") })
    end
end

local function saveModels()
    local path, err = modelPath()
    if not path then return false, err end
    local content, encodeErr = noctalia.json.encode(state.rules, true)
    if not content then return false, encodeErr end
    return noctalia.writeFile(path, content)
end

local function sizeNode(name, value)
    local number = tonumber(value)
    if not number or number <= 0 then return nil end
    if number <= 1 then
        return "    " .. name .. " { proportion " .. string.format("%.3f", number) .. "; }"
    end
    return "    " .. name .. " { fixed " .. tostring(math.floor(number)) .. "; }"
end

local function modeUsesInitialSize(mode)
    return mode == "tiled" or mode == "floating"
end

local function serializeRule(rule)
    local lines = {
        "// Managed by Niri Rules Studio. Edit this rule in the plugin.",
        "window-rule {",
        "    match app-id=" .. kdlQuote(exactRegex(rule.appId)),
    }
    if rule.matchTitle and trim(rule.title) ~= "" then
        lines[3] = "    match app-id=" .. kdlQuote(exactRegex(rule.appId)) .. " title=" .. kdlQuote(rule.title)
    end
    table.insert(lines, "    open-floating " .. tostring(rule.mode == "floating"))
    table.insert(lines, "    open-fullscreen " .. tostring(rule.mode == "fullscreen"))
    table.insert(lines, "    open-maximized " .. tostring(rule.mode == "maximized"))
    table.insert(lines, "    open-maximized-to-edges " .. tostring(rule.mode == "maximized_edges"))
    if trim(rule.workspace) ~= "" then table.insert(lines, "    open-on-workspace " .. kdlQuote(rule.workspace)) end
    if trim(rule.output) ~= "" then table.insert(lines, "    open-on-output " .. kdlQuote(rule.output)) end
    if modeUsesInitialSize(rule.mode) then
        local width = sizeNode("default-column-width", rule.width)
        local height = sizeNode("default-window-height", rule.height)
        if width then table.insert(lines, width) end
        if height then table.insert(lines, height) end
    end
    table.insert(lines, "}")
    return table.concat(lines, "\n")
end

local function serializeRules()
    local chunks = {
        "// This file is generated by Niri Rules Studio.",
        "// Do not edit it manually; changes will be overwritten.",
        "",
    }
    for _, rule in ipairs(state.rules) do
        if rule.enabled ~= false then
            table.insert(chunks, serializeRule(rule))
            table.insert(chunks, "")
        end
    end
    return table.concat(chunks, "\n")
end

local function exactLineBounds(text, expected)
    local startIndex = 1
    while startIndex <= #text + 1 do
        local newline = text:find("\n", startIndex, true)
        local endIndex = newline and (newline - 1) or #text
        local line = text:sub(startIndex, endIndex)
        if trim(line) == expected then return startIndex, endIndex, line:match("^(%s*)") or "" end
        if not newline then break end
        startIndex = newline + 1
    end
    return nil, nil, nil
end

local function replaceExactLine(text, expected, replacement)
    local startIndex, endIndex, indent = exactLineBounds(text, expected)
    if not startIndex then return nil end
    return text:sub(1, startIndex - 1) .. indent .. replacement .. text:sub(endIndex + 1)
end

local function includeBlock(includeLine)
    return BEGIN_MARKER .. "\n" .. includeLine .. "\n" .. END_MARKER
end

local function appendBlock(config, block)
    local suffix = config:sub(-1) == "\n" and "\n" or "\n\n"
    return config .. suffix .. block .. "\n"
end

-- Validate the full root configuration before activating a generated file.
local function configWithInclude(paths)
    local config, err = noctalia.readFile(paths.mainConfig)
    if not config then return nil, err or ("Cannot read " .. paths.mainConfig) end
    local includeStart = exactLineBounds(config, INCLUDE_LINE)
    if includeStart then return config, nil, true end
    if config:find("noctalia-rules-studio.kdl", 1, true) then
        return nil, tr("error_include_ambiguous")
    end
    return appendBlock(config, includeBlock(INCLUDE_LINE)), nil, false
end

local function persistRules(onSuccess, onFailure)
    local function fail(message, status)
        state.loading = false
        state.error = message
        state.status = status or tr("not_saved")
        if onFailure then onFailure() end
        panel.render(renderApp())
    end

    state.error = nil
    local paths = configuredPaths()
    local candidate = serializeRules()
    local config, readErr, alreadyIncluded = configWithInclude(paths)
    if not config then
        fail(readErr)
        return
    end

    -- Keep the include in the same position: Niri window rules are ordered.
    -- The temporary root stays beside the real root, so every other relative
    -- include resolves exactly as it does in the active configuration.
    local validationConfig = replaceExactLine(config, INCLUDE_LINE, CANDIDATE_INCLUDE_LINE)
    if not validationConfig then
        fail(tr("error_prepare_include"))
        return
    end

    local ok, writeErr = noctalia.mkdirAll(paths.cfgDir)
    if not ok then
        fail(tr("error_config_directory", { error = tostring(writeErr) }))
        return
    end
    ok, writeErr = noctalia.writeFile(paths.candidateRules, candidate)
    if not ok then
        fail(tr("error_write_candidate", { error = tostring(writeErr) }))
        return
    end
    ok, writeErr = noctalia.writeFile(paths.candidateConfig, validationConfig)
    if not ok then
        noctalia.removeFile(paths.candidateRules)
        fail(tr("error_prepare_validation", { error = tostring(writeErr) }))
        return
    end

    state.loading = true
    state.status = tr("validating")
    panel.render(renderApp())
    local started = noctalia.runAsync({ "niri", "validate", "-c", paths.candidateConfig }, function(result)
        state.loading = false
        noctalia.removeFile(paths.candidateConfig)
        if result.exitCode ~= 0 then
            noctalia.removeFile(paths.candidateRules)
            fail(
                trim(result.stderr) ~= "" and trim(result.stderr) or tr("error_validation_rejected"),
                tr("validation_failed")
            )
            return
        end

        local backupOk, backupErr = noctalia.mkdirAll(paths.backupDir)
        if not backupOk then
            noctalia.removeFile(paths.candidateRules)
            fail(tr("error_backup_directory", { error = tostring(backupErr) }))
            return
        end

        local stamp = tostring(noctalia.nowMs())
        local rulesBackup = pathJoin(paths.backupDir, "rules-" .. stamp .. ".kdl")
        if not alreadyIncluded then
            local configBackup = pathJoin(paths.backupDir, "config-" .. stamp .. ".kdl")
            local backupWritten, backupWriteErr = noctalia.writeFile(configBackup, noctalia.readFile(paths.mainConfig) or "")
            if not backupWritten then
                noctalia.removeFile(paths.candidateRules)
                fail(tr("error_backup_config", { error = tostring(backupWriteErr) }))
                return
            end
        end

        local movedOldRules = false
        if noctalia.fileExists(paths.managedRules) then
            local moveBackupErr
            movedOldRules, moveBackupErr = noctalia.renameFile(paths.managedRules, rulesBackup)
            if not movedOldRules then
                noctalia.removeFile(paths.candidateRules)
                fail(tr("error_backup_rules", { error = tostring(moveBackupErr) }))
                return
            end
        end
        local moved, moveErr = noctalia.renameFile(paths.candidateRules, paths.managedRules)
        if not moved then
            if movedOldRules then noctalia.renameFile(rulesBackup, paths.managedRules) end
            fail(tr("error_activate", { error = tostring(moveErr) }))
            return
        end
        if not alreadyIncluded then
            local wroteConfig, configErr = noctalia.writeFile(paths.mainConfig, config)
            if not wroteConfig then
                noctalia.removeFile(paths.managedRules)
                if movedOldRules then noctalia.renameFile(rulesBackup, paths.managedRules) end
                fail(tr("error_include", { error = tostring(configErr) }), tr("action_required"))
                return
            end
        end
        local modelOk, modelErr = saveModels()
        if not modelOk then
            state.error = tr("error_model_save", { error = tostring(modelErr) })
        end
        state.status = tr("saved")
        if onSuccess then onSuccess() end
        panel.render(renderApp())
    end)
    if not started then
        noctalia.removeFile(paths.candidateConfig)
        noctalia.removeFile(paths.candidateRules)
        fail(tr("error_start_command", { command = "niri validate" }))
    end
end

-- Select options and Niri IPC snapshots used by the panel.
local function workspaceOptions()
    local options = { tr("no_workspace_rule") }
    for _, workspace in ipairs(state.workspaces) do
        if workspace.name and workspace.name ~= "" then table.insert(options, workspace.name) end
    end
    return options
end

local function outputOptions()
    local options = { tr("no_output_rule") }
    for _, output in ipairs(state.outputs) do table.insert(options, output) end
    return options
end

local function optionIndex(options, value)
    for i, option in ipairs(options) do if option == value then return i - 1 end end
    return 0
end

local function requestJson(command, callback)
    local started = noctalia.runAsync(command, function(result)
        if result.exitCode ~= 0 then
            callback(nil, trim(result.stderr) ~= "" and trim(result.stderr) or tr("error_ipc"))
            return
        end
        local decoded, err = noctalia.json.decode(result.stdout)
        callback(decoded, err)
    end)
    if not started then
        callback(nil, tr("error_start_command", { command = command }))
    end
end

local function loadInspector()
    state.loading = true
    state.error = nil
    state.status = tr("inspecting")
    state.window = nil
    state.openWindows = {}
    state.workspaces = {}
    state.outputs = {}
    panel.render(renderApp())

    local firstError = nil
    local function rememberError(err)
        if err and not firstError then firstError = err end
    end
    local function resolveActiveWindow(focused)
        if focused then return focused end
        for _, window in ipairs(state.openWindows) do
            if window.is_focused then return window end
        end
        local activeWindowId = nil
        for _, workspace in ipairs(state.workspaces) do
            if workspace.is_focused then activeWindowId = workspace.active_window_id end
        end
        if activeWindowId then
            for _, window in ipairs(state.openWindows) do
                if window.id == activeWindowId then return window end
            end
        end
        return nil
    end

    -- Noctalia bounds concurrent subprocesses per plugin. Run these short IPC
    -- In other words - Query Niri for the data needed by the window inspector, then render it.
    requestJson("niri msg -j windows", function(windows, windowsErr)
        if type(windows) == "table" then state.openWindows = windows else rememberError(windowsErr) end
        requestJson("niri msg -j workspaces", function(workspaces, workspacesErr)
            if type(workspaces) == "table" then state.workspaces = workspaces else rememberError(workspacesErr) end
            requestJson("niri msg -j outputs", function(outputs, outputsErr)
                if type(outputs) == "table" then
                    for name, _ in pairs(outputs) do table.insert(state.outputs, name) end
                    table.sort(state.outputs)
                else
                    rememberError(outputsErr)
                end
                requestJson("niri msg -j focused-window", function(focused, focusedErr)
                    rememberError(focusedErr)
                    state.window = resolveActiveWindow(focused)
                    state.loading = false
                    if state.window then
                        state.form.appId = state.window.app_id or ""
                        state.form.title = state.window.title or ""
                        state.status = tr("active_window", { app = state.window.app_id or tr("unknown_app") })
                        state.error = nil
                    elseif #state.openWindows > 0 then
                        state.status = tr("window_list_status")
                        state.error = nil
                    else
                        state.status = tr("window_missing_status")
                        state.error = firstError
                    end
                    panel.render(renderApp())
                end)
            end)
        end)
    end)
end

local function startNewRule()
    state.editing = nil
    state.editorRevision = state.editorRevision + 1
    state.page = "editor"
    state.form = {
        appId = state.window and state.window.app_id or "",
        title = state.window and state.window.title or "",
        matchTitle = false,
        mode = "tiled",
        workspace = "",
        output = "",
        width = "",
        height = "",
    }
    panel.render(renderApp())
end

local function editRule(index)
    local rule = state.rules[index]
    if not rule then return end
    state.editing = index
    state.editorRevision = state.editorRevision + 1
    state.page = "editor"
    state.form = {
        appId = rule.appId or "", title = rule.title or "", matchTitle = rule.matchTitle == true,
        mode = rule.mode or "tiled", workspace = rule.workspace or "", output = rule.output or "",
        width = rule.width or "", height = rule.height or "",
    }
    panel.render(renderApp())
end

local function saveEditor()
    local appId = trim(state.form.appId)
    if appId == "" then
        state.error = tr("error_app_id_required")
        panel.render(renderApp())
        return
    end
    local editingIndex = state.editing
    local previousRule = editingIndex and state.rules[editingIndex] or nil
    local rule = {
        appId = appId, title = trim(state.form.title), matchTitle = state.form.matchTitle,
        mode = state.form.mode, workspace = state.form.workspace, output = state.form.output,
        width = trim(state.form.width), height = trim(state.form.height),
        enabled = previousRule == nil or previousRule.enabled ~= false,
    }
    if editingIndex then state.rules[editingIndex] = rule else table.insert(state.rules, rule) end
    persistRules(
        function()
            state.editing = nil
            state.page = "rules"
        end,
        function()
            -- Keep a rejected candidate as an editor draft, not a managed rule while it's being edited.
            if editingIndex then
                state.rules[editingIndex] = previousRule
            else
                table.remove(state.rules, #state.rules)
            end
            state.page = "editor"
        end
    )
end

-- Panel lifecycle and declarative UI callbacks.
function onOpen()
    loadRules()
    state.page = "inspect"
    -- Refreshing here would replace the result returned by Niri's picker.
    if state.reopenAfterPick then
        state.reopenAfterPick = false
        state.loading = false
        panel.render(renderApp())
    else
        loadInspector()
    end
end

function onClose()
    -- Start after the panel closes so its click cannot select a window just for safe.
    if not state.pendingPick then return end
    state.pendingPick = false
    requestJson("niri msg -j pick-window", function(value, err)
        state.loading = false
        if value then
            state.window = value
            state.form.appId = value.app_id or ""
            state.form.title = value.title or ""
            state.status = tr("selected_window", { app = value.app_id or tr("unknown_app"), id = tostring(value.id or "—") })
            state.error = nil
        else
            state.error = err or tr("window_selection_cancelled")
            state.status = tr("no_window_selected")
        end
        noctalia.togglePanel(PANEL_ID)
    end)
end

-- Call all the functions for panels

function refreshFocusedWindow() loadInspector() end
function openNewRule() startNewRule() end
function showInspector() state.page = "inspect"; panel.render(renderApp()) end
function showRules() state.page = "rules"; panel.render(renderApp()) end
function showWindowChooser()
    state.windowQuery = ""
    state.page = "windows"
    panel.render(renderApp())
end
function closePanel() panel.close() end
function setWindowQuery(value)
    state.windowQuery = value or ""
    panel.render(renderApp())
end
function setAppId(value) state.form.appId = value end
function setTitle(value) state.form.title = value end
function setWidth(value) state.form.width = value end
function setHeight(value) state.form.height = value end
function setMatchTitle(value) state.form.matchTitle = value == "true"; panel.render(renderApp()) end
function setMode(index)
    state.form.mode = ({ "tiled", "floating", "fullscreen", "maximized", "maximized_edges" })[tonumber(index) + 1] or "tiled"
    panel.render(renderApp())
end
function setWorkspace(index) local opts = workspaceOptions(); local selected = tonumber(index) or 0; state.form.workspace = selected == 0 and "" or (opts[selected + 1] or ""); panel.render(renderApp()) end
function setOutput(index) local opts = outputOptions(); local selected = tonumber(index) or 0; state.form.output = selected == 0 and "" or (opts[selected + 1] or ""); panel.render(renderApp()) end
function saveCurrentRule() saveEditor() end
function cancelEditor() state.page = state.editing and "rules" or "inspect"; panel.render(renderApp()) end

function selectRule(index)
    editRule(tonumber(index))
end

function requestDeleteRule(index)
    state.pendingDelete = tonumber(index)
    state.page = "rules"
    panel.render(renderApp())
end

function cancelDeleteRule()
    state.pendingDelete = nil
    panel.render(renderApp())
end

function confirmDeleteRule(index)
    local ruleIndex = tonumber(index)
    if state.loading or not state.rules[ruleIndex] then return end
    local removed = table.remove(state.rules, ruleIndex)
    state.pendingDelete = nil
    persistRules(nil, function()
        table.insert(state.rules, ruleIndex, removed)
    end)
end

function setRuleEnabled(index, value)
    local rule = state.rules[tonumber(index)]
    if not rule or state.loading then return end
    local previous = rule.enabled
    rule.enabled = value == true or value == "true"
    persistRules(nil, function()
        rule.enabled = previous
    end)
end

function pickWindow()
    state.reopenAfterPick = true
    state.pendingPick = true
    state.status = tr("select_window_status")
    panel.close()
end

function chooseOpenWindow(index)
    local selected = state.openWindows[tonumber(index)]
    if not selected then return end
    state.window = selected
    state.form.appId = selected.app_id or ""
    state.form.title = selected.title or ""
    state.status = tr("selected_window", { app = selected.app_id or tr("unknown_app"), id = tostring(selected.id or "—") })
    state.error = nil
    state.page = "inspect"
    panel.render(renderApp())
end

-- Panel views rendering aproach
function renderApp()
    local nav = ui.row({ gap = 6 }, {
        ui.button({ text = tr("inspect"), variant = state.page == "inspect" and "primary" or "ghost", onClick = "showInspector" }),
        ui.button({ text = tr("managed_rules", { count = #state.rules }), variant = state.page == "rules" and "primary" or "ghost", onClick = "showRules" }),
        ui.spacer({ flexGrow = 1 }),
        ui.button({ glyph = "x", variant = "ghost", tooltip = tr("close"), onClick = "closePanel" }),
    })
    local body = state.page == "editor" and renderEditor()
        or (state.page == "rules" and renderRules()
        or (state.page == "windows" and renderWindowChooser() or renderInspector()))
    local children = { nav, ui.separator({ spacing = 4 }), body }
    if state.loading and not (state.page == "inspect" and not state.window) then
        table.insert(children, ui.label({ text = state.status, color = "primary", fontSize = 12 }))
    end
    if state.error then table.insert(children, ui.label({ text = "⚠ " .. state.error, color = "error", fontSize = 12, maxLines = 3 })) end
    return ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children)
end

function renderInspector()
    if state.loading and not state.window then
        return ui.column({ flexGrow = 1, align = "center", gap = 12 }, {
            ui.spacer({ flexGrow = 1 }),
            ui.glyph({ name = "refresh", size = 36, color = "primary" }),
            ui.label({ text = tr("inspecting"), fontSize = 16, fontWeight = "bold" }),
            ui.spacer({ flexGrow = 1 }),
        })
    end
    if not state.window then
        return ui.column({ flexGrow = 1, align = "stretch" }, {
            ui.spacer({ flexGrow = 1 }),
            ui.column({ gap = 12, align = "center" }, {
                ui.glyph({ name = "app-window", size = 42, color = "primary" }),
                ui.label({ text = tr("no_focused_window"), fontSize = 18, fontWeight = "bold" }),
                ui.label({ text = tr("window_list_fallback"), color = "on_surface_variant", fontSize = 12 }),
                ui.row({ gap = 8 }, {
                    ui.button({ text = tr("open_window_list"), glyph = "list", variant = "primary", onClick = "showWindowChooser", enabled = #state.openWindows > 0 }),
                    ui.button({ text = tr("pick_on_screen"), glyph = "crosshair", variant = "outline", onClick = "pickWindow" }),
                    ui.button({ text = tr("refresh"), glyph = "refresh", variant = "ghost", onClick = "refreshFocusedWindow" }),
                }),
            }),
            ui.spacer({ flexGrow = 1 }),
        })
    end
    local workspace = "—"
    for _, item in ipairs(state.workspaces) do if item.id == state.window.workspace_id then workspace = item.name or ("Workspace " .. tostring(item.idx)) end end
    return ui.column({ flexGrow = 1, gap = 14, align = "stretch" }, {
        ui.row({ gap = 10, align = "center" }, {
            ui.glyph({ name = "app-window", size = 28, color = "primary" }),
            ui.column({ gap = 2, flexGrow = 1 }, {
                ui.label({ text = state.window.title or tr("untitled_window"), fontSize = 18, fontWeight = "bold", maxLines = 2 }),
                ui.label({ text = state.window.app_id or tr("no_app_id"), color = "on_surface_variant" }),
            }),
        }),
        ui.column({ gap = 7, padding = 12, fill = "surface_variant/0.45", radius = 10 }, {
            ui.label({ text = tr("window_inspector"), fontSize = 11, fontWeight = "bold", color = "primary" }),
            ui.label({ text = tr("app_id") .. "   " .. (state.window.app_id or "—") }),
            ui.label({ text = tr("workspace") .. "   " .. workspace }),
            ui.label({ text = tr("floating") .. "   " .. (state.window.is_floating and tr("yes") or tr("no")) }),
            ui.label({ text = tr("pid") .. "   " .. tostring(state.window.pid or "—") }),
        }),
        ui.button({ text = tr("create_rule"), glyph = "plus", variant = "primary", controlSize = "lg", onClick = "openNewRule" }),
        ui.row({ gap = 8 }, {
            ui.button({ text = tr("pick_on_screen"), glyph = "crosshair", variant = "outline", onClick = "pickWindow" }),
            ui.button({ text = tr("open_window_list"), glyph = "list", variant = "outline", onClick = "showWindowChooser" }),
            ui.button({ text = tr("refresh"), glyph = "refresh", variant = "ghost", onClick = "refreshFocusedWindow" }),
        }),
    })
end

function renderWindowChooser()
    local query = trim(state.windowQuery):lower()
    local matches = {}
    for index, window in ipairs(state.openWindows) do
        local searchable = table.concat({
            tostring(window.app_id or ""),
            tostring(window.title or ""),
            tostring(window.id or ""),
        }, " "):lower()
        if query == "" or searchable:find(query, 1, true) then
            table.insert(matches, { index = index, window = window })
        end
    end
    table.sort(matches, function(left, right)
        local leftSelected = state.window and state.window.id == left.window.id
        local rightSelected = state.window and state.window.id == right.window.id
        if leftSelected ~= rightSelected then return leftSelected end
        local leftName = tostring(left.window.app_id or "") .. "\0" .. tostring(left.window.title or "")
        local rightName = tostring(right.window.app_id or "") .. "\0" .. tostring(right.window.title or "")
        return leftName:lower() < rightName:lower()
    end)

    local rows = {}
    if #matches == 0 then
        table.insert(rows, ui.column({ align = "center", gap = 8, paddingV = 32 }, {
            ui.glyph({ name = "search", size = 30, color = "on_surface_variant" }),
            ui.label({
                text = #state.openWindows == 0 and tr("no_open_windows") or tr("no_matching_windows"),
                color = "on_surface_variant",
            }),
        }))
    else
        for _, item in ipairs(matches) do
            local window = item.window
            local appId = window.app_id or tr("unknown_app")
            local windowId = tostring(window.id or "—")
            table.insert(rows, ui.column({
                key = "window-" .. windowId,
                padding = 11,
                gap = 4,
                fill = state.window and state.window.id == window.id and "primary/0.14" or "surface_variant/0.4",
                radius = 9,
                border = state.window and state.window.id == window.id and "primary" or "outline",
                onClick = function() chooseOpenWindow(item.index) end,
            }, {
                ui.row({ gap = 8, align = "center" }, {
                    ui.label({ text = appId, fontWeight = "bold", color = "primary", flexGrow = 1 }),
                    ui.label({ text = "ID " .. windowId, fontSize = 11, color = "on_surface_variant" }),
                }),
                ui.label({ text = window.title or tr("untitled_window"), fontSize = 12, color = "on_surface_variant", maxLines = 2 }),
            }))
        end
    end

    return ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.button({ glyph = "arrow-left", variant = "ghost", tooltip = tr("back"), onClick = "showInspector" }),
            ui.column({ gap = 2, flexGrow = 1 }, {
                ui.label({ text = tr("choose_window"), fontSize = 20, fontWeight = "bold" }),
                ui.label({ text = tr("choose_window_help"), fontSize = 12, color = "on_surface_variant" }),
            }),
        }),
        ui.input({
            key = "window-search",
            value = state.windowQuery,
            placeholder = tr("search_windows"),
            onChange = "setWindowQuery",
        }),
        ui.label({
            text = #matches == 1 and tr("window_count_one") or tr("window_count", { count = #matches }),
            fontSize = 11,
            color = "on_surface_variant",
        }),
        ui.scroll({ key = "window-results", flexGrow = 1, gap = 9 }, rows),
    })
end

function renderEditor()
    local modeIndex = ({ tiled = 0, floating = 1, fullscreen = 2, maximized = 3, maximized_edges = 4 })[state.form.mode] or 0
    local showInitialSize = modeUsesInitialSize(state.form.mode)
    local modeHelp = ({
        tiled = tr("mode_tiled_help"),
        floating = tr("mode_floating_help"),
        fullscreen = tr("mode_fullscreen_help"),
        maximized = tr("mode_maximized_help"),
        maximized_edges = tr("mode_maximized_edges_help"),
    })[state.form.mode] or ""
    return ui.scroll({ key = "editor-" .. tostring(state.editorRevision), flexGrow = 1, gap = 12 }, {
        ui.label({ text = state.editing and tr("edit_rule") or tr("quick_rule"), fontSize = 20, fontWeight = "bold" }),
        ui.label({ text = tr("match_help"), color = "on_surface_variant", maxLines = 2 }),
        ui.label({ text = tr("when"), fontSize = 11, fontWeight = "bold", color = "primary" }),
        ui.input({ key = "app-id", value = state.form.appId, placeholder = tr("app_id"), onChange = "setAppId" }),
        ui.row({ gap = 12, padding = 10, align = "center", fill = "surface_variant/0.4", radius = 9 }, {
            ui.column({ gap = 2, flexGrow = 1 }, {
                ui.label({ text = tr("also_match_title"), fontWeight = "bold" }),
                ui.label({ text = tr("also_match_title_help"), fontSize = 11, color = "on_surface_variant", maxLines = 2 }),
            }),
            ui.toggle({ width = 46, checked = state.form.matchTitle, onChange = "setMatchTitle" }),
        }),
        ui.input({ key = "title", value = state.form.title, placeholder = tr("title_regex"), visible = state.form.matchTitle, enabled = state.form.matchTitle, onChange = "setTitle" }),
        ui.label({ text = tr("then"), fontSize = 11, fontWeight = "bold", color = "primary" }),
        ui.label({ text = tr("opening_rule_notice"), color = "on_surface_variant", fontSize = 12, maxLines = 2 }),
        ui.select({
            options = {
                tr("mode_tiled"),
                tr("mode_floating"),
                tr("mode_fullscreen"),
                tr("mode_maximized"),
                tr("mode_maximized_edges"),
            },
            selectedIndex = modeIndex,
            onChange = "setMode",
        }),
        ui.label({ text = modeHelp, fontSize = 12, color = "on_surface_variant", maxLines = 2 }),
        ui.select({ options = workspaceOptions(), selectedIndex = optionIndex(workspaceOptions(), state.form.workspace == "" and tr("no_workspace_rule") or state.form.workspace), onChange = "setWorkspace" }),
        ui.select({ options = outputOptions(), selectedIndex = optionIndex(outputOptions(), state.form.output == "" and tr("no_output_rule") or state.form.output), onChange = "setOutput" }),
        ui.column({ gap = 8, visible = showInitialSize }, {
            ui.label({ text = tr("initial_size_help"), fontSize = 12, color = "on_surface_variant", maxLines = 2 }),
            ui.row({ gap = 8 }, {
                ui.input({ key = "width", value = state.form.width, placeholder = tr("default_width"), onChange = "setWidth", flexGrow = 1 }),
                ui.input({ key = "height", value = state.form.height, placeholder = tr("default_height"), onChange = "setHeight", flexGrow = 1 }),
            }),
        }),
        ui.row({ gap = 8, justify = "end" }, {
            ui.button({ text = tr("cancel"), variant = "ghost", onClick = "cancelEditor" }),
            ui.button({ text = tr("save"), glyph = "device-floppy", variant = "primary", onClick = "saveCurrentRule", enabled = not state.loading }),
        }),
    })
end

function renderRules()
    local rows = {}
    local activeCount = 0
    for _, rule in ipairs(state.rules) do if rule.enabled ~= false then activeCount = activeCount + 1 end end
    if #state.rules == 0 then
        table.insert(rows, ui.column({ align = "center", gap = 8, paddingV = 40 }, {
            ui.glyph({ name = "list-details", size = 34, color = "on_surface_variant" }),
            ui.label({ text = tr("no_managed_rules"), fontWeight = "bold" }),
            ui.label({ text = tr("no_managed_rules_help"), color = "on_surface_variant" }),
        }))
    else
        for index, rule in ipairs(state.rules) do
            local ruleEnabled = rule.enabled ~= false
            local behavior = rule.mode or "tiled"
            if rule.workspace and rule.workspace ~= "" then behavior = behavior .. " · " .. rule.workspace end
            if not ruleEnabled then behavior = tr("disabled") .. " · " .. behavior end
            local rowChildren = {
                ui.column({ gap = 2, flexGrow = 1, onClick = function() selectRule(index) end }, {
                    ui.label({ text = rule.appId or tr("unknown_app"), fontWeight = "bold", color = ruleEnabled and "on_surface" or "on_surface_variant" }),
                    ui.label({ text = behavior, fontSize = 12, color = "on_surface_variant" }),
                }),
            }
            if state.pendingDelete == index then
                table.insert(rowChildren, ui.label({ text = tr("confirm_delete"), fontSize = 12, color = "error" }))
                table.insert(rowChildren, ui.button({ text = tr("cancel"), variant = "ghost", controlSize = "sm", onClick = "cancelDeleteRule" }))
                table.insert(rowChildren, ui.button({ text = tr("delete"), glyph = "trash", variant = "primary", controlSize = "sm", onClick = function() confirmDeleteRule(index) end }))
            else
                table.insert(rowChildren, ui.toggle({ checked = ruleEnabled, enabled = not state.loading, onChange = function(value) setRuleEnabled(index, value) end }))
                table.insert(rowChildren, ui.button({ glyph = "trash", variant = "ghost", tooltip = tr("delete_rule"), onClick = function() requestDeleteRule(index) end }))
            end
            table.insert(rows, ui.row({ key = "rule-" .. tostring(index), padding = 10, gap = 8, fill = ruleEnabled and "surface_variant/0.35" or "surface_variant/0.18", radius = 9, align = "center" }, rowChildren))
        end
    end
    return ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, {
        ui.row({ align = "center" }, {
            ui.column({ gap = 2, flexGrow = 1 }, {
                ui.label({ text = tr("managed_rules_title"), fontSize = 20, fontWeight = "bold" }),
                ui.label({ text = tr("managed_rules_help") .. " " .. tr("active_count", { active = activeCount }) .. ".", fontSize = 12, color = "on_surface_variant" }),
            }),
            ui.button({ text = tr("new"), glyph = "plus", variant = "primary", onClick = "openNewRule" }),
        }),
        ui.scroll({ key = "managed-rules", flexGrow = 1, gap = 10 }, rows),
    })
end
