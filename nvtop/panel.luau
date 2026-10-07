--!nonstrict

-- Data from the nvtop command, which is updated in real-time.
local nvtop_data = {}
-- The PID of the nvtop process, which is used to terminate the process when the panel is closed.
local nvtop_pid = -1
-- The index of the currently selected GPU, which is used to display the correct GPU info.
local selected_gpu = 1
-- Set when run_nvtop.py finished with error
local g_error_message = nil

local g_gpu_graph_path = nil
local g_mem_graph_path = nil

-- Data load time in milliseconds. Used as part of key for gauge images controls.
local g_data_load_ms = "none"

local g_order_by_context = "mem"

-- Forward declaration of the render function to allow it to be called from other functions.
local render

-- Get the file path for the stats data.
local function get_params_file_path()
    local path = noctalia.getenv("XDG_RUNTIME_DIR") or "/dev/shm"
    return path .. "/noctalia_tordex_nvtop_params"
end

local function write_params()
    local params = tostring(selected_gpu)

    noctalia.writeFile(get_params_file_path(), params)
end


-- Render a single row of GPU info with a label, value, and glyph.
local function gpu_info_row(label, value, glyph)
    return ui.row({
        gap = 8,
    },{
        ui.glyph({
            name = glyph,
            color = "on_surface_variant",
        }),
        ui.label({
            text = label .. ":",
            color = "on_surface_variant",
        })
    }), ui.label({
            text = value,
            flexGrow = 1,
            fontWeight = "bold",
            color = "on_surface_variant",
        })
end

