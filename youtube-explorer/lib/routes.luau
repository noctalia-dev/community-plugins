--!nonstrict
local records = require("./records.luau")
local M = {}
local KEY, LIMIT = "navigation", 256
local localKinds = {later = true, history = true, favorites = true, queue = true, feed = true}
local confirmations = {["clear"] = true, ["clear-cache"] = true, ["clear-later"] = true,
    ["clear-favorites"] = true, ["clear-queue"] = true, ["reset-queue"] = true, ["reset-library"] = true}

local function validPage(page)
    if type(page) ~= "table" or type(page.kind) ~= "string" then return false end
    if page.kind == "video" then return type(page.item) == "table" and records.validRecords({page.item}) end
    if confirmations[page.kind] then return true end
    if page.kind == "channel-search-input" then
        return records.validId(page.id, true) and type(page.name) == "string"
    end
    if type(page.number) ~= "number" or page.number < 1 or page.number % 1 ~= 0
        or page.number >= math.huge then return false end
    if localKinds[page.kind] then return true end
    if page.kind == "search" then return type(page.text) == "string" end
    if page.kind == "channel" or page.kind == "channel-search" then
        return records.validId(page.id, true) and type(page.name) == "string"
            and (page.kind ~= "channel-search" or type(page.text) == "string")
    end
    return false
end

function M.restore()
    local saved = noctalia.state.get(KEY)
    local routes = {}
    if type(saved) ~= "table" or saved.version ~= 1 or type(saved.pages) ~= "table" then return routes end
    local count = 0
    for label, page in pairs(saved.pages) do
        count = count + 1
        if count > LIMIT then return {} end
        if type(label) == "string" and validPage(page) then
            routes[label] = {label = label, kind = page.kind, number = page.number,
                text = page.text, id = page.id, name = page.name,
                item = page.kind == "video" and records.record(page.item) or nil}
            if page.kind == "channel-search-input" then routes[label].searches = {} end
        end
    end
    for label, page in pairs(routes) do
        local savedPage = saved.pages[label]
        if type(savedPage.origin) == "string" then page.origin = routes[savedPage.origin] end
        if type(savedPage.previous) == "string" then page.previous = routes[savedPage.previous] end
        if page.kind == "channel-search-input" and not page.origin then
            page.origin = {kind = "channel", id = page.id, name = page.name, number = 1}
        end
    end
    if type(saved.query) == "string" and type(saved.label) == "string" and routes[saved.label] then
        routes[saved.query] = routes[saved.label]
    end
    return routes
end

function M.trim(routes, currentPage, rows, roots)
    local count = 0
    for _ in pairs(routes) do count = count + 1 end
    if count <= LIMIT * 2 then return nil end
    local kept, total = {}, 0
    local function mark(page)
        if not page or kept[page] or total >= LIMIT then return end
        kept[page], total = true, total + 1
    end
    mark(currentPage)
    for _, page in ipairs(roots) do mark(page) end
    for _, row in ipairs(rows) do
        local label = type(row.query) == "string" and records.clean(row.query):match("^Search%s+(.+)$")
        if label then mark(routes[label]) end
    end
    local visited = {}
    local function ancestors(page)
        if not page or visited[page] then return end
        visited[page] = true
        mark(page.origin); mark(page.previous)
        if page.origin and kept[page.origin] then ancestors(page.origin) end
        if page.previous and kept[page.previous] then ancestors(page.previous) end
    end
    ancestors(currentPage)
    for _, page in ipairs(roots) do ancestors(page) end
    local recent, seen = {}, {}
    for _, page in pairs(routes) do
        if not seen[page] then table.insert(recent, page); seen[page] = true end
    end
    for _, page in ipairs(roots) do
        if not seen[page] then table.insert(recent, page); seen[page] = true end
    end
    table.sort(recent, function(a, b) return (a.usedAt or 0) > (b.usedAt or 0) end)
    for _, page in ipairs(recent) do mark(page) end
    for _, page in ipairs(recent) do
        -- Remove indirect references too, otherwise evicted pages stay alive through caches.
        for _, key in ipairs({"origin", "previous", "next", "searchInput"}) do
            if page[key] and not kept[page[key]] then
                if key == "next" then page.items, page.loadedAt = nil, nil end
                page[key] = nil
            end
        end
        for _, key in ipairs({"details", "channels", "searches"}) do
            for id, child in pairs(page[key] or {}) do if not kept[child] then page[key][id] = nil end end
        end
        for _, item in ipairs(page.items or {}) do
            if item.destination and not kept[item.destination] then page.items, page.loadedAt = nil, nil; break end
        end
        for _, group in ipairs(page.groups or {}) do
            if not kept[group.destination] then page.groups, page.items, page.loadedAt = nil, nil, nil; break end
        end
    end
    for label, page in pairs(routes) do if not kept[page] then routes[label] = nil end end
    return kept
end

function M.save(currentPage, rows, routes, query)
    -- Keep only the current screen, visible destinations and their return paths.
    -- Results and cyclic page caches stay in the VM; the snapshot is bounded.
    local pages, pending = {}, {}
    local function add(page)
        if not page or type(page.label) ~= "string" or not validPage(page) then return nil end
        local label = page.label
        if pages[label] then return label end
        if #pending >= LIMIT then return nil end
        pages[label] = {kind = page.kind, number = page.number, text = page.text,
            id = page.id, name = page.name, item = page.kind == "video" and records.record(page.item) or nil}
        table.insert(pending, page)
        return label
    end
    -- Reserve visible destinations before older ancestors can fill the snapshot.
    add(currentPage)
    for _, row in ipairs(rows) do
        if type(row.query) == "string" then
            local label = records.clean(row.query):match("^Search%s+(.+)$")
            if label then add(routes[label]) end
        end
    end
    local index = 1
    while index <= #pending do
        local page = pending[index]
        local saved = pages[page.label]
        saved.origin, saved.previous = add(page.origin), add(page.previous)
        index = index + 1
    end
    local label = currentPage and currentPage.label
    noctalia.state.set(KEY, {version = 1, pages = pages,
        query = label and records.clean(query):gsub("^Search%s+", "") or nil, label = label})
end

return M
