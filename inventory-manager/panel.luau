--!nonstrict
-- panel.luau
-- Inventory management panel with category switcher (+ and list icon)

local products = {}
local allCategories = {}
local categoryInputMode = "existing"
local selectedCategory = "all"
local draftName = ""
local draftCategory = ""
local draftQuantity = ""
local draftKey = 0
local draftError = ""
local showAddForm = false
local hoveredProductId = nil
local editingProductId = nil
local pendingDeleteId = nil
local pendingImport = false

local DRAG_TYPE = "inventory-product"

local render

local function extractCatName(item)
    if type(item) == "string" and item ~= "" then
        return item
    elseif type(item) == "table" then
        return item.name or item.label or item.title or item.category or item.value
    end
    return nil
end

local function getCategoryList()
    local catSet = {}

    if type(allCategories) == "table" then
        for _, cat in ipairs(allCategories) do 
            local name = extractCatName(cat)
            if name and name ~= "" then catSet[name] = true end 
        end
    end

    if type(products) == "table" then
        for _, p in ipairs(products) do 
            if type(p) == "table" and p.category and p.category ~= "" then 
                catSet[p.category] = true 
            end 
        end
    end

    local list = {}
    for cat, _ in pairs(catSet) do 
        table.insert(list, cat) 
    end
    table.sort(list)
    return list, catSet
end

local function resetCategoryMode()
    local catList, catSet = getCategoryList()
    if #catList == 0 then
        categoryInputMode = "new"
        draftCategory = ""
    else
        categoryInputMode = "existing"
        if draftCategory == "" or not catSet[draftCategory] then
            draftCategory = catList[1]
        end
    end
end

-- Color mapping
local COLOR_MAP = {
    black = "#000000", preto = "#000000",
    white = "#ffffff", branco = "#ffffff",
    ciano = "#00e5ff", cyan = "#00e5ff",
    yellow = "#ffea00", amarelo = "#ffea00",
    magenta = "#ff00ff",
    purple = "#9c27b0", roxo = "#9c27b0",
    red = "#ff0000", vermelho = "#ff0000",
    green = "#00ff00", verde = "#00ff00",
    blue = "#2979ff", azul = "#2979ff",
    orange = "#ff6d00", laranja = "#ff6d00",
    pink = "#ff4081", rosa = "#ff4081",
    gray = "#9e9e9e", cinza = "#9e9e9e"
}

local function getFilteredProducts()
    local filtered = {}
    if selectedCategory == "all" then
        for _, product in ipairs(products) do
            table.insert(filtered, product)
        end
    else
        for _, product in ipairs(products) do
            if (product.category or "Geral") == selectedCategory then
                table.insert(filtered, product)
            end
        end
    end

    local isManual = noctalia.getConfig("manual_sorting")
    if isManual == false then
        table.sort(filtered, function(a, b)
            return (a.name or ""):lower() < (b.name or ""):lower()
        end)
    end
    return filtered
end

local function getCategoryTotal(categoryName)
    local total = 0
    for _, product in ipairs(products) do
        if (product.category or "Geral") == categoryName then
            total = total + (product.total_quantity or 0)
        end
    end
    return total
end

local function extractColorFromName(name)
    if not name then return nil end
    local lowerName = name:lower()
    for colorName, _ in pairs(COLOR_MAP) do
        if lowerName:find(colorName, 1, true) then
            return colorName
        end
    end
    return nil
end

local function createColorDot(colorName)
    if not colorName then return nil end
    local hexColor = COLOR_MAP[colorName] or "#888888"
    return ui.box({
        fill = hexColor,
        radius = 6,
        width = 12,
        height = 12,
        align = "center",
        justify = "center",
        border = "outline",
        borderWidth = 1
    })
end

local function createQuantityCapsule(displayQty, badgeColor, badgeTextColor)
    local displayText = (displayQty == 0) and noctalia.tr("panel.zerado") or (noctalia.tr("panel.bucket.available") .. ": " .. displayQty)
    return ui.row({
        fill = badgeColor,
        radius = 12,
        paddingH = 10,
        paddingV = 4,
        align = "center",
        justify = "center"
    }, {
        ui.label({
            text = displayText,
            fontSize = 12,
            fontWeight = "bold",
            color = badgeTextColor
        })
    })
