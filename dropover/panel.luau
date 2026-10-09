--!nonstrict
-- Dropover Panel for Noctalia with Thumbnails & Quick Look

local STATE_KEY = "dropover_count"
local items = {}

local function getPluginDir()
    local dir = noctalia.pluginDir() or "~/.config/noctalia/plugins/dropover"
    return noctalia.expandPath(dir)
end

local function getShelfFilePath()
    if noctalia.pluginDataDir then
        local dataDir = noctalia.pluginDataDir()
        if dataDir and dataDir ~= "" then
            return dataDir .. "/shelf.json"
        end
    end
    local standardPath = noctalia.expandPath("~/.local/state/noctalia/plugins/data/pyrider3/dropover/shelf.json")
    if noctalia.fileExists(standardPath) then
        return standardPath
    end
    return getPluginDir() .. "/shelf.json"
end

local function getCoreScript()
    return getPluginDir() .. "/dropover_core.py"
end

local function getDndScript()
    return getPluginDir() .. "/dropover_dnd.py"
end

local function getShelfUiScript()
    return getPluginDir() .. "/dropover_shelf_ui.py"
end

local function getQuicklookScript()
    return getPluginDir() .. "/dropover_quicklook.py"
end

local function formatSize(bytes)
    if bytes < 1024 then
        return bytes .. " B"
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    else
        return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
    end
end

local function getGlyph(path, isDir)
    if isDir then
        return "folder"
    end
    local ext = string.lower(string.match(path, "%.([^%.]+)$") or "")
    if ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "webp" or ext == "gif" or ext == "svg" then
        return "photo"
    elseif ext == "mp4" or ext == "mkv" or ext == "webm" or ext == "avi" or ext == "mov" then
        return "video"
    elseif ext == "mp3" or ext == "flac" or ext == "wav" or ext == "ogg" or ext == "m4a" then
        return "music"
    elseif ext == "zip" or ext == "tar" or ext == "gz" or ext == "7z" or ext == "rar" or ext == "zst" then
        return "file-zip"
    elseif ext == "py" or ext == "lua" or ext == "luau" or ext == "sh" or ext == "js" or ext == "ts" or ext == "rs" or ext == "c" or ext == "cpp" or ext == "kdl" or ext == "toml" or ext == "json" then
        return "code"
    elseif ext == "pdf" or ext == "txt" or ext == "md" or ext == "doc" or ext == "docx" or ext == "csv" then
        return "file-text"
    else
        return "file"
    end
end

