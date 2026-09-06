--!nonstrict
-- service.luau
-- Headless service

local products = {}
local dataPath = nil
local nextId = 1
local previousLowStockProducts = {}

local function trim(s)
    return noctalia.string.trim(s or "")
end

local function generateId()
    local id = "p" .. tostring(nextId)
    nextId = nextId + 1
    return id
end

local function computeNextId()
    local maxNum = 0
    for _, p in ipairs(products) do
        local numStr = p.id and tostring(p.id):match("^p(%d+)$")
        if numStr then
            local num = tonumber(numStr)
            if num and num > maxNum then maxNum = num end
        end
    end
    return maxNum + 1
end

local function dedupeProductIds()
    local seen = {}
    local changed = false
    for _, p in ipairs(products) do
        if seen[p.id] then
            p.id = generateId()
            changed = true
        end
        seen[p.id] = true
    end
    return changed
end

local function getTotal(product)
    return (product.available_quantity or 0)
        + (product.in_use_quantity or 0)
        + (product.defective_quantity or 0)
end

local function saveState()
    if dataPath == nil then return false end
    local ok, encoded = pcall(noctalia.json.encode, { products = products })
    if ok and type(encoded) == "string" then
        return pcall(noctalia.writeFile, dataPath, encoded) and true or false
    end
    return false
end

local function migrateProduct(p)
    if p.available_quantity == nil then
        local oldQuantity = p.quantity or 0
        local oldDamage = p.damage_quantity or 0
        p.available_quantity = math.max(oldQuantity - oldDamage, 0)
        p.defective_quantity = oldDamage
        p.quantity = nil p.damage_quantity = nil
    end
    if p.reserved_quantity and p.reserved_quantity ~= 0 then
        p.available_quantity = (p.available_quantity or 0) + p.reserved_quantity
    end
    p.reserved_quantity = nil
    p.in_use_quantity = p.in_use_quantity or 0
    p.defective_quantity = p.defective_quantity or 0
    p.available_quantity = p.available_quantity or 0
end

local function loadState()
    local dir = noctalia.pluginDataDir()
    if dir == nil then return end
    dataPath = dir .. "/state.json"

    local raw = noctalia.readFile(dataPath)
    if raw ~= nil then
        local ok, decoded = pcall(noctalia.json.decode, raw)
        if ok and type(decoded) == "table" and type(decoded.products) == "table" then
            products = decoded.products
            for _, p in ipairs(products) do migrateProduct(p) end
        else products = {} end
    else products = {} end
    
    nextId = computeNextId()
    if dedupeProductIds() then saveState() end
end

local function checkLowStockAlerts()
    local enableAlerts = noctalia.getConfig("enable_low_stock_alerts")
    if enableAlerts == false then return end

    local threshold = noctalia.getConfig("low_stock_threshold") or 3
    local currentLow = {}

    for _, product in ipairs(products) do
        local available = product.available_quantity or 0
        if available <= threshold then
            currentLow[product.id] = true
            if not previousLowStockProducts[product.id] then
                noctalia.notify(
                    noctalia.tr("panel.title"),
                    string.format(noctalia.tr("panel.low_stock_notification"), product.name, available, threshold)
                )
            end
        end
    end
    previousLowStockProducts = currentLow
end

