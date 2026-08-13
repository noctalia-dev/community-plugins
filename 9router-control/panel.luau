-- 9Router Control — the combo management surface.
--
-- Three views:
--   • List — all combos with search + "new combo" button
--   • Detail — a single combo's model chain with reorder/edit/delete
--   • Create — a form to build a new combo
--
-- Pure subscriber of 9router.* state. User actions are dispatched as IPC
-- events to the service.

local STATE = {
    connection = "9router.connection",
    combos = "9router.combos",
    models = "9router.models",
    selected = "9router.selected_combo",
    last_error = "9router.last_error",
}

local PAD = 12
local WRAP = 480

-- Confirmation / form state
local pending_delete = nil
local rename_id = nil
local rename_value = ""
local creating = false
local create_name = ""
local create_models = ""
local create_kind = "none"
local search_query = ""
local login_password = ""
local adding_model = false
local model_search = ""
local create_error = ""
local rename_error = ""

local KIND_OPTIONS = {
    { value = "none", label_key = "kind.none" },
    { value = "fallback", label_key = "kind.fallback" },
    { value = "round-robin", label_key = "kind.round_robin" },
    { value = "fusion", label_key = "kind.fusion" },
}

-- ── i18n ─────────────────────────────────────────────────────────────────────

local i18n_cache = { lang = nil, table = nil }

local function load_lang_table(lang)
    if i18n_cache.lang == lang and i18n_cache.table then
        return i18n_cache.table
    end
    local merged = {}
    local function merge_file(path)
        local ok, content = pcall(noctalia.readFile, path)
        if not ok or type(content) ~= "string" or content == "" then return end
        local ok2, data = pcall(noctalia.json.decode, content)
        if not ok2 or type(data) ~= "table" then return end
        local function deep(dst, src)
            for k, v in pairs(src) do
                if type(v) == "table" and type(dst[k]) == "table" then
                    deep(dst[k], v)
                else
                    dst[k] = v
                end
            end
        end
        deep(merged, data)
    end
    merge_file("translations/en.json")
    if lang ~= "en" then
        merge_file("translations/" .. lang .. ".json")
    end
    i18n_cache.lang = lang
    i18n_cache.table = merged
    return merged
end

local function tr(key, args)
    local lang = noctalia.getConfig and noctalia.getConfig("language")
    if type(lang) ~= "string" or lang == "" or lang == "auto" then
        return noctalia.tr(key, args)
    end
    local node = load_lang_table(lang)
    for part in string.gmatch(key, "[^%.]+") do
        if type(node) ~= "table" then node = nil break end
        node = node[part]
    end
    if type(node) ~= "string" then
        return noctalia.tr(key, args)
    end
    if type(args) == "table" then
        node = string.gsub(node, "{(%w+)}", function(name)
            local v = args[name]
            if v == nil then return "{" .. name .. "}" end
            return tostring(v)
        end)
    end
    return node
end

local function kind_label(value)
    for _, o in ipairs(KIND_OPTIONS) do
        if o.value == value then return tr(o.label_key) end
    end
    return value or tr("kind.none")
end

-- ── helpers ─────────────────────────────────────────────────────────────────

local function dispatch_ipc(event, payload)
    local cmd = "noctalia msg plugin 'weinguyen/9router-control:service' all " .. event
    if payload ~= nil then
        -- Shell-escape the payload (single-quote wrap + escape embedded quotes).
        payload = tostring(payload):gsub("'", "'\\''")
        cmd = cmd .. " '" .. payload .. "'"
    end
    noctalia.runAsync(cmd)
end

local function find_combo(combos, id)
    if type(combos) ~= "table" then return nil end
    for _, c in ipairs(combos) do
        if type(c) == "table" and c.id == id then return c end
    end
    return nil
end