end

local function createTotalCapsule(total)
    return ui.row({
        fill = "surface_variant/0.5",
        radius = 12,
        paddingH = 10,
        paddingV = 4,
        align = "center",
        justify = "center"
    }, {
        ui.label({
            text = noctalia.tr("panel.bucket.total") .. ": " .. total,
            fontSize = 12,
            fontWeight = "bold",
            color = "on_surface"
        })
    })
end

local function createSimpleCapsule(labelText, count, capsuleColor)
    return ui.row({
        fill = capsuleColor,
        radius = 12,
        paddingH = 10,
        paddingV = 4,
        align = "center",
        justify = "center"
    }, {
        ui.label({
            text = labelText .. ": " .. count,
            fontSize = 12,
            fontWeight = "bold",
            color = "#ffffff"
        })
    })
end

local function createStockCapsule(totalProducts)
    local text = (totalProducts == 1) and 
                 string.format(noctalia.tr("panel.stock_singular"), totalProducts) or
                 string.format(noctalia.tr("panel.stock_plural"), totalProducts)
    
    local dateTime = os.date("%d/%m/%Y %H:%M", os.time())
    
    return ui.row({
        gap = 8,
        align = "center",
        padding = { 2, 0 }
    }, {
        ui.row({
            fill = "#b0ce0a",
            radius = 12,
            paddingH = 12,
            paddingV = 5,
            align = "center",
            justify = "center",
            gap = 4
        }, {
            ui.glyph({ name = "package", size = 13, color = "#1d0101" }),
            ui.label({ text = text, fontSize = 12, fontWeight = "bold", color = "#000000" })
        }),
        ui.row({
            fill = "#616161",
            radius = 12,
            paddingH = 12,
            paddingV = 5,
            align = "center",
            justify = "center",
            gap = 4
        }, {
            ui.glyph({ name = "clock", size = 13, color = "#ffffff" }),
            ui.label({ text = dateTime, fontSize = 12, fontWeight = "bold", color = "#ffffff" })
        })
    })
end

local function createInfoCapsule(value, icon, color)
    if not value or value == "" then return nil end
    return ui.row({
        fill = color,
        radius = 12,
        paddingH = 10,
        paddingV = 4,
        align = "center",
        justify = "center",
        gap = 4
    }, {
        ui.glyph({ name = icon or "info", size = 12, color = "#ffffff" }),
        ui.label({ text = value, fontSize = 11, fontWeight = "bold", color = "#ffffff" })
    })
end

local function insertionZone(key, targetSpec)
    return ui.dropZone({
        key          = "gap-" .. key,
        accepts      = { DRAG_TYPE },
        value        = targetSpec,
        onDrop       = "onProductDropped",
        height       = 3,
        radius       = 4,
        expandOnDrag = true,
        hitSlop      = 24,
    })
end

function onProductDropped(payload, value)
    -- The dropped-on target is identified by a neighboring product's id
    -- ("before:<id>" / "after:<id>") rather than a raw position number.
    -- Using an id means the service can find that product's true index in
    -- the FULL (unfiltered) product list, so reordering still lands in the
    -- right spot even while a category tab is filtering what's shown here -
    -- a plain "insert at position N" index would only be correct for the
    -- filtered view, not the full list the service actually reorders.
    if type(payload) ~= "string" or payload == "" or type(value) ~= "string" then
        return
    end
    local kind, anchorId = value:match("^(%a+):(.+)$")
    if not kind or not anchorId or anchorId == payload then
        return
    end
    noctalia.state.set("inventory.cmd", { op = "reorder", id = payload, anchor_kind = kind, anchor_id = anchorId })
end

local function resolveExportDir()
    local custom = noctalia.string.trim(noctalia.getConfig("export_folder") or "")
    if custom ~= "" then
        if custom:sub(1, 1) == "~" then
            local home = os.getenv("HOME")
            if home then custom = home .. custom:sub(2) end
        end
        return custom
    end
    return noctalia.pluginDataDir()
end