local function publishState()
    local statuses = {}
    local lowStockCount = 0
    local threshold = noctalia.getConfig("low_stock_threshold") or 3
    local categoryTotals = {}
    local allCategoriesSet = {}
    
    for _, product in ipairs(products) do
        local cat = product.category or "Geral"
        allCategoriesSet[cat] = true
        
        local available = product.available_quantity or 0
        local total = getTotal(product)
        
        if total > 0 then
            categoryTotals[cat] = (categoryTotals[cat] or 0) + total
        end
        
        if available <= threshold and available > 0 then
            lowStockCount = lowStockCount + 1
        end
        
        table.insert(statuses, {
            id = product.id,
            name = product.name,
            category = cat,
            available_quantity = available,
            in_use_quantity = product.in_use_quantity or 0,
            defective_quantity = product.defective_quantity or 0,
            total_quantity = total
        })
    end
    
    local categoryList = {}
    for cat, total in pairs(categoryTotals) do
        if total > 0 then
            table.insert(categoryList, { name = cat, total = total })
        end
    end
    table.sort(categoryList, function(a, b) return a.name < b.name end)
    
    local allCategories = {}
    for cat, _ in pairs(allCategoriesSet) do table.insert(allCategories, cat) end
    table.sort(allCategories)
    
    noctalia.state.set("inventory.products", statuses)
    noctalia.state.set("inventory.total", #products)
    noctalia.state.set("inventory.low_stock_count", lowStockCount)
    noctalia.state.set("inventory.category_totals", categoryList)
    noctalia.state.set("inventory.all_categories", allCategories)
    
    checkLowStockAlerts()
end

noctalia.state.watch("inventory.cmd", function(cmd)
    if type(cmd) ~= "table" then return end
    local op = cmd.op or "unknown"
    
    if op == "add" then
        local name = trim(cmd.name or "")
        local category = trim(cmd.category or "Geral")
        local available = tonumber(cmd.available_quantity) or tonumber(cmd.quantity) or 0
        local inUse = tonumber(cmd.in_use_quantity) or 0
        local defective = tonumber(cmd.defective_quantity) or tonumber(cmd.damage_quantity) or 0
        available = math.max(available + (tonumber(cmd.reserved_quantity) or 0), 0)
        inUse = math.max(inUse, 0)
        defective = math.max(defective, 0)
        
        if name ~= "" then
            table.insert(products, {
                id = generateId(), name = name, category = category,
                available_quantity = available, in_use_quantity = inUse, defective_quantity = defective
            })
            saveState() publishState()
            noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.added") .. ": " .. name)
        end
    
    elseif op == "update" then
        local id = cmd.id
        local name = trim(cmd.name or "")
        local category = trim(cmd.category or "Geral")
        local available = math.max(tonumber(cmd.quantity) or 0, 0)
        if name == "" then return end
        
        for _, product in ipairs(products) do
            if product.id == id then
                product.name = name product.category = category product.available_quantity = available
                saveState() publishState()
                noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.updated") .. ": " .. name)
                break
            end
        end
    
    elseif op == "adjust" then
        local id = cmd.id
        local delta = tonumber(cmd.delta) or 0
        local bucketType = cmd.type or "available"
        
        for _, product in ipairs(products) do
            if product.id == id then
                local avail = product.available_quantity or 0
                local inUse = product.in_use_quantity or 0
                local def = product.defective_quantity or 0

                if bucketType == "available" then
                    if avail + delta < 0 then noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.error_negative")) return end
                    product.available_quantity = avail + delta
                elseif bucketType == "in_use" then
                    if delta > 0 then
                        if avail < delta then noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.error_negative")) return end
                        product.available_quantity = avail - delta
                        product.in_use_quantity = inUse + delta
                    elseif delta < 0 then
                        local absDelta = math.abs(delta)
                        if inUse < absDelta then noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.error_negative")) return end
                        product.in_use_quantity = inUse - absDelta
                        product.available_quantity = avail + absDelta
                    end
                elseif bucketType == "defective" then
                    if delta > 0 then
                        if avail < delta then noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.error_negative")) return end
                        product.available_quantity = avail - delta
                        product.defective_quantity = def + delta
                    elseif delta < 0 then
                        local absDelta = math.abs(delta)
                        if def < absDelta then noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.error_negative")) return end
                        product.defective_quantity = def - absDelta
                        product.available_quantity = avail + absDelta
                    end
                end
                saveState() publishState()
                break
            end
        end

    elseif op == "move" then
        local id = cmd.id
        local direction = cmd.direction
        for i, product in ipairs(products) do
            if product.id == id then
                if direction == "up" and i > 1 then
                    products[i], products[i - 1] = products[i - 1], products[i]
                elseif direction == "down" and i < #products then
                    products[i], products[i + 1] = products[i + 1], products[i]
                end
                saveState() publishState()
                break
            end
        end

    elseif op == "reorder" then
        -- The client identifies the drop target by a neighboring product's
        -- id ("before"/"after" + anchor_id) instead of a raw position, so
        -- this works correctly even when the panel is showing a filtered
        -- (single-category) view: ids map onto a unique, unambiguous index
        -- in this full unfiltered list, whereas a plain position number
        -- would only have been valid for the filtered view it was read from.
        local id = cmd.id
        local anchorKind = cmd.anchor_kind
        local anchorId = cmd.anchor_id
        
        if id and anchorKind and anchorId then
            local fromIdx = nil
            for i, p in ipairs(products) do
                if p.id == id then fromIdx = i break end
            end
            
            if fromIdx then
                local item = table.remove(products, fromIdx)
                local insertAt = #products + 1
                
                local anchorIdx = nil
                for i, p in ipairs(products) do
                    if p.id == anchorId then anchorIdx = i break end
                end
                
                if anchorIdx then
                    if anchorKind == "before" then
                        insertAt = anchorIdx
                    elseif anchorKind == "after" then
                        insertAt = anchorIdx + 1
                    end
                end
                
                insertAt = math.max(1, math.min(insertAt, #products + 1))
                table.insert(products, insertAt, item)
                saveState()
                publishState()
            end
        end
    
    elseif op == "delete" then
        for i, product in ipairs(products) do
            if product.id == cmd.id then
                table.remove(products, i)
                saveState() publishState()
                break
            end
        end
    
    elseif op == "refresh" then
        publishState()
    end
    
    noctalia.state.set("inventory.cmd", nil)
end)

loadState()
publishState()
noctalia.setUpdateInterval(60000)

function update() publishState() end
function onConfigChanged() publishState() end

function onIpc(event, payload)
    if event == "refresh" then publishState()
    elseif event == "add" and payload then
        local data = noctalia.json.decode(payload)
        if data then
            local name = trim(data.name or "")
            if name ~= "" then
                table.insert(products, {
                    id = generateId(), name = name, category = trim(data.category or "Geral"),
                    available_quantity = tonumber(data.quantity) or 0, in_use_quantity = 0, defective_quantity = 0
                })
                saveState() publishState()
                noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.added") .. ": " .. name)
            end
        end
    end
end

function onExit() saveState() end