-- Helper function to check if a string starts with a given prefix.
local function starts_with(str: string, prefix: string): boolean
    return string.sub(str, 1, #prefix) == prefix
end

-- Format memory size in bytes to a human-readable string in M or G.
local function format_memory_size(size_in_bytes)
    local size_in_mb = size_in_bytes / (1024 * 1024)
    if size_in_mb >= 1024 then
        local size_in_gb = size_in_mb / 1024
        return string.format("%.2f G", size_in_gb)
    else
        return string.format("%.1f M", size_in_mb)
    end
end

-- Render a message when there is no data available.
local function render_no_data_message()
    if #nvtop_data == 0 then
        if g_error_message == nil then
            panel.render(ui.row({
                key = "no-data-row",
                fill = "surface_variant",
                border = "outline",
                padding = 16,
                radius = 12,
                gap = 8,
            },{
                ui.glyph({
                    key = "no-data-glyph",
                    name = "info-circle",
                    color = "on_surface_variant",
                    size = 20,
                }),
                ui.label({
                    key = "no-data-label",
                    text = noctalia.tr("nvtop.nodata"),
                    color = "on_surface_variant",
                    fontSize = 20,
                })
            }))
        else
            panel.render(ui.column({
                key = "no-data-row",
                fill = "error",
                border = "outline",
                padding = 16,
                radius = 12,
                gap = 8,
            },{
                ui.row({
                    key = "no-data-row",
                    fill = "error",
                    gap = 8,
                },{
                    ui.glyph({
                        key = "no-data-glyph",
                        name = "exclamation-circle",
                        color = "on_error",
                        size = 20,
                    }),
                    ui.label({
                        key = "no-data-label",
                        text = noctalia.tr("nvtop.nodata"),
                        color = "on_error",
                        fontSize = 20,
                    })
                }),
                ui.label({
                    key = "no-data-label",
                    text = g_error_message,
                    color = "on_error",
                })
            }))
        end
        return true
    end
    return false
end

-- Render the list of GPUs as buttons, and highlight the selected GPU.
local function render_gpu_list(selected_idx)
    local children = {
        ui.glyph({ name = "cpu", size = 16 }),
        ui.label({
            key = "title",
            text = "NVTOP",
            fontSize = 16,
            fontWeight = "bold",
            color = "on_surface",
        }),
        ui.spacer({ key = "title-gap-2", flexGrow = 0, width = 8 }),
    }
    for idx, gpu in ipairs(nvtop_data) do
        table.insert(children,
            ui.button({
                selected = idx == selected_idx,
                glyph = "cpu",
                text = gpu.device_name,
                variant = "outline",
                onClick = function()
                    selected_gpu = idx
                    write_params()
                    render()
                end
            })
        )
    end

    table.insert(children,
        ui.spacer({ key = "title-gap-2", flexGrow = 1 })
    )
    table.insert(children,
        ui.button({
            key = "settings",
            glyph = "settings",
            variant = "ghost",
            tooltip = noctalia.tr("tip_settings"),
            onClick = function()
                noctalia.openSettings()
            end,
        })
    )
    table.insert(children,
        ui.button({
            key = "close",
            glyph = "close",
            variant = "ghost",
            tooltip = noctalia.tr("tip_close"),
            onClick = function()
                panel.close()
            end,
        })
    )

    return ui.row({
        gap = 4,
        align = "center",
    }, children)
end

-- Define the GPU info rows to display in the panel.
local gpu_info = {
    {
        label = noctalia.tr("nvtop.gpu_load"),
        glyph = "brand-speedtest",
        data_key = "gpu_util",
        func = function(value) return value end,
        column = 1
    },
    {
        label = noctalia.tr("nvtop.gpu_clock"),
        glyph = "bolt",
        data_key = "gpu_clock",
        func = function(value) return value end,
        column = 1
    },
    {
        label = noctalia.tr("nvtop.temperature"),
        glyph = "temperature",
        data_key = "temp",
        func = function(value) return value end,
        column = 1
    },
    {
        label = noctalia.tr("nvtop.fan_speed"),
        glyph = "car-fan",
        data_key = "fan_speed",
        func = function(value) return value end,
        column = 1
    },
    {
        label = noctalia.tr("nvtop.power"),
        glyph = "bolt",
        data_key = "power_draw",
        func = function(value) return value end,
        column = 1
    },
    {
        label = noctalia.tr("nvtop.memory_clock"),
        glyph = "bolt",
        data_key = "mem_clock",
        func = function(value) return value end,
        column = 2
    },
    {
        label = noctalia.tr("nvtop.memory_total"),
        glyph = "cpu-2",
        data_key = "mem_total",
        func = format_memory_size,
        column = 2
    },
    {
        label = noctalia.tr("nvtop.memory_used"),
        glyph = "cpu-2",
        data_key = "mem_used",
        func = format_memory_size,
        column = 2
    },
    {
        label = noctalia.tr("nvtop.memory_free"),
        glyph = "cpu-2",
        data_key = "mem_free",
        func = format_memory_size,
        column = 2
    },
}

-- Render the GPU info for the selected GPU.
local function render_gpu_info(selected_idx)
    local columns = {
        {
            labels = {},
            values = {},
        },
        {
            labels = {},
            values = {},
        }
    }

    for _, info in ipairs(gpu_info) do
        if nvtop_data[selected_idx][info.data_key] ~= nil then
            local label, value = gpu_info_row(info.label, info.func(nvtop_data[selected_idx][info.data_key]), info.glyph)
            table.insert(columns[info.column].labels, label)
            table.insert(columns[info.column].values, value)
        end
    end

    local children = {}
    for _, column in ipairs(columns) do
        table.insert(children, ui.column({
            gap = 1,
        }, column.labels))
        table.insert(children, ui.column({
            gap = 1,
            flexGrow = 1,
        }, column.values))
    end

    -- Include the GPU and memory graph images if available.
    if g_gpu_graph_path ~= nil and noctalia.fileExists(g_gpu_graph_path) then
        table.insert(children, ui.image({
            key = "img-gpu-" .. g_data_load_ms,
            path = g_gpu_graph_path,
            width = 110,
            height = 110,
        }))
    end
    if g_mem_graph_path ~= nil and noctalia.fileExists(g_mem_graph_path) then
        table.insert(children, ui.image({
            key = "img-mem-" .. g_data_load_ms,
            path = g_mem_graph_path,
            width = 110,
            height = 110,
        }))
    end

    return ui.row({
        gap = 8,
        padding = 8,
        radius = 12,
        border = "outline",
        fill = "surface_variant",
        borderWidth = 1,
    }, children)
end

local function persent_to_number(value)
    if value == nil then
        return 0
    end
    local number = tonumber(value:match("(%d+)%%"))
    return number or 0
end

-- Define the process data columns to display in the panel.
local processes_data = {
    {
        data_key = "pid",
        context_key = {"pid"},
        label = noctalia.tr("nvtop.process.pid.label"),
        tip = noctalia.tr("nvtop.process.pid.tip"),
        flexGrow = 2,
        textAlign = "end",
        process_value = function(value) return value end,
        sort_value = function(value) return tonumber(value) end
    },
    {
        data_key = "gpu_usage",
        context_key = {"gpu"},
        label = noctalia.tr("nvtop.process.gpu_usage.label"),
        tip = noctalia.tr("nvtop.process.gpu_usage.tip"),
        flexGrow = 1.5,
        textAlign = "end",
        process_value = function(value) return value or "n/a" end,
        sort_value = function(value) return persent_to_number(value) end
    },
    {
        data_key = "encode",
        context_key = {"enc"},
        label = noctalia.tr("nvtop.process.encode.label"),
        tip = noctalia.tr("nvtop.process.encode.tip"),
        flexGrow = 1.5,
        textAlign = "end",
        process_value = function(value) return value or "n/a" end,
        sort_value = function(value) return persent_to_number(value) end
    },
    {
        data_key = "decode",
        context_key = {"dec"},
        label = noctalia.tr("nvtop.process.decode.label"),
        tip = noctalia.tr("nvtop.process.decode.tip"),
        flexGrow = 1.5,
        textAlign = "end",
        process_value = function(value) return value or "n/a" end,
        sort_value = function(value) return persent_to_number(value) end
    },
    {
        data_key = "gpu_mem_bytes_alloc",
        context_key = {"mem"},
        label = noctalia.tr("nvtop.process.gpu_mem.label"),
        tip = noctalia.tr("nvtop.process.gpu_mem.tip"),
        flexGrow = 2.3,
        textAlign = "end",
        process_value = function(value) return value ~= nil and format_memory_size(value) or "n/a" end,
        sort_value = function(value) return tonumber(value) end,
    },
    {
        data_key = "cmdline",
        context_key = {"cmd"},
        label = noctalia.tr("nvtop.process.cmdline.label"),
        tip = noctalia.tr("nvtop.process.cmdline.tip"),
        flexGrow = 8,
        textAlign = "start",
        process_value = function(value) return value end,
        sort_value = function(value) return tostring(value) end,
    },
}

-- Define the process data columns to display in the panel.
local processes_data_shared_encode_decode = {
    {
        data_key = "pid",
        context_key = {"pid"},
        label = noctalia.tr("nvtop.process.pid.label"),
        tip = noctalia.tr("nvtop.process.pid.tip"),
        flexGrow = 2,
        textAlign = "end",
        process_value = function(value) return value end,
        sort_value = function(value) return tonumber(value) end
    },
    {
        data_key = "gpu_usage",
        context_key = {"gpu"},
        label = noctalia.tr("nvtop.process.gpu_usage.label"),
        tip = noctalia.tr("nvtop.process.gpu_usage.tip"),
        flexGrow = 1.5,
        textAlign = "end",
        process_value = function(value) return value or "n/a" end,
        sort_value = function(value) return persent_to_number(value) end
    },
    {
        data_key = "encode_decode",
        context_key = {"enc", "dec"},
        label = noctalia.tr("nvtop.process.encode_decode.label"),
        tip = noctalia.tr("nvtop.process.encode_decode.tip"),
        flexGrow = 2,
        textAlign = "end",
        process_value = function(value) return value or "n/a" end,
        sort_value = function(value) return persent_to_number(value) end
    },
    {
        data_key = "gpu_mem_bytes_alloc",
        context_key = {"mem"},
        label = noctalia.tr("nvtop.process.gpu_mem.label"),
        tip = noctalia.tr("nvtop.process.gpu_mem.tip"),
        flexGrow = 2.3,
        textAlign = "end",
        process_value = function(value) return value ~= nil and format_memory_size(value) or "n/a" end,
        sort_value = function(value) return tonumber(value) end,
    },
    {
        data_key = "cmdline",
        context_key = {"cmd"},
        label = noctalia.tr("nvtop.process.cmdline.label"),
        tip = noctalia.tr("nvtop.process.cmdline.tip"),
        flexGrow = 9,
        textAlign = "start",
        process_value = function(value) return value end,
        sort_value = function(value) return tostring(value) end,
    },
}

local processes_data_transfer = {}
for _, column in ipairs(processes_data) do
    processes_data_transfer[column.data_key] = column.sort_value
end

local processes_data_transfer_shared_encode_decode = {}
for _, column in ipairs(processes_data_shared_encode_decode) do
    processes_data_transfer_shared_encode_decode[column.data_key] = column.sort_value
end

local function is_shared_encode_decode(gpu_idx)
    for key, _ in nvtop_data[gpu_idx] do
        if key == "encode_decode" then
            return true
        end
    end
    return false
end

local function get_processes_data(gpu_idx)
    if is_shared_encode_decode(gpu_idx) then
        return processes_data_shared_encode_decode
    else
        return processes_data
    end
end

local function get_processes_data_transfer(gpu_idx)
    if is_shared_encode_decode(gpu_idx) then
        return processes_data_transfer_shared_encode_decode
    else
        return processes_data_transfer
    end
end

local function get_order_by(context, gpu_idx)
    local clear_context = context
    if context:sub(1, 1) == "-" then
        clear_context = context:sub(2)
    end
    for _, column in ipairs(get_processes_data(gpu_idx)) do
        if table.find(column.context_key, clear_context) then
            local ret = column.data_key
            if context:sub(1, 1) == "-" then
                ret = "-" .. column.data_key
            end
            return ret
        end
    end
    return "gpu_mem_bytes_alloc"
end

local function values_are_equal(a, b)
    if a == nil and b == nil then
        return true
    elseif a == nil or b == nil then
        return false
    end

    if type(a) == "number" and type(b) == "number" then
        return a == b
    else
        return tostring(a) == tostring(b)
    end
end

local function compare_values(a, b, reverse)
    if a == nil and b == nil then
        return false
    elseif a == nil then
        return not reverse
    elseif b == nil then
        return reverse
    end

    if type(a) == "number" and type(b) == "number" then
        if reverse then
            return a > b
        else
            return a < b
        end
    else
        if reverse then
            return tostring(a) > tostring(b)
        else
            return tostring(a) < tostring(b)
        end
    end
end

-- Sort the processes based on the selected column and order (ascending or descending).
local function sort_processes(processes, gpu_idx)
    local order_by = get_order_by(g_order_by_context, gpu_idx)
    local reverse = true
    if order_by:sub(1, 1) == "-" then
        order_by = order_by:sub(2)
        reverse = false
    end

    local data = get_processes_data_transfer(gpu_idx)

    table.sort(processes, function(a, b)
        local a_value = data[order_by](a[order_by])
        local b_value = data[order_by](b[order_by])
        local a_value2 = data["gpu_mem_bytes_alloc"](a["gpu_mem_bytes_alloc"])
        local b_value2 = data["gpu_mem_bytes_alloc"](b["gpu_mem_bytes_alloc"])

        if a_value == nil and b_value == nil then
            return false
        elseif a_value == nil then
            return not reverse
        elseif b_value == nil then
            return reverse
        end

        if values_are_equal(a_value, b_value) then
            return compare_values(a_value2, b_value2, reverse)
        end

        return compare_values(a_value, b_value, reverse)
    end)
end

local function sort_all_processes()
    for idx, gpu in ipairs(nvtop_data) do
        if gpu.processes then
            sort_processes(gpu.processes, idx)
        end
    end
end

-- Render the header row for the process list, with sortable columns.
local function render_processes_header(gpu_idx)
    local children = {}
    local order_by = get_order_by(g_order_by_context, gpu_idx)
    for _, column in ipairs(get_processes_data(gpu_idx)) do
        local sort_indicator = ""
        if order_by == column.data_key then
            sort_indicator = "▼ "
        elseif order_by == "-" .. column.data_key then
            sort_indicator = "▲ "
        end
        table.insert(children, ui.button({
            text = sort_indicator .. column.label,
            tooltip = column.tip,
            flexGrow = column.flexGrow,
            variant = "ghost",
            controlSize = "sm",
            fontSize = 10,
            selected = order_by == column.data_key or order_by == "-" .. column.data_key,
            onClick = function()
                if table.find(column.context_key, g_order_by_context) then
                    g_order_by_context = "-" .. column.context_key[1]
                else
                    g_order_by_context = column.context_key[1]
                end
                sort_all_processes()
                render()
            end
        }))
    end
    return ui.row({
        gap = 8,
        fill = "surface_variant",
        radius = 8,
    }, children)
end

local hover_row_key = nil
local expanded_pid = nil

-- Render the list of processes for the selected GPU, with sortable columns.
local function render_processes(gpu_idx)
    local children = {}
    local order_by = get_order_by(g_order_by_context, gpu_idx)
    local default_hover_fill = noctalia.getConfig("process_hover_background") or "surface_variant"
    local default_hover_color = noctalia.getConfig("process_hover_color") or "on_surface_variant"
    for _, process in ipairs(nvtop_data[gpu_idx].processes) do
        local process_children = {}
        local is_hovered = hover_row_key == "proc-row-" .. process.pid
        for _, column in ipairs(get_processes_data(gpu_idx)) do
            local fill = "surface/0.0"
            local color = (is_hovered or (expanded_pid ~= nil and expanded_pid == process.pid)) and default_hover_color or "on_surface"
            local fontWeight = "medium"
            if order_by == column.data_key or order_by == "-" .. column.data_key then
                if not is_hovered then
                    fill = noctalia.getConfig("sort_column_background") or "surface_variant"
                    color = noctalia.getConfig("sort_column_color") or "on_surface_variant"
                end
                fontWeight = "bold"
            end
            table.insert(process_children, ui.column({
                flexGrow = column.flexGrow,
                paddingH = 8,
                paddingV = 1,
                fill = fill,
                radius = 16,
            }, {
                ui.label({
                    text = column.process_value(process[column.data_key]),
                    maxLines = 1,
                    flexGrow = 1,
                    color = color,
                    textAlign = column.textAlign,
                    fontWeight = fontWeight,
                    opacity = process[column.data_key] and 1 or 0.4,
                })
            }))
        end

        if expanded_pid ~= nil and expanded_pid == process.pid then
            table.insert(children, ui.column({
                radius = 2,
                padding = 1,
                fill = default_hover_fill
            }, {
                ui.row({
                    key = "proc-row-" .. process.pid,
                    gap = 8,
                    onClick = function()
                        expanded_pid = nil
                        render()
                    end
                }, process_children),
                ui.row({
                    key = "proc-row-expanded-" .. process.pid,
                    gap = 8,
                    padding = 4,
                    radius = 2,
                    fill = default_hover_fill,
                }, {
                    ui.button({
                        text = noctalia.tr("nvtop.process_buttons.kill.label"),
                        tooltip = noctalia.tr("nvtop.process_buttons.kill.tip"),
                        glyph = "square-x",
                        variant = "destructive",
                        controlSize = "sm",
                        onClick = function()
                            noctalia.runAsync({"kill", tostring(process.pid)})
                            expanded_pid = nil
                            render()
                        end
                    }),
                    ui.button({
                        text = noctalia.tr("nvtop.process_buttons.force_kill.label"),
                        tooltip = noctalia.tr("nvtop.process_buttons.force_kill.tip"),
                        glyph = "skull",
                        variant = "destructive",
                        controlSize = "sm",
                        onClick = function()
                            noctalia.runAsync({"kill", "-9", tostring(process.pid)})
                            expanded_pid = nil
                            render()
                        end
                    }),
                    ui.spacer({flexGrow = 1}),
                    ui.button({
                        text = noctalia.tr("nvtop.process_buttons.copy_pid.label"),
                        tooltip = noctalia.tr("nvtop.process_buttons.copy_pid.tip"),
                        glyph = "clipboard",
                        variant = "default",
                        controlSize = "sm",
                        onClick = function()
                            noctalia.copyToClipboard(process.pid, "text/plain")
                            expanded_pid = nil
                            render()
                        end
                    }),
                    ui.button({
                        text = noctalia.tr("nvtop.process_buttons.copy_cmdline.label"),
                        tooltip = noctalia.tr("nvtop.process_buttons.copy_cmdline.tip"),
                        glyph = "clipboard",
                        variant = "default",
                        controlSize = "sm",
                        onClick = function()
                            noctalia.copyToClipboard(process.cmdline, "text/plain")
                            expanded_pid = nil
                            render()
                        end
                    }),
                    ui.button({
                        text = noctalia.tr("nvtop.process_buttons.cancel.label"),
                        tooltip = noctalia.tr("nvtop.process_buttons.cancel.tip"),
                        glyph = "cancel",
                        variant = "primary",
                        controlSize = "sm",
                        onClick = function()
                            expanded_pid = nil
                            render()
                        end
                    })
                })
            }))
        else
            table.insert(children, ui.row({
                key = "proc-row-" .. process.pid,
                gap = 8,
                padding = 1,
                radius = 16,
                fill = (is_hovered or (expanded_pid ~= nil and expanded_pid == process.pid)) and default_hover_fill or "surface",
                onHover = function(state, key)
                    local old_state = hover_row_key
                    if state == "true" then
                        hover_row_key = "proc-row-" .. process.pid
                    else
                        hover_row_key = nil
                    end
                    if old_state ~= hover_row_key then
                        render()
                    end
                end,
                onClick = function()
                    if expanded_pid == nil or expanded_pid ~= process.pid then
                        expanded_pid = process.pid
                        render()
                    end
                end
            }, process_children))
        end
    end

    return ui.column({
        fill = "surface_variant",
        border = "outline",
        borderWidth = 1,
        flexGrow = 1,
        radius = 12,
        padding = 4
    }, {
        render_processes_header(gpu_idx),
        ui.scroll({
            flexGrow = 1,
            border = "outline",
            borderWidth = 1,
            fill = "surface",
            radius = 10,
            gap = 2,
        }, children)
    })
end

-- Render the entire panel, including the GPU list, GPU info, and process list.
render = function()
    if render_no_data_message() then
        return
    end

    local children = {}

    -- Fix the selected index if it is out of bounds, and render the GPU list.
    local selected_idx = selected_gpu
    if selected_idx > #nvtop_data or selected_idx < 1 then
        selected_idx = 1
    end

    -- Add the GPU list to the children
    table.insert(children, render_gpu_list(selected_idx))
    -- Add the GPU info for the selected GPU to the children
    table.insert(children, render_gpu_info(selected_idx))
    -- Add the process rows for the selected GPU to the children
    table.insert(children, render_processes(selected_idx))

    panel.render(ui.column({
        flexGrow = 1,
        gap = 6,
    }, children))
end


local function run_nvtop()
    local plugin_dir = noctalia.pluginDir()
    local theme
    if noctalia.isDarkMode() then
        theme = "dark"
    else
        theme = "light"
    end
    local nvtop_cmd = "python3 " .. plugin_dir .. "/scripts/run_nvtop.py " .. tostring(noctalia.getConfig("delay")) .. " " .. theme
    g_error_message = nil
    noctalia.runStream(nvtop_cmd, function(line)
        if line:find("tordex/nvtop:pid:") then
            nvtop_pid = tonumber(line:match("tordex/nvtop:pid:(%d+)"))
        elseif starts_with(line, "tordex/nvtop:ready:") then
            local in_data = line:match("tordex/nvtop:ready:(.+)")
            local decoded_in_data = noctalia.json.decode(in_data) or nil
            local filename = decoded_in_data and decoded_in_data.data or nil
            g_gpu_graph_path = decoded_in_data and decoded_in_data.gpu_graph or g_gpu_graph_path
            g_mem_graph_path = decoded_in_data and decoded_in_data.mem_graph or g_mem_graph_path
            if filename then
                noctalia.readFileAsync(filename, function(content, err)
                    if content then
                        local decoded = noctalia.json.decode(content) or nil
                        if decoded then
                            nvtop_data = decoded
                            g_data_load_ms = tostring(noctalia.nowMs())
                            sort_all_processes()
                            render()
                        end
                    end
                end)
            end
        elseif starts_with(line, "tordex/nvtop:done:") then
            local message = line:match("tordex/nvtop:done:(.+)")
            -- You can handle the done message here if needed
            local decoded = noctalia.json.decode(message) or nil
            if decoded then
                if decoded.status == "error" then
                    g_error_message = decoded.message or "Unknown error"
                    nvtop_data = {}
                    render()
                end
            end
        end
    end)
end

-- Stop the nvtop process if it is running, and reset the PID to -1.
local function stop_nvtop()
    if nvtop_pid ~= -1 then
        noctalia.runAsync("pkill -P " .. tostring(nvtop_pid))
        nvtop_pid = -1
    end
end

-- Handle the panel opening event, and check for a context key to sort the process list by.
function onOpen(context)
    if context ~= nil and context ~= "" then
        g_order_by_context = context:lower()
        sort_all_processes()
        render()
    end
    write_params()
    stop_nvtop()
    run_nvtop()
end

-- Handle the panel closing event, and stop the nvtop process.
function onClose()
    stop_nvtop()
    local params_file = get_params_file_path()
    if noctalia.fileExists(params_file) then
        noctalia.removeFile(params_file)
    end
end