local function model_chain_text(models)
    if type(models) ~= "table" then return "" end
    local parts = {}
    for _, m in ipairs(models) do
        if type(m) == "string" and m ~= "" then parts[#parts + 1] = m end
    end
    return table.concat(parts, " → ")
end

-- 9Router combo name rule: only a-z, A-Z, 0-9, -, _ and .
local NAME_RE = "^[%w%.%-]+$"
local function valid_name(name)
    return type(name) == "string" and name ~= "" and string.match(name, NAME_RE) ~= nil
end

-- Compact fingerprint of the combo list (names + model chains + kinds) so a
-- reorder/edit that keeps the count the same still triggers a re-render.
local function combos_fingerprint(combos)
    if type(combos) ~= "table" then return "0" end
    local parts = {}
    for _, c in ipairs(combos) do
        if type(c) == "table" then
            parts[#parts + 1] = tostring(c.id or "") .. "|" .. tostring(c.name or "") .. "|" .. tostring(c.kind or "") .. "|" .. model_chain_text(c.models)
        end
    end
    return table.concat(parts, "\1")
end

-- ── list view ───────────────────────────────────────────────────────────────

local function render_list(combos, conn)
    local rows = {}

    -- Header
    rows[#rows + 1] = ui.row({ justify = "space_between", align = "center" }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "route", color = "primary", size = 24 }),
            ui.label({ text = tr("list.title"), fontSize = 18, fontWeight = "bold", color = "on_surface" }),
        }),
        ui.row({ gap = 8 }, {
            ui.button({ glyph = "refresh", onClick = function()
                dispatch_ipc("refresh")
            end, tooltip = tr("list.refresh") }),
        }),
    })

    rows[#rows + 1] = ui.separator({})

    -- Error banner (if any)
    local err = noctalia.state.get(STATE.last_error)
    if type(err) == "table" and err.message then
        rows[#rows + 1] = ui.row({ gap = 8, align = "center", padding = 8, radius = 8, fill = "error/0.15", border = "error", borderWidth = 1 }, {
            ui.glyph({ name = "alert-circle", color = "error", size = 16 }),
            ui.column({ gap = 2, flexGrow = 1 }, {
                ui.label({ text = err.message, color = "error", fontSize = 13, fontWeight = "bold", maxWidth = WRAP - 40 }),
                ui.label({ text = err.detail or "", fontSize = 11, opacity = 0.75, maxWidth = WRAP - 40 }),
            }),
            ui.button({
                glyph = "x",
                variant = "ghost",
                tooltip = tr("error.dismiss"),
                onClick = function()
                    dispatch_ipc("clear_error")
                end,
            }),
        })
    end

    -- New combo button
    rows[#rows + 1] = ui.button({
        text = tr("list.new_combo"),
        glyph = "plus",
        onClick = function()
            creating = true
            create_name = ""
            create_models = ""
            create_kind = "none"
            render()
        end,
    })

    -- Search box
    rows[#rows + 1] = ui.input({
        key = "combo_search",
        value = search_query,
        placeholder = tr("list.search"),
        onChange = function(text)
            search_query = text or ""
            render()
        end,
    })

    -- Filter combos by search query
    local visible = combos
    if type(combos) == "table" and search_query ~= "" then
        local needle = string.lower(search_query)
        visible = {}
        for _, c in ipairs(combos) do
            if type(c) == "table" then
                local hay = string.lower(tostring(c.name or "") .. " " .. model_chain_text(c.models))
                if string.find(hay, needle, 1, true) then
                    visible[#visible + 1] = c
                end
            end
        end
    end

    -- Combo list
    local list_items = {}
    if type(visible) ~= "table" or #visible == 0 then
        list_items[#list_items + 1] = ui.label({
            text = search_query ~= "" and tr("list.no_match") or tr("list.empty"),
            maxWidth = WRAP,
            opacity = 0.7,
        })
    else
        for _, c in ipairs(visible) do
            if type(c) == "table" and c.id then
                local combo_id = c.id
                local name = c.name or c.id
                local chain = model_chain_text(c.models)
                local kind = kind_label(c.kind)

                local function open_this()
                    dispatch_ipc("select_combo", combo_id)
                end

                local actions
                if pending_delete == combo_id then
                    actions = ui.row({ gap = 6 }, {
                        ui.button({
                            glyph = "check",
                            variant = "primary",
                            tooltip = tr("list.delete_confirm"),
                            onClick = function()
                                dispatch_ipc("delete_combo", combo_id)
                                pending_delete = nil
                                render()
                            end,
                        }),
                        ui.button({
                            glyph = "x",
                            variant = "secondary",
                            tooltip = tr("list.delete_cancel"),
                            onClick = function()
                                pending_delete = nil
                                render()
                            end,
                        }),
                    })
                else
                    actions = ui.row({ gap = 6 }, {
                        ui.button({
                            glyph = "trash",
                            variant = "secondary",
                            tooltip = tr("list.delete"),
                            onClick = function()
                                pending_delete = combo_id
                                render()
                            end,
                        }),
                        ui.button({
                            glyph = "arrow-right",
                            variant = "primary",
                            tooltip = tr("list.open"),
                            onClick = open_this,
                        }),
                    })
                end

                list_items[#list_items + 1] = ui.row({
                    key = combo_id,
                    justify = "space_between",
                    align = "center",
                    padding = 10,
                    radius = 10,
                    fill = "surface",
                    border = "surface",
                    borderWidth = 1,
                }, {
                    ui.column({
                        gap = 2, flexGrow = 1,
                        onClick = open_this,
                    }, {
                        ui.label({
                            text = name,
                            maxWidth = WRAP - 140,
                            fontWeight = "bold",
                            color = "on_surface",
                        }),
                        ui.label({
                            text = chain,
                            maxWidth = WRAP - 140,
                            opacity = 0.6,
                            fontSize = 12,
                        }),
                        ui.label({
                            text = tr("list.kind", { kind = kind }),
                            maxWidth = WRAP - 140,
                            opacity = 0.5,
                            fontSize = 11,
                        }),
                    }),
                    actions,
                })
            end
        end
    end

    rows[#rows + 1] = ui.scroll({ flexGrow = 1, gap = 8, align = "stretch", justify = "start" }, list_items)

    panel.render(ui.column({ padding = PAD, gap = 8, flexGrow = 1, align = "stretch", justify = "start" }, rows))
end

-- ── create view ──────────────────────────────────────────────────────────────

local function render_create()
    local rows = {}

    rows[#rows + 1] = ui.row({ justify = "space_between", align = "center" }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.button({
                glyph = "chevron-left",
                variant = "ghost",
                tooltip = tr("create.back"),
                onClick = function()
                    creating = false
                    render()
                end,
            }),
            ui.glyph({ name = "plus", color = "primary", size = 20 }),
            ui.label({ text = tr("create.title"), fontSize = 18, fontWeight = "bold", color = "on_surface" }),
        }),
    })

    rows[#rows + 1] = ui.separator({})

    rows[#rows + 1] = ui.label({ text = tr("create.name_label"), fontWeight = "bold", fontSize = 13 })
    rows[#rows + 1] = ui.input({
        key = "create_name",
        value = create_name,
        placeholder = tr("create.name_placeholder"),
        onChange = function(text)
            create_name = text or ""
            create_error = ""
        end,
    })

    if create_error ~= "" then
        rows[#rows + 1] = ui.label({ text = create_error, color = "error", fontSize = 12, maxWidth = WRAP })
    end

    rows[#rows + 1] = ui.label({ text = tr("create.models_label"), fontWeight = "bold", fontSize = 13 })
    rows[#rows + 1] = ui.label({ text = tr("create.models_hint"), opacity = 0.6, fontSize = 11, maxWidth = WRAP })
    rows[#rows + 1] = ui.input({
        key = "create_models",
        value = create_models,
        placeholder = tr("create.models_placeholder"),
        multiline = true,
        flexGrow = 1,
        onChange = function(text)
            create_models = text or ""
        end,
    })

    rows[#rows + 1] = ui.label({ text = tr("create.kind_label"), fontWeight = "bold", fontSize = 13 })
    local kind_labels = {}
    local kind_values = {}
    local kind_index = nil
    for i, o in ipairs(KIND_OPTIONS) do
        kind_labels[i] = tr(o.label_key)
        kind_values[i] = o.value
        if o.value == create_kind then kind_index = i - 1 end
    end
    local kind_props = {
        key = "create_kind",
        options = kind_labels,
        placeholder = tr("create.kind_label"),
        onChange = function(idx)
            local n = tonumber(idx)
            if n ~= nil then
                create_kind = kind_values[math.floor(n) + 1] or "none"
            end
        end,
    }
    if kind_index ~= nil then kind_props.selectedIndex = kind_index end
    rows[#rows + 1] = ui.select(kind_props)

    rows[#rows + 1] = ui.separator({})

    rows[#rows + 1] = ui.row({ justify = "end", gap = 8 }, {
        ui.button({
            text = tr("create.cancel"),
            variant = "secondary",
            onClick = function()
                creating = false
                render()
            end,
        }),
        ui.button({
            text = tr("create.submit"),
            glyph = "check",
            variant = "primary",
            onClick = function()
                if not valid_name(create_name) then
                    create_error = tr("error.invalid_name")
                    render()
                    return
                end
                local models = {}
                for line in string.gmatch(create_models, "[^\n]+") do
                    local m = line:gsub("^%s+", ""):gsub("%s+$", "")
                    if m ~= "" then models[#models + 1] = m end
                end
                if #models == 0 then
                    create_error = tr("error.need_name_models")
                    render()
                    return
                end
                local payload = noctalia.json.encode({
                    name = create_name,
                    models = models,
                    kind = (create_kind == "none" or create_kind == "") and nil or create_kind,
                })
                dispatch_ipc("create_combo", payload)
                creating = false
                create_error = ""
                render()
            end,
        }),
    })

    panel.render(ui.column({ padding = PAD, gap = 8, flexGrow = 1, align = "stretch", justify = "start" }, rows))
end

-- ── detail view ─────────────────────────────────────────────────────────────

local function render_detail(combo)
    local rows = {}

    -- Header with back button
    rows[#rows + 1] = ui.row({ justify = "space_between", align = "center" }, {
        ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
            ui.button({
                glyph = "chevron-left",
                variant = "ghost",
                tooltip = tr("detail.back"),
                onClick = function()
                    dispatch_ipc("back_to_list")
                end,
            }),
            ui.glyph({ name = "route", color = "primary", size = 20 }),
            ui.column({ gap = 0, flexGrow = 1 }, {
                ui.label({ text = combo.name or combo.id, fontWeight = "bold", maxWidth = WRAP - 200, fontSize = 14 }),
                ui.label({ text = tr("detail.models_count", { count = #(combo.models or {}) }), opacity = 0.6, fontSize = 11 }),
            }),
        }),
        ui.row({ gap = 6 }, {
            ui.button({
                glyph = "refresh",
                tooltip = tr("detail.refresh"),
                onClick = function()
                    dispatch_ipc("refresh")
                end,
            }),
            ui.button({
                glyph = "trash",
                variant = "secondary",
                tooltip = tr("detail.delete"),
                onClick = function()
                    pending_delete = combo.id
                    render()
                end,
            }),
        }),
    })

    rows[#rows + 1] = ui.separator({})

    -- Inline delete confirmation
    if pending_delete == combo.id then
        rows[#rows + 1] = ui.row({ justify = "space_between", align = "center", padding = 8, radius = 8, fill = "error/0.15", border = "error", borderWidth = 1 }, {
            ui.label({ text = tr("detail.delete_confirm"), color = "error", fontWeight = "bold", maxWidth = WRAP - 120 }),
            ui.row({ gap = 6 }, {
                ui.button({
                    glyph = "check",
                    variant = "primary",
                    tooltip = tr("detail.delete_yes"),
                    onClick = function()
                        dispatch_ipc("delete_combo", combo.id)
                        pending_delete = nil
                        render()
                    end,
                }),
                ui.button({
                    glyph = "x",
                    variant = "secondary",
                    tooltip = tr("detail.delete_no"),
                    onClick = function()
                        pending_delete = nil
                        render()
                    end,
                }),
            }),
        })
    end

    -- Kind selector
    local kind_labels = {}
    local kind_values = {}
    local kind_index = nil
    for i, o in ipairs(KIND_OPTIONS) do
        kind_labels[i] = tr(o.label_key)
        kind_values[i] = o.value
        if o.value == (combo.kind or "none") then kind_index = i - 1 end
    end
    local kind_props = {
        key = "detail_kind",
        options = kind_labels,
        placeholder = tr("detail.kind_label"),
        flexGrow = 1,
        onChange = function(idx)
            local n = tonumber(idx)
            if n ~= nil then
                local chosen = kind_values[math.floor(n) + 1] or "none"
                dispatch_ipc("set_kind", combo.id .. ":" .. chosen)
            end
        end,
    }
    if kind_index ~= nil then kind_props.selectedIndex = kind_index end
    rows[#rows + 1] = ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = tr("detail.kind_label"), fontWeight = "bold", fontSize = 13 }),
        ui.select(kind_props),
    })

    -- Rename
    if rename_id == combo.id then
        rows[#rows + 1] = ui.row({ gap = 8, align = "center" }, {
            ui.input({
                key = "rename_input",
                value = rename_value,
                placeholder = tr("detail.rename_placeholder"),
                flexGrow = 1,
                onChange = function(text)
                    rename_value = text or ""
                    rename_error = ""
                end,
            }),
            ui.button({
                glyph = "check",
                variant = "primary",
                tooltip = tr("detail.rename_save"),
                onClick = function()
                    if not valid_name(rename_value) then
                        rename_error = tr("error.invalid_name")
                        render()
                        return
                    end
                    dispatch_ipc("rename_combo", combo.id .. ":" .. rename_value)
                    rename_id = nil
                    rename_value = ""
                    rename_error = ""
                    render()
                end,
            }),
            ui.button({
                glyph = "x",
                variant = "secondary",
                tooltip = tr("detail.rename_cancel"),
                onClick = function()
                    rename_id = nil
                    rename_value = ""
                    rename_error = ""
                    render()
                end,
            }),
        })
        if rename_error ~= "" then
            rows[#rows + 1] = ui.label({ text = rename_error, color = "error", fontSize = 12, maxWidth = WRAP })
        end
    else
        rows[#rows + 1] = ui.button({
            text = tr("detail.rename"),
            glyph = "pencil",
            variant = "outline",
            onClick = function()
                rename_id = combo.id
                rename_value = combo.name or ""
                render()
            end,
        })
    end

    rows[#rows + 1] = ui.separator({})

    -- Model chain (reorderable via drag-and-drop)
    rows[#rows + 1] = ui.row({ justify = "space_between", align = "center" }, {
        ui.label({ text = tr("detail.models_title"), fontWeight = "bold", fontSize = 13 }),
        ui.button({
            glyph = "plus",
            variant = "secondary",
            tooltip = tr("detail.add_model"),
            onClick = function()
                adding_model = true
                model_search = ""
                render()
            end,
        }),
    })
    local models = combo.models or {}
    local model_items = {}
    if #models == 0 then
        model_items[#model_items + 1] = ui.label({ text = tr("detail.no_models"), opacity = 0.7, maxWidth = WRAP })
    else
        model_items[#model_items + 1] = ui.label({ text = tr("detail.drag_hint"), opacity = 0.6, fontSize = 11, maxWidth = WRAP })
        for i, m in ipairs(models) do
            local idx = i
            model_items[#model_items + 1] = ui.dropZone({
                key = "drop_" .. tostring(idx),
                value = tostring(idx),
                accepts = { "model" },
                onDrop = function(payload, target)
                    dispatch_ipc("move_model", combo.id .. ":" .. tostring(payload) .. ":" .. tostring(target))
                end,
                direction = "column",
                gap = 6,
                padding = 2,
                radius = 8,
            }, {
                ui.dragSource({
                    key = "drag_" .. tostring(idx),
                    dragType = "model",
                    payload = tostring(idx),
                }, {
                    ui.row({
                        justify = "space_between",
                        align = "center",
                        padding = 8,
                        radius = 8,
                        fill = "surface",
                        border = "surface",
                        borderWidth = 1,
                    }, {
                        ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
                            ui.glyph({ name = "grip-vertical", color = "on_surface", size = 16, opacity = 0.5 }),
                            ui.label({ text = tostring(idx), color = "primary", fontWeight = "bold", fontSize = 12 }),
                            ui.label({ text = tostring(m), maxWidth = WRAP - 140, fontSize = 13 }),
                        }),
                        ui.button({
                            glyph = "x",
                            variant = "ghost",
                            tooltip = tr("detail.remove_model"),
                            onClick = function()
                                dispatch_ipc("remove_model", combo.id .. ":" .. tostring(idx))
                            end,
                        }),
                    }),
                }),
            })
        end
    end
    rows[#rows + 1] = ui.scroll({ flexGrow = 1, gap = 6, align = "stretch", justify = "start" }, model_items)

    panel.render(ui.column({ padding = PAD, gap = 8, flexGrow = 1, align = "stretch", justify = "start" }, rows))
end

-- ── add model view ───────────────────────────────────────────────────────────────

local function render_add_model(combo)
    local rows = {}

    rows[#rows + 1] = ui.row({ justify = "space_between", align = "center" }, {
        ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
            ui.button({
                glyph = "chevron-left",
                variant = "ghost",
                tooltip = tr("add_model.back"),
                onClick = function()
                    adding_model = false
                    model_search = ""
                    render()
                end,
            }),
            ui.glyph({ name = "plus", color = "primary", size = 20 }),
            ui.label({ text = tr("add_model.title"), fontSize = 18, fontWeight = "bold", color = "on_surface" }),
        }),
    })

    rows[#rows + 1] = ui.separator({})

    rows[#rows + 1] = ui.input({
        key = "model_search",
        value = model_search,
        placeholder = tr("add_model.search"),
        onChange = function(text)
            model_search = text or ""
            render()
        end,
    })

    -- Available models from the system, minus ones already in this combo.
    local all_models = noctalia.state.get(STATE.models) or {}
    local in_combo = {}
    for _, m in ipairs(combo.models or {}) do in_combo[m] = true end
    local needle = string.lower(model_search)
    local items = {}
    local count = 0
    for _, m in ipairs(all_models) do
        if type(m) == "table" and type(m.fullModel) == "string" then
            local full = m.fullModel
            if not in_combo[full] then
                if needle == "" or string.find(string.lower(full), needle, 1, true) then
                    count = count + 1
                    items[#items + 1] = ui.button({
                        key = "add_" .. full,
                        text = full,
                        variant = "outline",
                        contentAlign = "start",
                        onClick = function()
                            dispatch_ipc("add_model", combo.id .. ":" .. full)
                            adding_model = false
                            model_search = ""
                            render()
                        end,
                    })
                end
            end
        end
    end

    if count == 0 then
        items[#items + 1] = ui.label({
            text = needle ~= "" and tr("add_model.no_match") or tr("add_model.empty"),
            opacity = 0.7,
            maxWidth = WRAP,
        })
    end

    rows[#rows + 1] = ui.scroll({ flexGrow = 1, gap = 6, align = "stretch", justify = "start" }, items)

    panel.render(ui.column({ padding = PAD, gap = 8, flexGrow = 1, align = "stretch", justify = "start" }, rows))
end

-- ── login view ────────────────────────────────────────────────────────────────

local function render_login()
    local rows = {}

    rows[#rows + 1] = ui.row({ justify = "space_between", align = "center" }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "lock", color = "error", size = 24 }),
            ui.label({ text = tr("login.title"), fontSize = 18, fontWeight = "bold", color = "on_surface" }),
        }),
    })

    rows[#rows + 1] = ui.separator({})

    rows[#rows + 1] = ui.label({ text = tr("login.hint"), opacity = 0.7, fontSize = 12, maxWidth = WRAP })

    rows[#rows + 1] = ui.input({
        key = "login_password",
        value = login_password,
        placeholder = tr("login.password_placeholder"),
        password = true,
        onChange = function(text)
            login_password = text or ""
        end,
    })

    -- Error banner (if any)
    local err = noctalia.state.get(STATE.last_error)
    if type(err) == "table" and err.message then
        rows[#rows + 1] = ui.row({ gap = 8, align = "center", padding = 8, radius = 8, fill = "error/0.15", border = "error", borderWidth = 1 }, {
            ui.glyph({ name = "alert-circle", color = "error", size = 16 }),
            ui.column({ gap = 2, flexGrow = 1 }, {
                ui.label({ text = err.message, color = "error", fontSize = 13, fontWeight = "bold", maxWidth = WRAP - 40 }),
                ui.label({ text = err.detail or "", fontSize = 11, opacity = 0.75, maxWidth = WRAP - 40 }),
            }),
        })
    end

    rows[#rows + 1] = ui.separator({})

    rows[#rows + 1] = ui.row({ justify = "end", gap = 8 }, {
        ui.button({
            text = tr("login.submit"),
            glyph = "login",
            variant = "primary",
            onClick = function()
                dispatch_ipc("login", login_password)
                login_password = ""
                render()
            end,
        }),
    })

    panel.render(ui.column({ padding = PAD, gap = 8, flexGrow = 1, align = "stretch", justify = "start" }, rows))