local function exportStock()
    local productsData = noctalia.state.get("inventory.products") or {}
    if #productsData == 0 then
        noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.no_products"))
        return
    end
    
    local exportData = {
        exported_at = os.date("%d/%m/%Y %H:%M:%S"),
        total_products = #productsData,
        products = productsData
    }
    
    local ok, encoded = pcall(noctalia.json.encode, exportData)
    if not ok or not encoded then
        noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.export_error"))
        return
    end
    
    local dir = resolveExportDir()
    if not dir or dir == "" then
        noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.export_error"))
        return
    end
    
    local filepath = dir .. "/estoque_" .. os.date("%Y%m%d_%H%M%S") .. ".json"
    if pcall(noctalia.writeFile, filepath, encoded) then
        noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.export_success") .. " (" .. filepath .. ")")
    else
        noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.export_error"))
    end
end

local function importStock()
    local dir = resolveExportDir()
    if not dir or dir == "" then
        noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.import_error"))
        return
    end
    
    local files = noctalia.listDir(dir)
    local jsonFiles = {}
    if files then
        for _, file in ipairs(files) do
            if file:sub(-5) == ".json" and file:sub(1, 7) == "estoque" then
                table.insert(jsonFiles, file)
            end
        end
    end
    
    if #jsonFiles == 0 then
        noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.import_no_files"))
        return
    end
    
    table.sort(jsonFiles, function(a, b) return a > b end)
    local raw = noctalia.readFile(dir .. "/" .. jsonFiles[1])
    if not raw then
        noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.import_error"))
        return
    end
    
    local ok, data = pcall(noctalia.json.decode, raw)
    if not ok or not data or not data.products then
        noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.import_error"))
        return
    end
    
    local currentProducts = noctalia.state.get("inventory.products") or {}
    for _, product in ipairs(currentProducts) do
        noctalia.state.set("inventory.cmd", { op = "delete", id = product.id })
    end
    
    noctalia.runAsync("sleep 0.3", function()
        for _, product in ipairs(data.products) do
            noctalia.state.set("inventory.cmd", {
                op = "add",
                name = product.name,
                category = product.category or "Geral",
                available_quantity = product.available_quantity or product.quantity or 0,
                in_use_quantity = product.in_use_quantity or 0,
                reserved_quantity = product.reserved_quantity or 0,
                defective_quantity = product.defective_quantity or product.damage_quantity or 0
            })
        end
        noctalia.notify(noctalia.tr("panel.title"), string.format(noctalia.tr("panel.import_success"), #data.products))
        noctalia.runAsync("sleep 0.3", function() render() end)
    end)
end

local function onAdjustBucket(product, bucketType, delta)
    noctalia.state.set("inventory.cmd", { 
        op = "adjust", id = product.id, delta = delta, type = bucketType
    })
    noctalia.runAsync("sleep 0.1", function() render() end)
end

local function confirmDelete(productId)
    noctalia.state.set("inventory.cmd", { op = "delete", id = productId })
    pendingDeleteId = nil
    noctalia.runAsync("sleep 0.1", function() render() end)
end

local function cancelDelete()
    pendingDeleteId = nil
    render()
end

local function requestDelete(productId)
    pendingDeleteId = productId
    render()
end

local function startEdit(product)
    editingProductId = product.id
    draftName = product.name or ""
    draftCategory = product.category or ""
    draftQuantity = tostring(product.available_quantity or 0)
    draftError = ""
    draftKey = draftKey + 1

    local catList, catSet = getCategoryList()
    if #catList == 0 then
        categoryInputMode = "new"
    else
        if draftCategory ~= "" and catSet[draftCategory] then
            categoryInputMode = "existing"
        elseif draftCategory ~= "" and not catSet[draftCategory] then
            categoryInputMode = "new"
        else
            categoryInputMode = "existing"
            draftCategory = catList[1]
        end
    end

    showAddForm = true
    render()
end

local function cancelEdit()
    editingProductId = nil
    draftName = ""
    draftCategory = ""
    draftQuantity = ""
    draftError = ""
    showAddForm = false
    draftKey = draftKey + 1
    render()
end

render = function()
    local column = {}
    
    local storeName = noctalia.getConfig("store_name") or ""
    local storeNumber = noctalia.getConfig("store_number") or ""
    local storeCnpj = noctalia.getConfig("store_cnpj") or ""
    local tiName = noctalia.getConfig("ti_name") or ""
    local isManual = noctalia.getConfig("manual_sorting") ~= false
    
    local headerChildren = {}
    local headerRow1 = {}
    
    table.insert(headerRow1, ui.label({
        text = noctalia.tr("panel.title"),
        fontSize = 18,
        fontWeight = "bold",
        color = "on_surface",
        flexGrow = 1
    }))
    
    local headerButtons = {}
    table.insert(headerButtons, ui.button({
        glyph = "plus", variant = "outline", controlSize = "sm",
        tooltip = noctalia.tr("panel.add_product"), border = "outline", borderWidth = 1,
        onClick = function()
            if showAddForm then 
                cancelEdit()
            else
                editingProductId = nil draftName = "" draftCategory = "" draftQuantity = "" draftError = ""
                draftKey = draftKey + 1 resetCategoryMode() showAddForm = true render()
            end
        end
    }))
    table.insert(headerButtons, ui.button({
        glyph = "download", variant = "outline", controlSize = "sm",
        tooltip = noctalia.tr("panel.export"), border = "outline", borderWidth = 1,
        onClick = function() exportStock() end
    }))
    table.insert(headerButtons, ui.button({
        glyph = "upload", variant = "outline", controlSize = "sm",
        tooltip = noctalia.tr("panel.import"), border = "outline", borderWidth = 1,
        onClick = function() pendingImport = true render() end
    }))
    table.insert(headerButtons, ui.button({
        glyph = "refresh", variant = "outline", controlSize = "sm",
        tooltip = noctalia.tr("panel.refresh"), border = "outline", borderWidth = 1,
        onClick = function() noctalia.state.set("inventory.cmd", { op = "refresh" }) render() end
    }))
    table.insert(headerButtons, ui.button({
        glyph = "settings", variant = "outline", controlSize = "sm",
        tooltip = noctalia.tr("panel.settings"), border = "outline", borderWidth = 1,
        onClick = function() noctalia.openSettings() end
    }))
    table.insert(headerButtons, ui.button({
        glyph = "close", variant = "outline", controlSize = "sm",
        tooltip = noctalia.tr("panel.close"), border = "outline", borderWidth = 1,
        onClick = function() panel.close() end
    }))
    
    table.insert(headerRow1, ui.row({ gap = 4, align = "center" }, headerButtons))
    table.insert(headerChildren, ui.row({ align = "center", justify = "space_between" }, headerRow1))
    
    local infoCapsules = {}
    if tiName ~= "" then table.insert(infoCapsules, createInfoCapsule(tiName, "user", "#e65100")) end
    if storeName ~= "" then table.insert(infoCapsules, createInfoCapsule(storeName, "building-store", "#1976d2")) end
    if storeNumber ~= "" then table.insert(infoCapsules, createInfoCapsule(storeNumber, "note", "#f18304")) end
    if storeCnpj ~= "" then table.insert(infoCapsules, createInfoCapsule(storeCnpj, "file-text", "#7b1fa2")) end
    
    if #infoCapsules > 0 then
        table.insert(headerChildren, ui.row({ gap = 6, align = "center", padding = { 4, 0 }, wrap = true }, infoCapsules))
    end
    
    local stockCapsule = createStockCapsule(#products)
    if stockCapsule then
        table.insert(headerChildren, ui.row({ align = "center", padding = { 4, 0 } }, { stockCapsule }))
    end
    
    local displayCategories, _ = getCategoryList()
    if #displayCategories > 0 then
        local allCatChildren = {}
        table.insert(allCatChildren, ui.row({
            fill = selectedCategory == "all" and "primary" or "surface_variant/0.5",
            radius = 12, paddingH = 10, paddingV = 4, align = "center", justify = "center",
            onClick = function() selectedCategory = "all" render() end
        }, {
            ui.label({
                text = string.format(noctalia.tr("panel.all") .. " (%d)", #products),
                fontSize = 11, fontWeight = "bold",
                color = selectedCategory == "all" and "on_primary" or "on_surface"
            })
        }))
        
        for _, cat in ipairs(displayCategories) do
            local total = getCategoryTotal(cat)
            local isSelected = selectedCategory == cat
            table.insert(allCatChildren, ui.row({
                fill = isSelected and "primary" or "surface_variant/0.5",
                radius = 12, paddingH = 10, paddingV = 4, align = "center", justify = "center",
                onClick = function() selectedCategory = cat render() end
            }, {
                ui.label({
                    text = cat .. " (" .. total .. ")",
                    fontSize = 11, fontWeight = isSelected and "bold" or "regular",
                    color = isSelected and "on_primary" or "on_surface"
                })
            }))
        end
        
        local catRows = {}
        local currentRow = {}
        local itemsPerRow = 4
        for i, child in ipairs(allCatChildren) do
            table.insert(currentRow, child)
            if i % itemsPerRow == 0 or i == #allCatChildren then
                table.insert(catRows, ui.row({ gap = 4, align = "center" }, currentRow))
                currentRow = {}
            end
        end
        
        table.insert(headerChildren, ui.column({
            gap = 4, padding = { 4, 6 }, radius = 6, fill = "surface_variant/0.08", align = "stretch"
        }, catRows))
    end
    
    table.insert(column, ui.column({ gap = 6, padding = { 0, 0, 8, 0 } }, headerChildren))
    
    if pendingImport then
        table.insert(column, ui.column({
            gap = 6, padding = 10, radius = 8, fill = "#c62828", align = "stretch"
        }, {
            ui.label({ text = noctalia.tr("panel.import_confirm_message"), fontSize = 12, fontWeight = "bold", color = "#ffffff" }),
            ui.row({ gap = 6, justify = "end" }, {
                ui.button({ text = noctalia.tr("panel.confirm"), variant = "destructive", controlSize = "sm", onClick = function() pendingImport = false render() importStock() end }),
                ui.button({ text = noctalia.tr("panel.form.cancel"), variant = "ghost", controlSize = "sm", onClick = function() pendingImport = false render() end })
            })
        }))
    end
    
    if showAddForm then
        local isEditing = editingProductId ~= nil
        local formTitle = isEditing and noctalia.tr("panel.form.edit_title") or noctalia.tr("panel.form.add_title")
        local buttonText = isEditing and noctalia.tr("panel.form.update") or noctalia.tr("panel.form.save")
        
        local formContainer = {}
        table.insert(formContainer, ui.label({ text = formTitle, fontSize = 13, fontWeight = "bold", color = "primary" }))
        
        local HEADER_HEIGHT = 22

        -- Row 1: Name and Quantity
        local row1 = {}

        table.insert(row1, ui.column({ flexGrow = 1, gap = 4 }, {
            ui.row({ height = HEADER_HEIGHT, align = "center" }, {
                ui.label({ text = noctalia.tr("panel.form.name"), fontSize = 11, fontWeight = "bold" })
            }),
            ui.input({
                key = "add-name-" .. draftKey, value = draftName,
                placeholder = noctalia.tr("panel.form.name_placeholder"), controlSize = "sm",
                onChange = function(value) draftName = value draftError = "" end
            })
        }))

        table.insert(row1, ui.column({ width = 90, gap = 4 }, {
            ui.row({ height = HEADER_HEIGHT, align = "center" }, {
                ui.label({ text = noctalia.tr("panel.form.quantity"), fontSize = 11, fontWeight = "bold" })
            }),
            ui.input({
                key = "add-quantity-" .. draftKey, value = draftQuantity,
                placeholder = "0", controlSize = "sm",
                onChange = function(value) draftQuantity = value end
            })
        }))

        table.insert(formContainer, ui.row({ gap = 6, align = "start" }, row1))

        -- Row 2: Category
        local catList, catSet = getCategoryList()
        local hasCategories = #catList > 0

        local categoryControl

        if categoryInputMode == "existing" and hasCategories then
            if draftCategory == "" or not catSet[draftCategory] then
                draftCategory = catList[1]
            end

            local selectedIdx = 0
            for i, cat in ipairs(catList) do
                if cat == draftCategory then
                    selectedIdx = i - 1
                    break
                end
            end

            categoryControl = ui.select({
                key = "add-cat-select-" .. draftKey .. "-" .. categoryInputMode,
                options = catList,
                selectedIndex = selectedIdx,
                controlSize = "sm",
                flexGrow = 1,
                onChange = function(val)
                    -- ui.select delivers the selected option's index as a
                    -- string (e.g. "0", "1"), not the option's text - look it
                    -- back up in catList instead of using val directly as a
                    -- name (that bug made every pick collapse back to the
                    -- first category on the next render).
                    local idx = tonumber(val)
                    if idx ~= nil and catList[idx + 1] then
                        draftCategory = catList[idx + 1]
                        render()
                    end
                end
            })
        else
            categoryControl = ui.input({
                key = "add-cat-input-" .. draftKey .. "-" .. categoryInputMode,
                value = draftCategory,
                placeholder = noctalia.tr("panel.form.category_placeholder"),
                controlSize = "sm",
                flexGrow = 1,
                onChange = function(value)
                    draftCategory = value
                end
            })
        end

        local categoryRowElements = { categoryControl }

        if hasCategories then
            if categoryInputMode == "existing" then
                table.insert(categoryRowElements, ui.button({
                    glyph = "plus",
                    variant = "outline",
                    controlSize = "sm",
                    tooltip = noctalia.tr("panel.form.category_tooltip_new"),
                    onClick = function()
                        categoryInputMode = "new"
                        draftCategory = ""
                        draftKey = draftKey + 1
                        render()
                    end
                }))
            else
                table.insert(categoryRowElements, ui.button({
                    glyph = "list",
                    variant = "outline",
                    controlSize = "sm",
                    tooltip = noctalia.tr("panel.form.category_tooltip_existing"),
                    onClick = function()
                        categoryInputMode = "existing"
                        local currentList = getCategoryList()
                        if #currentList > 0 then
                            draftCategory = currentList[1]
                        end
                        draftKey = draftKey + 1
                        render()
                    end
                }))
            end
        end

        table.insert(formContainer, ui.column({ gap = 4 }, {
            ui.row({ height = HEADER_HEIGHT, align = "center" }, {
                ui.label({ text = noctalia.tr("panel.form.category"), fontSize = 11, fontWeight = "bold" })
            }),
            ui.row({ gap = 6, align = "center" }, categoryRowElements)
        }))
        
        -- Form buttons
        table.insert(formContainer, ui.row({ gap = 4, justify = "end" }, {
            ui.button({
                text = buttonText, variant = "primary", controlSize = "sm",
                onClick = function()
                    if isEditing then onEditSubmit() else onAddSubmit() end
                end
            }),
            ui.button({
                text = noctalia.tr("panel.form.cancel"), variant = "ghost", controlSize = "sm",
                onClick = function() cancelEdit() end
            })
        }))
        
        if draftError ~= "" then
            table.insert(formContainer, ui.label({ text = draftError, color = "#c62828", fontSize = 11 }))
        end
        
        table.insert(column, ui.column({
            gap = 6, padding = 8, radius = 8, fill = "surface_variant/0.35", align = "stretch"
        }, formContainer))
    end
    
    local filteredProducts = getFilteredProducts()
    
    if #filteredProducts == 0 then
        table.insert(column, ui.column({
            gap = 12, align = "center", padding = 32, flexGrow = 1, justify = "center"
        }, {
            ui.glyph({ name = "package", size = 48, color = "outline" }),
            ui.label({ 
                text = (selectedCategory ~= "all") and noctalia.tr("panel.no_category") or noctalia.tr("panel.no_products"),
                color = "outline", fontSize = 14 
            }),
            ui.button({
                text = noctalia.tr("panel.add_first"), variant = "primary",
                onClick = function()
                    editingProductId = nil draftName = "" draftCategory = "" draftQuantity = ""
                    draftKey = draftKey + 1 resetCategoryMode() showAddForm = true render()
                end
            })
        }))
    else
        local rows = {}
        for i, product in ipairs(filteredProducts) do
            if isManual then
                table.insert(rows, insertionZone(product.id, "before:" .. product.id))
            end

            local availableQty = product.available_quantity or 0
            local inUseQty = product.in_use_quantity or 0
            local defectiveQty = product.defective_quantity or 0
            local totalQty = product.total_quantity or (availableQty + inUseQty + defectiveQty)
            local lowThreshold = noctalia.getConfig("low_stock_threshold") or 3
            
            local isZero = availableQty == 0
            local isLowStock = availableQty <= lowThreshold and availableQty > 0
            local colorName = extractColorFromName(product.name)
            
            local badgeColor = isZero and "#c62828" or (isLowStock and "#f2b705" or "#2e7d32")
            local badgeTextColor = (isLowStock and not isZero) and "#000000" or "#ffffff"
            
            local isHovered = (hoveredProductId == product.id)
            local isPendingDelete = (pendingDeleteId == product.id)
            
            local function onCardHover(state)
                if state == "true" then hoveredProductId = product.id
                elseif hoveredProductId == product.id then hoveredProductId = nil end
                render()
            end
            
            local productRowChildren = {}

            if isManual then
                table.insert(productRowChildren, ui.dragSource({
                    key             = "grip-" .. product.id,
                    dragType        = DRAG_TYPE,
                    payload         = product.id,
                    previewAncestor = 1,
                    liftFromLayout  = true,
                    width           = 20,
                    height          = 20,
                    align           = "center",
                    justify         = "center",
                    tooltip         = noctalia.tr("panel.tooltip_drag"),
                }, {
                    ui.glyph({ name = "menu", size = 14, color = "on_surface_variant" }),
                }))
            end

            local mainColumnChildren = {}
            local row1Elements = {}
            
            if colorName then
                local dot = createColorDot(colorName)
                if dot then table.insert(row1Elements, dot) end
            end
            
            -- Product name is always shown in bold
            table.insert(row1Elements, ui.label({ 
                text = product.name, 
                fontWeight = "bold", 
                fontSize = 13 
            }))
            
            table.insert(row1Elements, createQuantityCapsule(availableQty, badgeColor, badgeTextColor))
            if inUseQty > 0 then table.insert(row1Elements, createSimpleCapsule(noctalia.tr("panel.bucket.in_use"), inUseQty, "#1976d2")) end
            if defectiveQty > 0 then table.insert(row1Elements, createSimpleCapsule(noctalia.tr("panel.bucket.defective"), defectiveQty, "#c62828")) end
            -- Total is only useful once it actually differs from Available -
            -- that only happens once some stock sits in In use or Damage, so
            -- skip it otherwise even when the setting is enabled.
            if noctalia.getConfig("show_total_quantity") ~= false and (inUseQty > 0 or defectiveQty > 0) then
                table.insert(row1Elements, createTotalCapsule(totalQty))
            end
            
            table.insert(mainColumnChildren, ui.row({ gap = 6, align = "center" }, row1Elements))
            
            local row2Elements = {}
            table.insert(row2Elements, ui.row({
                border = "outline", borderWidth = 1, radius = 10, paddingH = 8, paddingV = 2, align = "center", justify = "center"
            }, {
                ui.label({ text = product.category or "Geral", fontSize = 10, color = "on_surface_variant", fontWeight = "medium" })
            }))
            
            local actionsRow = {}
            table.insert(actionsRow, ui.button({
                glyph = "pencil", variant = "ghost", controlSize = "sm",
                tooltip = noctalia.tr("panel.edit_product"), onHover = onCardHover,
                onClick = function() startEdit(product) end
            }))
            
            if isPendingDelete then
                table.insert(actionsRow, ui.label({ text = noctalia.tr("panel.confirm_delete"), fontSize = 10, fontWeight = "bold", color = "#c62828", paddingH = 4 }))
                table.insert(actionsRow, ui.button({ glyph = "check", variant = "destructive", controlSize = "sm", tooltip = noctalia.tr("panel.confirm"), onHover = onCardHover, onClick = function() confirmDelete(product.id) end }))
                table.insert(actionsRow, ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.form.cancel"), onHover = onCardHover, onClick = function() cancelDelete() end }))
            else
                table.insert(actionsRow, ui.button({ glyph = "trash", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.delete"), onHover = onCardHover, onClick = function() requestDelete(product.id) end }))
            end
            
            table.insert(actionsRow, ui.button({ glyph = "plus", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.bucket.available") .. " +1", onHover = onCardHover, onClick = function() onAdjustBucket(product, "available", 1) end }))
            table.insert(actionsRow, ui.button({ glyph = "minus", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.bucket.available") .. " -1", enabled = availableQty > 0, onHover = onCardHover, onClick = function() onAdjustBucket(product, "available", -1) end }))
            table.insert(actionsRow, ui.button({ glyph = "arrow-right", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.bucket.in_use") .. " +1", enabled = availableQty > 0, onHover = onCardHover, onClick = function() onAdjustBucket(product, "in_use", 1) end }))
            table.insert(actionsRow, ui.button({ glyph = "arrow-left", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.bucket.in_use") .. " -1", enabled = inUseQty > 0, onHover = onCardHover, onClick = function() onAdjustBucket(product, "in_use", -1) end }))
            table.insert(actionsRow, ui.button({ glyph = "alert-triangle", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.bucket.defective") .. " +1", enabled = availableQty > 0, onHover = onCardHover, onClick = function() onAdjustBucket(product, "defective", 1) end }))
            table.insert(actionsRow, ui.button({ glyph = "circle-minus", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.bucket.defective") .. " -1", enabled = defectiveQty > 0, onHover = onCardHover, onClick = function() onAdjustBucket(product, "defective", -1) end }))
            
            table.insert(row2Elements, ui.row({ gap = 4, align = "center" }, actionsRow))
            table.insert(mainColumnChildren, ui.row({ gap = 8, align = "center" }, row2Elements))
            table.insert(productRowChildren, ui.column({ flexGrow = 1, gap = 2 }, mainColumnChildren))
            
            -- Card background uses "surface_variant/0.35" for better visibility
            table.insert(rows, ui.row({
                key = "product-" .. product.id, gap = 8, padding = 8, radius = 6,
                fill = isHovered and "surface_variant/0.5" or "surface_variant/0.35",
                border = isHovered and "outline" or "surface_variant/0.5", borderWidth = 1,
                align = "center", justify = "space_between", onHover = onCardHover
            }, productRowChildren))
        end

        if isManual and #filteredProducts > 0 then
            local lastProduct = filteredProducts[#filteredProducts]
            table.insert(rows, insertionZone("end-" .. lastProduct.id, "after:" .. lastProduct.id))
        end

        table.insert(column, ui.scroll({ gap = 4, flexGrow = 1 }, rows))
    end
    
    panel.render(ui.column({ gap = 8, padding = 8, flexGrow = 1, align = "stretch" }, column))
end

function onAddSubmit()
    local name = noctalia.string.trim(draftName)
    local category = noctalia.string.trim(draftCategory)
    local quantity = tonumber(draftQuantity) or 0
    
    if name == "" then
        draftError = noctalia.tr("panel.form.name_required")
        showAddForm = true
        render()
        return
    end
    
    noctalia.state.set("inventory.cmd", {
        op = "add",
        name = name,
        category = category ~= "" and category or "Geral",
        quantity = quantity
    })
    
    draftName = "" draftCategory = "" draftQuantity = "" draftError = ""
    showAddForm = false draftKey = draftKey + 1
    noctalia.runAsync("sleep 0.2", function() render() end)
end

function onEditSubmit()
    local name = noctalia.string.trim(draftName)
    local category = noctalia.string.trim(draftCategory)
    local quantity = tonumber(draftQuantity) or 0
    
    if name == "" then
        draftError = noctalia.tr("panel.form.name_required")
        showAddForm = true
        render()
        return
    end
    
    if editingProductId then
        noctalia.state.set("inventory.cmd", {
            op = "update",
            id = editingProductId,
            name = name,
            category = category ~= "" and category or "Geral",
            quantity = quantity
        })
    end

    editingProductId = nil
    draftName = "" draftCategory = "" draftQuantity = "" draftError = ""
    showAddForm = false draftKey = draftKey + 1
    noctalia.runAsync("sleep 0.2", function() render() end)
end

function onOpen(_context)
    products = noctalia.state.get("inventory.products") or {}
    allCategories = noctalia.state.get("inventory.all_categories") or {}
    hoveredProductId = nil
    editingProductId = nil
    pendingDeleteId = nil
    showAddForm = false
    render()
end

noctalia.state.watch("inventory.products", function(value)
    products = (type(value) == "table") and value or {}
    render()
end)

noctalia.state.watch("inventory.all_categories", function(value)
    allCategories = (type(value) == "table") and value or {}
    render()
end)