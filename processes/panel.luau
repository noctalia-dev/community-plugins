--!nonstrict

-- Data from the nvtop command, which is updated in real-time.
local g_data = nil

-- The PID of the stats.py process, which is used to terminate the process when the panel is closed.
local g_procs_pid = -1

-- Context for ordering processes in the panel.
local g_order_by_context = "mem"

-- Whether to show view options in the panel.
local g_show_view_options = false

-- Whether to show user processes in the panel.
local g_show_user_processes = true

-- Show applications in the processes list
local view_show_apps = noctalia.getConfig("show_apps")

-- Show processes in the processes list
local view_show_processes = noctalia.getConfig("show_processes")

-- Forward declaration of the render function to allow it to be called from other functions.
local render

-- Data load time in milliseconds. Used as part of key for gauge images controls.
local g_data_load_ms = "none"

-- Cache for processes UI tree to improve performance.
local g_processes_cache = nil

-- The PID of the process currently being viewed in the info block.
-- This var set on process row click
local g_process_view_pid = nil

-- The data of the process currently being viewed in the info block.
-- This var set on process row click
local g_process_view_data = nil

-- The text of search query
local g_search_query = ""

-- The part of search input control key. Used to set focus to the input when required.
local g_search_query_ctl_key = 0

-- The key of the info row currently being hovered. Used to change the row's appearance on hover.
local g_info_row_hover_key = ""

-- The key of the value currently being hovered in the process view. Used to change the appearance of the value on hover.
local g_process_view_hover_key = nil


-- Reset the processes cache. This is useful when the underlying data changes and the UI needs to be refreshed.
local function reset_processes_cache()
    g_processes_cache = nil
end

-- Helper function to check if a string starts with a given prefix.
local function starts_with(str: string, prefix: string): boolean
    return string.sub(str, 1, #prefix) == prefix
end

-- Format memory size in bytes to a human-readable string in M or G.
local function format_memory_size(size_in_bytes, show_B)
    show_B = show_B or false
    if size_in_bytes == nil then
        return "0" .. (show_B and " B" or "")
    end

    local size_in_units = size_in_bytes
    if size_in_units < 1024 then
        return tostring(size_in_bytes) .. (show_B and " B" or "")
    end

    size_in_units = size_in_units / 1024
    if size_in_units < 1024 then
        return string.format("%.1f K", size_in_units)
    end

    size_in_units = size_in_units / 1024
    if size_in_units < 1024 then
        return string.format("%.1f M", size_in_units)
    end

    size_in_units = size_in_units / 1024
    return string.format("%.1f G", size_in_units)
end

-- Render a message when there is no data available.
local function render_no_data_message()
    if g_data == nil then
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
                name = "info-triangle"
            }),
            ui.label({
                key = "no-data-label",
                text = noctalia.tr("procs.nodata"),
            })
        }))
        return true
    end
    return false
end

-- Render a single row of system information with a glyph and text.
local function render_system_info_row(glyph, text)
    local row_key = "info-row-" .. glyph

    local fill = "on_surface_variant/0.0"
    local color = "on_surface_variant"
    if row_key == g_info_row_hover_key then
        color = "on_hover"
        fill = "hover"
    end

    return ui.row({
        key = row_key,
        gap = 8,
        radius = 16,
        paddingH = 8,
        paddingV = 2,
        fill = fill,
        onClick = function()
            if noctalia.copyToClipboard(text, "text/plain") then
                noctalia.notify(noctalia.tr("procs.copied_to_clipboard"), text)
            else
                noctalia.notify(noctalia.tr("procs.copy_failed"), text)
            end
        end,
        onHover = function(state, key)
            local old_state = g_info_row_hover_key
            if state == "true" then
                g_info_row_hover_key = key
            else
                g_info_row_hover_key = ""
            end
            if old_state ~= g_info_row_hover_key then
                render()
            end
        end,
    },{
        ui.glyph({
            key = row_key .. "-glyph",
            name = glyph,
            color = color,
            size = 12,
        }),
        ui.label({
            key = row_key .. "-label",
            text = text,
            color = color,
            maxLines = 1,
            fontSize = 12,
        }),
    })
end