local function saveItems()
    local encoded = noctalia.json.encode(items, true)
    if encoded then
        noctalia.writeFile(getShelfFilePath(), encoded)
        noctalia.state.set(STATE_KEY, #items)
    end
end

local function loadItems()
    local raw = noctalia.readFile(getShelfFilePath())
    if raw then
        local data = noctalia.json.decode(raw)
        if type(data) == "table" then
            items = data
        else
            items = {}
        end
    else
        items = {}
    end
    noctalia.state.set(STATE_KEY, #items)
end

local render

local function reloadAndRender()
    loadItems()
    render()
end

function onCloseClicked()
    panel.close()
end

function onPasteClipboardClicked()
    local cmd = "python3 '" .. getCoreScript() .. "' from-clipboard"
    noctalia.runAsync(cmd, function(res)
        local added = tonumber(res.stdout) or 0
        if added > 0 then
            noctalia.notify("Dropover", "已从剪贴板添加 " .. added .. " 个文件")
        else
            noctalia.notify("Dropover", "剪贴板中未找到复制的文件 (可先在文件管理器中 Ctrl+C)")
        end
        reloadAndRender()
    end, 5000)
end

function onPickFilesClicked()
    local cmd = "python3 '" .. getCoreScript() .. "' pick"
    noctalia.runAsync(cmd, function(res)
        reloadAndRender()
    end, 60000)
end

function onDropTargetClicked()
    local cmd = "python3 '" .. getDndScript() .. "' drop"
    noctalia.runAsync(cmd, function()
        reloadAndRender()
    end, 60000)
end

function onClearAllClicked()
    items = {}
    saveItems()
    reloadAndRender()
end

function onCopyAllClicked()
    if #items == 0 then
        return
    end
    local cmd = "python3 '" .. getCoreScript() .. "' copy-all"
    noctalia.runAsync(cmd, function()
        noctalia.notify("Dropover", "已复制所有暂存文件到剪贴板，可在目标窗口按 Ctrl+V 粘贴")
    end, 5000)
end

function onLaunchDragShelfClicked()
    panel.close()
    noctalia.runAsync("python3 '" .. getShelfUiScript() .. "'")
end

function onOpenFolderClicked()
    if #items > 0 then
        local firstPath = items[1]
        local dir = string.match(firstPath, "^(.*)/[^/]+$") or firstPath
        noctalia.runAsync("nautilus '" .. dir .. "' &")
    else
        noctalia.runAsync("nautilus ~ &")
    end
end

-- 快捷按键处理 (Space 快速预览第一项，1..9 秒复制对应序号文件)
function onKey(chord, pressed)
    if not pressed then
        return
    end
    if chord == "Space" then
        if #items > 0 then
            local target = items[1]
            noctalia.runAsync("python3 '" .. getQuicklookScript() .. "' '" .. target .. "'")
        end
    elseif chord >= "1" and chord <= "9" then
        local idx = tonumber(chord)
        if idx and idx <= #items then
            local target = items[idx]
            local cmd = "python3 '" .. getCoreScript() .. "' copy-one '" .. target .. "'"
            noctalia.runAsync(cmd, function()
                local name = string.match(target, "[^/]+$") or target
                noctalia.notify("Dropover", "[" .. chord .. "] 已复制「" .. name .. "」，可按 Ctrl+V 粘贴")
            end, 3000)
        end
    end
end

render = function()
    local fileRows = {}

    if #items == 0 then
        table.insert(fileRows, ui.column({
            align = "center",
            justify = "center",
            gap = 12,
            padding = 36,
            fill = "surface_variant/0.2",
            radius = 16,
        }, {
            ui.glyph({ name = "inbox", size = 48, color = "on_surface_variant" }),
            ui.label({ text = "暂存架空空如也", fontSize = 15, fontWeight = "bold", color = "on_surface" }),
            ui.label({
                text = "• Nautilus 中右键任意文件 →「暂存到 Dropover」\n• 拖拽中随时按 Super+Z 唤起就地磁吸区\n• 文件管理器中 Ctrl+C 复制后点击「剪贴板存入」",
                textAlign = "center",
                fontSize = 12,
                color = "on_surface_variant",
            }),
        }))
    else
        for idx, path in ipairs(items) do
            local currentPath = path
            local currentIndex = idx
            local exists = noctalia.fileExists(currentPath)
            local info = exists and noctalia.fileInfo(currentPath) or nil
            local name = string.match(currentPath, "[^/]+$") or currentPath
            local ext = string.lower(string.match(currentPath, "%.([^%.]+)$") or "")
            local isImage = ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "webp" or ext == "gif" or ext == "svg"
            local isDir = info and info.isDir or false
            local glyph = exists and getGlyph(currentPath, isDir) or "alert-circle"
            local sizeStr = ""
            if not exists then
                sizeStr = "文件已不存在"
            elseif isDir then
                sizeStr = "文件夹"
            elseif info then
                sizeStr = formatSize(info.size)
            end

            -- 缩略图或类型图标
            local thumbView
            if isImage and exists then
                thumbView = ui.image({
                    path = currentPath,
                    width = 48,
                    height = 48,
                    radius = 8,
                    fit = "cover",
                    onClick = function()
                        noctalia.runAsync("python3 '" .. getQuicklookScript() .. "' '" .. currentPath .. "'")
                    end,
                    tooltip = "点击或按 Space 大图预览 (Quick Look)",
                })
            else
                thumbView = ui.column({
                    width = 48,
                    height = 48,
                    radius = 8,
                    fill = "surface_variant/0.4",
                    align = "center",
                    justify = "center",
                }, {
                    ui.glyph({ name = glyph, size = 26, color = exists and "primary" or "error" }),
                })
            end

            table.insert(fileRows, ui.row({
                key = "item-" .. tostring(currentIndex) .. "-" .. name,
                align = "center",
                justify = "space_between",
                gap = 12,
                padding = 10,
                fill = "surface_variant/0.3",
                radius = 14,
            }, {
                ui.row({ align = "center", gap = 12, flexGrow = 1 }, {
                    thumbView,
                    ui.column({ gap = 3, flexGrow = 1 }, {
                        ui.row({ align = "center", gap = 6 }, {
                            ui.label({
                                text = "[" .. tostring(currentIndex) .. "]",
                                fontSize = 11,
                                fontWeight = "bold",
                                color = "primary",
                            }),
                            ui.label({
                                text = name,
                                fontWeight = "semibold",
                                fontSize = 13,
                                color = "on_surface",
                            }),
                        }),
                        ui.row({ align = "center", gap = 8 }, {
                            ui.label({ text = sizeStr, fontSize = 11, color = "on_surface_variant" }),
                            ui.label({
                                text = string.upper(ext ~= "" and ext or (isDir and "DIR" or "FILE")),
                                fontSize = 10,
                                fontWeight = "bold",
                                color = "primary/0.8",
                            }),
                        }),
                    }),
                }),

                -- 操作按钮组
                ui.row({ align = "center", gap = 4 }, {
                    ui.button({
                        glyph = "eye",
                        tooltip = "快速预览 (Quick Look)",
                        variant = "ghost",
                        controlSize = "sm",
                        onClick = function()
                            noctalia.runAsync("python3 '" .. getQuicklookScript() .. "' '" .. currentPath .. "'")
                        end,
                    }),
                    ui.button({
                        glyph = "copy",
                        tooltip = "复制到剪贴板 (按键 " .. tostring(currentIndex) .. " 或 Ctrl+V 粘贴)",
                        variant = "secondary",
                        controlSize = "sm",
                        onClick = function()
                            local cmd = "python3 '" .. getCoreScript() .. "' copy-one '" .. currentPath .. "'"
                            noctalia.runAsync(cmd, function()
                                noctalia.notify("Dropover", "已复制「" .. name .. "」，可按 Ctrl+V 粘贴")
                            end, 3000)
                        end,
                    }),
                    ui.button({
                        glyph = "arrow-up-right",
                        tooltip = "拖出文件到目标窗口",
                        variant = "secondary",
                        controlSize = "sm",
                        onClick = function()
                            panel.close()
                            noctalia.runAsync("python3 '" .. getShelfUiScript() .. "'")
                        end,
                    }),
                    ui.button({
                        glyph = "trash",
                        tooltip = "从暂存架移除",
                        variant = "ghost",
                        controlSize = "sm",
                        onClick = function()
                            table.remove(items, currentIndex)
                            saveItems()
                            reloadAndRender()
                        end,
                    }),
                }),
            }))
        end
    end

    panel.render(ui.column({ flexGrow = 1, gap = 12, padding = 16 }, {
        -- 顶部标题与快速统计
        ui.row({ align = "center", justify = "space_between", gap = 8 }, {
            ui.row({ align = "center", gap = 8 }, {
                ui.glyph({ name = "inbox", size = 22, color = "primary" }),
                ui.label({ text = "Dropover 暂存架", fontSize = 16, fontWeight = "bold", color = "on_surface" }),
                ui.label({ text = "(" .. tostring(#items) .. ")", fontSize = 13, color = "primary" }),
            }),
            ui.row({ align = "center", gap = 6 }, {
                ui.button({ glyph = "folder", tooltip = "在文件管理器打开所在目录", variant = "ghost", onClick = "onOpenFolderClicked" }),
                ui.button({ glyph = "close", tooltip = "关闭面板", variant = "ghost", onClick = "onCloseClicked" }),
            }),
        }),

        -- 快捷动作栏
        ui.row({ align = "center", gap = 8 }, {
            ui.button({
                text = "剪贴板存入",
                glyph = "clipboard",
                variant = "primary",
                controlSize = "sm",
                flexGrow = 1,
                tooltip = "将当前复制的文件存入 (Ctrl+C 后的文件)",
                onClick = "onPasteClipboardClicked",
            }),
            ui.button({
                text = "磁吸收集",
                glyph = "drag-drop",
                variant = "secondary",
                controlSize = "sm",
                flexGrow = 1,
                tooltip = "打开浮动拖拽收集窗口 (快捷键 Super+Z)",
                onClick = "onDropTargetClicked",
            }),
            ui.button({
                text = "随身拖出",
                glyph = "arrow-up-right",
                variant = "secondary",
                controlSize = "sm",
                flexGrow = 1,
                tooltip = "呼出随身拖拽货架 (快捷键 Super+Shift+Z)",
                onClick = "onLaunchDragShelfClicked",
            }),
        }),

        ui.separator({ orientation = "horizontal", color = "outline/0.2" }),

        -- 提示条：快捷操作说明
        ui.row({ align = "center", justify = "space_between" }, {
            ui.label({ text = "提示：按数字键 1~9 秒复制对应文件 • 按 Space 预览首项", fontSize = 11, color = "on_surface_variant" }),
        }),

        -- 滚动列表
        ui.scroll({ flexGrow = 1, gap = 8 }, fileRows),

        ui.separator({ orientation = "horizontal", color = "outline/0.2" }),

        -- 底部批量操作
        ui.row({ align = "center", justify = "space_between", gap = 8 }, {
            ui.button({
                text = "复制全部文件",
                glyph = "copy",
                variant = "secondary",
                enabled = #items > 0,
                tooltip = "批量复制所有文件到剪贴板 (Ctrl+V 一次性粘贴全部)",
                onClick = "onCopyAllClicked",
            }),
            ui.button({
                text = "全部清空",
                glyph = "trash",
                variant = "destructive",
                enabled = #items > 0,
                tooltip = "清空暂存架",
                onClick = "onClearAllClicked",
            }),
        }),
    }))
end

function onOpen(_context)
    reloadAndRender()
end