end

-- ── main render ──────────────────────────────────────────────────────────────

render = function()
    local conn = noctalia.state.get(STATE.connection)
    local combos = noctalia.state.get(STATE.combos) or {}
    local selected_id = noctalia.state.get(STATE.selected)

    -- Login view takes priority when the dashboard requires authentication.
    if type(conn) == "table" and conn.status == "auth_required" then
        render_login()
        return
    end

    -- Create view takes priority
    if creating then
        render_create()
        return
    end

    -- Detail view when a combo is selected and still exists
    local selected = find_combo(combos, selected_id)
    if selected then
        if adding_model then
            render_add_model(selected)
            return
        end
        render_detail(selected)
        return
    end

    -- Otherwise the list view
    render_list(combos, conn)
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

local function fingerprint_state()
    local conn = noctalia.state.get(STATE.connection)
    local combos = noctalia.state.get(STATE.combos)
    local selected_id = noctalia.state.get(STATE.selected)
    local err = noctalia.state.get(STATE.last_error)
    return table.concat({
        (type(conn) == "table" and conn.status or "offline"),
        tostring(selected_id or "none"),
        (type(err) == "table" and tostring(err.message) or "none"),
        combos_fingerprint(combos),
    }, "\1")
end

local snap_cache = { fingerprint = nil }

function onOpen(_context)
    panel.setWantsSecondTicks(true)
    for _, key in pairs(STATE) do
        noctalia.state.watch(key, function()
            local fp = fingerprint_state()
            if fp ~= snap_cache.fingerprint then
                snap_cache.fingerprint = fp
                render()
            end
        end)
    end
    render()
end

function onClose()
end

function update()
    local fp = fingerprint_state()
    if fp ~= snap_cache.fingerprint then
        snap_cache.fingerprint = fp
        render()
    end
end