-- Render the system information section.
local function render_system_info()
    local children = {}

    if g_data.distro_info.pretty_name ~= nil then
        table.insert(children, render_system_info_row("device-desktop", g_data.distro_info.pretty_name))
    else
        table.insert(children, render_system_info_row("device-desktop", noctalia.tr("procs.system_info.unknown")))
    end

    if g_data.system_stats.kernel_version ~= nil then
        table.insert(children, render_system_info_row("copy", g_data.system_stats.kernel_version))
    end

    if g_data.system_stats.cpu_name ~= nil then
        table.insert(children, render_system_info_row("cpu", g_data.system_stats.cpu_name))
    end

    if g_data.system_stats.board ~= nil then
        table.insert(children, render_system_info_row("artboard", g_data.system_stats.board))
    end

    if g_data.system_stats.uptime ~= nil then
        local uptime_seconds = g_data.system_stats.uptime
        local uptime_days = math.floor(uptime_seconds / (24 * 3600))
        local uptime_hours = math.floor((uptime_seconds % (24 * 3600)) / 3600)
        local uptime_minutes = math.floor((uptime_seconds % 3600) / 60)
        local uptime_str = string.format("%d %s %d %s %d %s",
                uptime_days, noctalia.trp("days", uptime_days),
                uptime_hours, noctalia.trp("hours", uptime_hours),
                uptime_minutes, noctalia.trp("minutes", uptime_minutes))

        table.insert(children, render_system_info_row("clock", uptime_str))
    end

    return ui.column({
        key = "system-info-column",
        flexGrow = 1,
    }, children)
end

-- Render the view options section.
local function render_view_options()

    return ui.row({ flexGrow = 1 }, {
        ui.column({
            key = "view-options-column",
            gap = 8,
        },{
            ui.row({
                gap = 8,
                radius = 16,
                paddingH = 8,
            },{
                ui.label({
                    text = noctalia.tr("settings.show_apps.label"),
                    color = "on_surface_variant",
                    maxLines = 1,
                }),
                ui.spacer({ flexGrow = 1 }),
                ui.toggle({
                    key = "toggle-show-apps",
                    checked = view_show_apps,
                    onChange = function(new_value)
                        view_show_apps = new_value == "true"
                        reset_processes_cache()
                        render()
                    end
                })
            }),
            ui.row({
                gap = 8,
                radius = 16,
                paddingH = 8,
            },{
                ui.label({
                    text = noctalia.tr("settings.show_processes.label"),
                    color = "on_surface_variant",
                    maxLines = 1,
                }),
                ui.spacer({ flexGrow = 1 }),
                ui.toggle({
                    key = "toggle-show-processes",
                    checked = view_show_processes,
                    onChange = function(new_value)
                        view_show_processes = new_value == "true"
                        reset_processes_cache()
                        render()
                    end
                })
            }),
        })
    })
end

-- Render a label for a process view row.
local function render_process_view_label(text)
    return ui.label({
        text = text,
        maxLines = 1,
        fontSize = 12,
        color = "on_surface_variant",
    })
end

-- Render a value for a process view row, with optional hover and click behavior.
local function render_process_view_value(text, align, hover_key)
    local ret = ui.label({
        text = text,
        maxLines = 1,
        fontSize = 12,
        flexGrow = 1,
        textAlign = align,
        color = "on_surface"
    })

    if hover_key then
        local new_ret = ui.column({
            flexGrow = 1,
        }, {ret})
        new_ret.props.key = hover_key
        new_ret.props.onHover = function(state, key)
            local old_state = g_process_view_hover_key
            if state == "true" then
                g_process_view_hover_key = hover_key
            else
                g_process_view_hover_key = nil
            end
            if old_state ~= g_process_view_hover_key then
                render()
            end
        end
        new_ret.props.onClick = function()
            noctalia.copyToClipboard(text, "text/plain")
            noctalia.notify(noctalia.tr("procs.copied_to_clipboard"), text)
        end
        if g_process_view_hover_key == hover_key then
            ret.props.color = "on_hover"
            new_ret.props.fill = "hover"
        else
            ret.props.color = "on_surface"
            new_ret.props.fill = "on_hover/0.0"
        end
        ret = new_ret
    end
    return ret
end

