--!nonstrict
local browser = require("./lib/browser.luau").new()
local mode, input, activeQuery, urlItem = "menu", "", "", nil

local function handleQuery(query)
    browser.collectQueueEvents()
    local text = query:match("^%s*(.-)%s*$")
    input, activeQuery, urlItem = "", query, nil
    if text == "" then
        mode = "menu"
        browser.cancel()
        launcher.setResults(query, {
            {id = "search", title = noctalia.tr("menu.search"), subtitle = noctalia.tr("menu.search_hint"), glyph = "search", query = "Search "},
            {id = "url", title = noctalia.tr("menu.url"), subtitle = noctalia.tr("menu.url_hint"), glyph = "player-play", query = "URL "},
            {id = "later", title = noctalia.tr("menu.later"), subtitle = noctalia.tr("menu.later_hint"), glyph = "bookmark", query = browser.libraryQuery("later")},
            {id = "history", title = noctalia.tr("menu.history"), subtitle = noctalia.tr("menu.history_hint"),
                glyph = "history", query = browser.libraryQuery("history")},
            {id = "favorites", title = noctalia.tr("menu.favorites"), subtitle = noctalia.tr("menu.favorites_hint"),
                glyph = "star", query = browser.libraryQuery("favorites")},
            {id = "queue", title = browser.queueMenuTitle(), glyph = "list", query = browser.libraryQuery("queue")},
            {id = "cache", title = noctalia.tr("cache.clear"), glyph = "trash", query = browser.cacheQuery()},
        })
    elseif text == "URL" or text:match("^URL%s+") then
        mode = "url"
        browser.cancel()
        input = text:match("^URL%s+(.+)$") or ""
        urlItem = browser.urlItem(input)
        local rows = {
            {
                id = urlItem and "play" or "hint",
                query = input == "" and "URL " or nil,
                title = input == "" and noctalia.tr("url.paste") or not urlItem and noctalia.tr("url.invalid")
                    or browser.playTitle(urlItem, input),
                subtitle = input ~= "" and input or nil,
                glyph = "player-play",
            },
        }
        if urlItem then
            table.insert(rows, {id = "queue-toggle", title = browser.queueTitle(urlItem), glyph = "list"})
            table.insert(rows, {id = "toggle", title = browser.isLater(urlItem)
                and noctalia.tr("action.remove_later") or noctalia.tr("action.add_later"), glyph = "bookmark"})
        end
        table.insert(rows, {id = "home", title = "YouTube", glyph = "arrow-left", query = ""})
        launcher.setResults(query, rows)
    else
        mode = "search"
        browser.query(query)
    end
end

function onQuery(query)
    handleQuery(query)
end

function onActivate(id)
    browser.collectQueueEvents()
    if mode == "search" then
        browser.activate(id)
    elseif mode == "url" and id == "play" and urlItem then
        -- Keep pasted URLs out of shell parsing, including quotes and separators.
        browser.play(urlItem, input)
    elseif mode == "url" and id == "hint" then
        launcher.setQuery(activeQuery)
    elseif mode == "url" and id == "toggle" and urlItem then
        browser.toggleLater(urlItem)
        launcher.setQuery(activeQuery)
        handleQuery(activeQuery)
    elseif mode == "url" and id == "queue-toggle" and urlItem then
        browser.toggleQueue(urlItem)
        launcher.setQuery(activeQuery)
        handleQuery(activeQuery)
    end
end

browser.home = function()
    launcher.setQuery("")
    handleQuery("")
end
browser.queueChanged = function()
    if mode == "search" then browser.refreshLocalState() else handleQuery(activeQuery) end
end

function onExit()
    browser.cancel()
    require("./lib/scheduler.luau").clear()
end

noctalia.state.watch("queue_revision", browser.queueChanged)