-- Implementation for rendering the detailed view of a single process.
local function render_process_view()
    if g_process_view_data == nil then
        return
    end

    local children = {}
    table.insert(children,
        ui.column({
            paddingV = 1,
            gap = 2,
        }, {
            ui.button({
                key = "kill-process",
                tooltip = noctalia.tr("procs.process_buttons.kill"),
                glyph = "square-x",
                controlSize = "sm",
                variant = "destructive",
                enabled = g_process_view_data.uid == g_data.system_stats.uid,
                onClick = function()
                    noctalia.runAsync({"kill", tostring(g_process_view_pid)})
                    g_process_view_data = nil
                    g_process_view_pid = nil
                    render()
                end
            }),
            ui.button({
                key = "force-kill-process",
                tooltip = noctalia.tr("procs.process_buttons.force_kill"),
                glyph = "skull",
                controlSize = "sm",
                variant = "destructive",
                enabled = g_process_view_data.uid == g_data.system_stats.uid,
                onClick = function()
                    noctalia.runAsync({"kill", "-9", tostring(g_process_view_pid)})
                    g_process_view_data = nil
                    g_process_view_pid = nil
                    render()
                end
            }),
            ui.spacer({ flexGrow = 1 }),
            ui.button({
                key = "close-process-view",
                tooltip = noctalia.tr("procs.process_buttons.cancel"),
                glyph = "cancel",
                controlSize = "sm",
                variant = "primary",
                onClick = function()
                    g_process_view_data = nil
                    g_process_view_pid = nil
                    render()
                end
            }),
        })
    )

    table.insert(children, ui.separator({ orientation = "auto", color = "on_surface_variant" }))

    table.insert(children, ui.column({},
    {
        render_process_view_label("comm:"),
        render_process_view_label("PID:"),
        render_process_view_label("PPID:"),
        render_process_view_label("exe:"),
        render_process_view_label("cmdline:"),
        render_process_view_label("cpu:"),
    }))

    table.insert(children, ui.column({
        flexGrow = 4,
    }, {
        render_process_view_value(g_process_view_data.comm, "start", "process_view_comm"),
        render_process_view_value(tostring(g_process_view_data.pid), "start", "process_view_pid"),
        render_process_view_value(tostring(g_process_view_data.ppid), "start", "process_view_ppid"),
        render_process_view_value(g_process_view_data.exe, "start", "process_view_exe"),
        render_process_view_value(table.concat(g_process_view_data.cmdline, " "), "start", "process_view_cmdline"),
        render_process_view_value(tostring(g_process_view_data.cpu) .. "%", "start"),
    }))

    table.insert(children, ui.separator({ orientation = "auto", color = "on_surface_variant" }))

    table.insert(children, ui.column({},
    {
        render_process_view_label("private:"),
        render_process_view_label("shared:"),
        render_process_view_label("mem:"),
        render_process_view_label("swap:"),
        render_process_view_label("io read:"),
        render_process_view_label("io write:"),
    }))

    table.insert(children, ui.column({
        flexGrow = 1,
    }, {
        render_process_view_value(format_memory_size(g_process_view_data.private), "end"),
        render_process_view_value(format_memory_size(g_process_view_data.shared), "end"),
        render_process_view_value(format_memory_size(g_process_view_data.mem), "end"),
        render_process_view_value(format_memory_size(g_process_view_data.swap), "end"),
        render_process_view_value(format_memory_size(g_process_view_data.io_read, true) .. "/s", "end"),
        render_process_view_value(format_memory_size(g_process_view_data.io_write, true) .. "/s", "end"),
    }))

    table.insert(children, ui.separator({ orientation = "auto", color = "on_surface_variant" }))

    return children
end

-- Render the system information.
local function render_info()
    local children = {}

    if g_process_view_data ~= nil then
        children = render_process_view()
    else
        if g_data.distro_info.icon_path ~= nil then
            table.insert(children, ui.image({
                key = "img-distro",
                path = g_data.distro_info.icon_path,
                width = 110,
                height = 110,
            }))
        end

        if g_show_view_options then
            table.insert(children, render_view_options())
        else
            table.insert(children, render_system_info())
        end
    end

    if g_data ~= nil and g_data["system_stats"] ~= nil then
        local system_stats = g_data["system_stats"]
        if system_stats["cpu_graph_path"] ~= nil and noctalia.fileExists(system_stats["cpu_graph_path"]) then
            table.insert(children, ui.image({
                key = "img-cpu-" .. g_data_load_ms,
                path = system_stats["cpu_graph_path"],
                width = 110,
                height = 110,
            }))
        end
        if system_stats["mem_graph_path"] ~= nil and noctalia.fileExists(system_stats["mem_graph_path"]) then
            table.insert(children, ui.image({
                key = "img-mem-" .. g_data_load_ms,
                path = system_stats["mem_graph_path"],
                width = 110,
                height = 110,
            }))
        end
    end

    return ui.row({
        key = "info-row",
        gap = 8,
        padding = 8,
        radius = 12,
        border = "outline",
        fill = "surface_variant",
        borderWidth = 1,
    }, children)
end

-- Define the process data columns to display in the panel.
local g_processes_data = {
    {
        data_key = "name",
        label = noctalia.tr("procs.process.name.label"),
        tip = noctalia.tr("procs.process.name.tip"),
        flexGrow = 4,
        textAlign = "start",
        process_value = function(value) return value end,
        sort_value = function(value) return value end
    },
    {
        data_key = "cpu",
        label = noctalia.tr("procs.process.cpu.label"),
        tip = noctalia.tr("procs.process.cpu.tip"),
        flexGrow = 1.5,
        textAlign = "end",
        process_value = function(value) return tostring(value) .. "%" end,
        sort_value = function(value) return value end
    },
    {
        data_key = "mem",
        label = noctalia.tr("procs.process.mem.label"),
        tip = noctalia.tr("procs.process.mem.tip"),
        flexGrow = 2.0,
        textAlign = "end",
        process_value = function(value) return format_memory_size(value) end,
        sort_value = function(value) return value end
    },
    {
        data_key = "swap",
        label = noctalia.tr("procs.process.swap.label"),
        tip = noctalia.tr("procs.process.swap.tip"),
        flexGrow = 2.0,
        textAlign = "end",
        process_value = function(value) return format_memory_size(value) end,
        sort_value = function(value) return value end
    },
    {
        data_key = "io",
        label = noctalia.tr("procs.process.disk.label"),
        tip = noctalia.tr("procs.process.disk.tip"),
        flexGrow = 2.0,
        textAlign = "end",
        process_value = function(value) return format_memory_size(value, true) .. "/s" end,
        sort_value = function(value) return value end
    },
    {
        data_key = "pid",
        label = noctalia.tr("procs.process.pid.label"),
        tip = noctalia.tr("procs.process.pid.tip"),
        flexGrow = 2,
        textAlign = "end",
        process_value = function(value) return tostring(value or "") end,
        sort_value = function(value) return value end
    },
    {
        data_key = "username",
        label = noctalia.tr("procs.process.username.label"),
        tip = noctalia.tr("procs.process.username.tip"),
        flexGrow = 2.0,
        textAlign = "start",
        process_value = function(value) return value end,
        sort_value = function(value) return value end
    },
}

local g_processes_data_transfer = {}

for _, column in ipairs(g_processes_data) do
    g_processes_data_transfer[column.data_key] = column.sort_value
end

-- Converts context value to a valid order_by key, handling the "-" prefix for descending order.
local function get_order_by(context)
    local clear_context = context
    if context:sub(1, 1) == "-" then
        clear_context = context:sub(2)
    end
    for col_idx = 1, #g_processes_data do
        local column = g_processes_data[col_idx]
        if column.data_key == clear_context then
            local ret = column.data_key
            if context:sub(1, 1) == "-" then
                ret = "-" .. column.data_key
            end
            return ret
        end
    end
    return "mem"
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
local function sort_processes(processes)
    local order_by = get_order_by(g_order_by_context)
    local reverse = true
    if order_by:sub(1, 1) == "-" then
        order_by = order_by:sub(2)
        reverse = false
    end

    table.sort(processes, function(a, b)
        local a_value = g_processes_data_transfer[order_by](a[order_by]) or g_processes_data_transfer["name"](a["name"])
        local b_value = g_processes_data_transfer[order_by](b[order_by]) or g_processes_data_transfer["name"](b["name"])
        local a_value2 = g_processes_data_transfer["name"](a["name"])
        local b_value2 = g_processes_data_transfer["name"](b["name"])

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

-- Sort all processes in the data, including applications, user processes, and system processes.
local function sort_all_processes()
    if g_data == nil then
        return
    end
    sort_processes(g_data.processes)
    sort_processes(g_data.applications)
    sort_processes(g_data.user_processes)
    sort_processes(g_data.system_processes)
    for _, app_data in pairs(g_data.applications) do
        sort_processes(app_data.processes)
    end
    for _, process in pairs(g_data.user_processes) do
        if process.processes then
            sort_processes(process.processes)
        end
    end
    for _, process in pairs(g_data.system_processes) do
        if process.processes then
            sort_processes(process.processes)
        end
    end
end

-- Render the header row for the process list, with sortable columns.
local function render_processes_header()
    local children = {}
    local order_by = get_order_by(g_order_by_context)
    for col_idx = 1, #g_processes_data do
        local column = g_processes_data[col_idx]
        local sort_indicator = ""
        if order_by == column.data_key then
            sort_indicator = "▼ "
        elseif order_by == "-" .. column.data_key then
            sort_indicator = "▲ "
        end
        table.insert(children, ui.button({
            key = "processes-header-" .. column.data_key,
            text = sort_indicator .. column.label,
            tooltip = column.tip,
            flexGrow = column.flexGrow,
            variant = "ghost",
            controlSize = "sm",
            fontSize = 10,
            selected = order_by == column.data_key or order_by == "-" .. column.data_key,
            onClick = function()
                if column.data_key == g_order_by_context then
                    g_order_by_context = "-" .. column.data_key
                else
                    g_order_by_context = column.data_key
                end
                sort_all_processes()
                reset_processes_cache()
                render()
            end
        }))
    end
    return ui.row({
        key = "processes-header-row",
        gap = 8,
        fill = "surface_variant",
        radius = 8,
    }, children)
end

-- Track the hover state for process rows.
local g_hover_row_key = nil

-- Track the expand/collapse state for process groups.
local g_group_expand_state = {}

-- Track the expand/collapse state for the applications section.
local g_apps_expanded = true

-- Track the expand/collapse state for the all processes section.
local g_all_processes_expanded = true

local function toggle_group_expand_state(group_key)
    if g_group_expand_state[group_key] == nil then
        g_group_expand_state[group_key] = true
    else
        g_group_expand_state[group_key] = not g_group_expand_state[group_key]
    end
end

local function is_group_expanded(group_key)
    return g_group_expand_state[group_key] == true
end

-- Render the header row for a specific type of processes (applications or all processes).
local function render_processes_type_header(is_app)
    local children = {}
    local expanded
    if is_app then
        expanded = g_apps_expanded
    else
        expanded = g_all_processes_expanded
    end

    local header_text = ""
    local row_key = "header"
    if is_app then
        header_text = noctalia.tr("procs.applications_header")
        row_key = row_key .. "-app"
    else
        header_text = noctalia.tr("procs.processes_header")
        row_key = row_key .. "-all"
    end

    if expanded then
        table.insert(children, ui.glyph({
            name = "chevron-down",
            color = "on_surface_variant",
        }))
    else
        table.insert(children, ui.glyph({
            name = "chevron-right",
            color = "on_surface_variant",
        }))
    end

    table.insert(children, ui.label({
        text = header_text,
        fontWeight = "bold",
        maxLines = 1,
        flexGrow = 1,
        color = "secondary",
    }))

    return ui.row({
            key = row_key,
            gap = 8,
            padding = 1,
            radius = 2,
            onClick = function()
                if is_app then
                    g_apps_expanded = not g_apps_expanded
                else
                    g_all_processes_expanded = not g_all_processes_expanded
                end
                reset_processes_cache()
                render()
            end
        }, children)
end

-- Update the processes list in cache based on hover state.
local function update_processes_hover_cache(default_hover_fill, default_hover_color)
    if g_processes_cache == nil then
        return
    end
    for idx = 1, #g_processes_cache do
        local rows = g_processes_cache[idx].children
        for rows_idx = 1, #rows do
            local process_row = rows[rows_idx]
            if process_row.type == "row" then
                if g_hover_row_key == process_row.props.key then
                    process_row.props.fill = default_hover_fill
                    process_row.props.borderWidth = 1
                else
                    process_row.props.fill = "surface/0.0"
                    process_row.props.borderWidth = 0
                end
                for child_idx = 1, #process_row.children do
                    local label = process_row.children[child_idx].label
                    if label ~= nil then
                        if g_hover_row_key == process_row.props.key then
                            label.props.color = default_hover_color
                        else
                            label.props.color = "on_surface"
                        end
                    end
                end
            end
        end
    end
end

-- Filter process. Returns true to show process and false to hide process
local function filter_process(process)
    if g_search_query == "" then
        return true
    end

    if process.pid == nil then
        return false
    end

    if g_show_user_processes and process.uid ~= g_data.system_stats.uid then
        return false
    end

    if not g_show_user_processes and process.uid == g_data.system_stats.uid then
        return false
    end

    local num_text = tonumber(g_search_query)
    if num_text ~= nil then
        -- Search numbers in pid and ppid
        if num_text == process.pid or num_text == process.ppid then
            return true
        end
        return false
    end

    local search_fields = { "name", "cmdline", "exe", "comm", "username" }

    for _, field in pairs(search_fields) do
        if typeof(field) == "string" then
            if process[field] and string.find(tostring(process[field]), g_search_query, 1, true) then
                return true
            end
        elseif typeof(field) == "table" then
            if process[field] and string.find(table.concat(process[field], " "), g_search_query, 1, true) then
                return true
            end
        end
    end

    return false
end

-- Render the list of processes for the selected GPU, with sortable columns.
local function render_processes(processes, level, holder)
    holder = holder or false
    level = level or 0
    local key_prefix = "proc-"
    local children = {}
    local rows_holders = {}
    local children_N = 0
    local order_by = get_order_by(g_order_by_context)
    local default_hover_fill = noctalia.getConfig("process_hover_background") or "surface_variant"
    local default_hover_color = noctalia.getConfig("process_hover_color") or "on_surface_variant"
    for row_idx = 1, #processes do
        local process = processes[row_idx]

        if not filter_process(process) then
            continue
        end

        children_N = children_N + 1
        local process_key = key_prefix .. "row-" .. process.key
        local is_hovered = g_hover_row_key == process_key

        if g_process_view_pid and g_process_view_pid == process.pid then
            g_process_view_data = process
        end

        local columns_num = #g_processes_data
        local process_children = table.create(columns_num)

        for col_idx = 1, columns_num do
            local column = g_processes_data[col_idx]
            local fill = "surface/0.0"
            local color = is_hovered and default_hover_color or "on_surface"
            local fontWeight = "medium"
            if order_by == column.data_key or order_by == "-" .. column.data_key then
                fill = noctalia.getConfig("sort_column_background") or "surface_variant"
                color = noctalia.getConfig("sort_column_color") or "on_surface_variant"
                fontWeight = "bold"
            end

            local value_label = ui.label({
                            key = process_key .. "-col-" .. tostring(col_idx) .. "-" .. tostring(level) .. "-label",
                            text = if process[column.data_key] ~= 0 then column.process_value(process[column.data_key]) else "—",
                            maxLines = 1,
                            flexGrow = 1,
                            color = color,
                            textAlign = column.textAlign,
                            fontWeight = fontWeight,
                        })


            if col_idx == 1 then
                local marker_glyph = nil
                if process.processes ~= nil then
                    if is_group_expanded(process.key) then
                        marker_glyph = "chevron-down"
                    else
                        marker_glyph = "chevron-right"
                    end
                end
                process_children[col_idx] = ui.column({
                    flexGrow = column.flexGrow,
                    paddingH = 2,
                    paddingV = 1,
                    fill = fill,
                    radius = 16,
                }, {
                    ui.row({
                        key = process_key .. "-col-" .. tostring(col_idx) .. "-" .. tostring(level) .. "-row",
                        flexGrow = 1,
                        gap = 4,
                    }, {
                        ui.spacer({
                            key = process_key .. "-col-" .. tostring(col_idx) .. "-" .. tostring(level) .. "-spacer",
                            width = 8 * level * (col_idx == 1 and 1 or 0),
                            flexGrow = 0,
                        }),
                        ui.glyph({
                            key = process_key .. "-col-" .. tostring(col_idx) .. "-" .. tostring(level) .. "-glyph",
                            size = 12,
                            name = marker_glyph,
                        }),
                        ui.image({
                            key = process_key .. "-col-" .. tostring(col_idx) .. "-" .. tostring(level) .. "-icon",
                            path = process.icon,
                            width = 16,
                            height = 16,
                        }),
                        value_label
                    })
                })
            else
                process_children[col_idx] = ui.column({
                    key = process_key .. "-col-" .. tostring(col_idx) .. "-" .. tostring(level) .. "-column",
                    flexGrow = column.flexGrow,
                    paddingH = 8,
                    paddingV = 1,
                    fill = fill,
                    radius = 16,
                }, { value_label })
            end
            -- We don't change color for "order by" column, so don't save the reference for it
            if not (order_by == column.data_key or order_by == "-" .. column.data_key) then
                -- Save refference to the value label for update_processes_hover_cache
                process_children[col_idx].label = value_label
            end
        end

        children[children_N] = ui.row({
            key = process_key,
            gap = 8,
            paddingV = 1,
            radius = 16,
            fill = is_hovered and default_hover_fill or "surface/0.0",
            onHover = function(state, key)
                local old_state = g_hover_row_key
                if state == "true" then
                    g_hover_row_key = process_key
                else
                    g_hover_row_key = nil
                end
                if old_state ~= g_hover_row_key then
                    update_processes_hover_cache(default_hover_fill, default_hover_color)
                    render()
                end
            end,
            onClick = function()
                if process.processes ~= nil then
                    toggle_group_expand_state(process.key)
                    reset_processes_cache()
                    render()
                elseif g_process_view_pid == nil or g_process_view_pid ~= process.pid then
                    g_process_view_pid = process.pid
                    g_process_view_data = process
                    render()
                else
                    g_process_view_pid = nil
                    g_process_view_data = nil
                    render()
                end
            end
        }, process_children)
        if process.processes ~= nil and is_group_expanded(process.key) then
            local group_processes_children = render_processes(process.processes, level + 1, false)
            table.move(group_processes_children, 1, #group_processes_children, children_N + 1, children)
            children_N = children_N + #group_processes_children
        else
            if children_N > 100 and holder then
                rows_holders[#rows_holders + 1] = ui.column({ gap = 4 }, children)
                children = {}
                children_N = 0
            end
        end

    end

    if children_N > 0 and holder then
        rows_holders[#rows_holders + 1] = ui.column({ gap = 4 }, children)
    end

    -- For processes within applications we return the children directly instead of the rows_holders.
    if  not holder then
        return children
    end

    return rows_holders
end

-- Render the header block for the processes panel.
local function render_header_block()
    return {
        ui.row({ key = "header", gap = 4, align = "center" }, {
            ui.glyph({ name = "device-desktop-analytics", size = 16 }),
            ui.label({
                key = "title",
                text = noctalia.tr("title"),
                fontSize = 16,
                fontWeight = "bold",
                color = "on_surface",
            }),
            ui.spacer({ key = "title-gap-2", flexGrow = 0, width = 8 }),
            ui.button({
                key = "show_user_processes",
                glyph = "user",
                text = noctalia.tr("user_processes_label"),
                variant = "default",
                controlSize = "sm",
                tooltip = noctalia.tr("user_processes_tip"),
                selected = g_show_user_processes,
                onClick = function()
                    g_show_user_processes = true
                    reset_processes_cache()
                    render()
                end,
            }),
            ui.button({
                key = "show_system_processes",
                glyph = "cpu",
                text = noctalia.tr("system_processes_label"),
                variant = "default",
                controlSize = "sm",
                tooltip = noctalia.tr("system_processes_tip"),
                selected = not g_show_user_processes,
                onClick = function()
                    g_show_user_processes = false
                    reset_processes_cache()
                    render()
                end,
            }),
            ui.spacer({ key = "title-gap-2", flexGrow = 1 }),
            ui.glyph({ name = "search", size = 16 }),
            ui.input({
                key = "search-" .. tostring(g_search_query_ctl_key),
                placeholder = noctalia.tr("search_placeholder"),
                flexGrow = 6,
                controlSize = "sm",
                value = g_search_query,
                focus = true,
                onChange = function(value)
                    g_search_query = value
                    reset_processes_cache()
                    render()
                end
            }),
            ui.button({
                key = "clear_search",
                glyph = "x",
                variant = "default",
                enabled = g_search_query ~= "",
                tooltip = noctalia.tr("tip_clear_search"),
                onClick = function()
                    g_search_query = ""
                    g_search_query_ctl_key = g_search_query_ctl_key + 1
                    reset_processes_cache()
                    render()
                end,
            }),
            ui.spacer({ key = "title-gap-2", flexGrow = 1 }),
            ui.button({
                key = "options",
                glyph = "adjustments-horizontal",
                variant = "ghost",
                tooltip = noctalia.tr("tip_options"),
                selected = g_show_view_options,
                onClick = function()
                    g_show_view_options = not g_show_view_options
                    render()
                end,
            }),
            ui.button({
                key = "settings",
                glyph = "settings",
                variant = "ghost",
                tooltip = noctalia.tr("tip_settings"),
                onClick = function()
                    noctalia.openSettings()
                end,
            }),
            ui.button({
                key = "close",
                glyph = "close",
                variant = "ghost",
                tooltip = noctalia.tr("tip_close"),
                onClick = function()
                    panel.close()
                end,
            }),
        }),
    }
end

-- Render the processes block with caching
local function render_processes_block()
    if g_processes_cache ~= nil then
        return g_processes_cache
    end

    local rows
    local children = {}

    if g_search_query == "" then
        if not g_show_user_processes then
            rows = render_processes(g_data.system_processes, 0, true)
            table.move(rows, 1, #rows, #children + 1, children)
        else
            local have_apps = view_show_apps
            if #g_data.applications == 0 then
                have_apps = false
            end

            if have_apps then
                local level = 0
                if view_show_processes then
                    table.insert(children, render_processes_type_header(true))
                    level = 1
                end
                if g_apps_expanded or not view_show_processes then
                    rows = render_processes(g_data.applications, level, true)
                    table.move(rows, 1, #rows, #children + 1, children)
                end
            end

            if view_show_processes then
                local level = 0
                if have_apps then
                    level = 1
                    table.insert(children, render_processes_type_header(false))
                end
                if g_all_processes_expanded or not have_apps then
                    rows = render_processes(g_data.user_processes, level, true)
                    table.move(rows, 1, #rows, #children + 1, children)
                end
            end
        end
    else
        rows = render_processes(g_data.processes, 0, true)
        table.move(rows, 1, #rows, #children + 1, children)
    end

    g_processes_cache = children
    return children
end

-- Render the entire panel
render = function()
    if render_no_data_message() then
        return
    end

    local children = render_header_block()

    local processes_block = render_processes_block()

    table.insert(children, render_info())
    table.insert(children,
        ui.column({
                key = "processes-column",
                fill = "surface_variant",
                border = "outline",
                borderWidth = 1,
                flexGrow = 1,
                radius = 12,
                padding = 4
            }, {
                render_processes_header(),
                ui.scroll({
                    key = "processes-scroll",
                    flexGrow = 1,
                    border = "outline",
                    borderWidth = 1,
                    fill = "surface",
                    radius = 10,
                    gap = 4,
                }, processes_block)
            })
    )

    panel.render(ui.column({
        key = "main-column",
        flexGrow = 1,
        gap = 6,
    }, children))
end

-- Run scripts/stats.py to get stats updates for processes
local function run_processes_stream()
    local plugin_dir = noctalia.pluginDir()
    local theme
    if noctalia.isDarkMode() then
        theme = "dark"
    else
        theme = "light"
    end
    local cmd = "python3 " .. plugin_dir .. "/scripts/stats.py " .. tostring(noctalia.getConfig("delay")) .. " " .. theme
    noctalia.runStream(cmd,
        function(line)
            if line:find("tordex/procs:pid:") then
                g_procs_pid = tonumber(line:match("tordex/procs:pid:(%d+)"))
            elseif starts_with(line, "tordex/procs:ready:") then
                local filename = line:match("tordex/procs:ready:(.+)")
                noctalia.readFileAsync(filename, function(content, err)
                    if content then
                        local decoded = noctalia.json.decode(content) or nil
                        if decoded then
                            g_data = decoded
                            g_data_load_ms = tostring(noctalia.nowMs())
                            sort_all_processes()
                            reset_processes_cache()
                            render()
                        end
                    end
                end)
            end
        end)
end

-- Stop the procs process if it is running, and reset the PID to -1.
local function stop_processes_stream()
    if g_procs_pid ~= -1 then
        local cmd = "pkill -SIGINT -p " .. tostring(g_procs_pid)
        noctalia.runAsync(cmd)
        g_procs_pid = -1
    end
end

-- Handle the panel opening event, and check for a context key to sort the process list by.
function onOpen(context)
    if context ~= nil and context ~= "" then
        g_order_by_context = context:lower()
        sort_all_processes()
        render()
    end
    stop_processes_stream()
    run_processes_stream()
    render()
end

-- Handle the panel closing event, and stop the nvtop process.
function onClose()
    stop_processes_stream()
end

render()
