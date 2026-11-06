--!nonstrict
local records = require("./records.luau")
local Routes = require("./routes.luau")
local Library = require("./library.luau")
local Playback = require("./playback.luau")
local Search = require("./search.luau")
local Thumbnails = require("./thumbnails.luau")

local Module = {}
function Module.new()
    local M = {}
    local clean, validId = records.clean, records.validId
    local itemSubtitle = records.displaySubtitle
    local contains, without, record = records.contains, records.without, records.record
    local dataDir = noctalia.pluginDataDir()
    local LIST_PAGE_SIZE, PAGE_TTL_MS = 25, 60000
    local FAVORITE_VIDEO_COUNT = noctalia.getConfig("favorite_video_count")
    local libraryStore = Library.new(dataDir)
    local playback = Playback.new(dataDir, function() if M.queueChanged then M.queueChanged() end end)
    local api = Search.new()
    local render, renderLocal
    local currentPage
    local thumbnails = Thumbnails.new(dataDir, function() return currentPage end, function()
        if currentPage.kind == "favorites" or currentPage.kind == "later"
            or currentPage.kind == "history" or currentPage.kind == "queue" then
            renderLocal(currentPage)
        elseif currentPage.items then render() end
    end)
    local generation, currentQuery = 0, ""
    local routes, allowed = Routes.restore(), {}
    local channelSearchInputs = {}
    local trimCaches = function() end
    local routeSerial = 0
    for label, page in pairs(routes) do
        if page.kind == "channel-search-input" then channelSearchInputs[label] = page end
    end
    local function publish(query, rows)
        trimCaches(rows)
        Routes.save(currentPage, rows, routes, query)
        launcher.setResults(query, rows)
    end
    local function copyUrl(url)
        if noctalia.copyToClipboard(url, "text/plain") then
            noctalia.notify(noctalia.tr("notice.url_copied"))
        else
            noctalia.notifyError(noctalia.tr("error.copy_url"))
        end
    end
    local function copyUrlAction()
        return {id = "copy-url", title = noctalia.tr("action.copy_url"), glyph = "copy"}
    end
    local function displayTitle(item)
        local saved = item.destination and contains(libraryStore.data.favorites, item.destination.id)
            or contains(libraryStore.data.later, item.id)
        return saved and ("☆ " .. records.displayTitle(item)) or records.displayTitle(item)
    end
    local function enrichRecord(item)
        return records.enrich(item, {libraryStore.data.history, libraryStore.data.later, playback.items})
    end
    local function play(item, url) playback.play(item and enrichRecord(item) or nil, url) end
    local function toggleQueue(item) playback.run("toggle", nil, nil, enrichRecord(item)) end
    local function toggleLater(item)
        local later = without(libraryStore.data.later, item.id)
        if not contains(libraryStore.data.later, item.id) then table.insert(later, 1, enrichRecord(item)) end
        return libraryStore.save(later, libraryStore.data.history)
    end
    local function sameDestination(a, b)
        return a.kind == b.kind and a.id == b.id and a.number == b.number and a.text == b.text
            and (a.kind ~= "video" or a.item.id == b.item.id)
    end
    local function route(page)
        routeSerial = routeSerial + 1
        page.usedAt = routeSerial
        if not page.label then
            local subst = {page = page.number, name = page.name, term = page.text}
            local label = page.kind == "video" and noctalia.tr("route.video", {title = records.displayTitle(page.item), id = page.item.id})
                or page.kind == "later" and noctalia.tr("route.later", subst)
                or page.kind == "history" and noctalia.tr("route.history", subst)
                or page.kind == "favorites" and noctalia.tr("route.favorites", subst)
                or page.kind == "feed" and noctalia.tr("route.feed", subst)
                or page.kind == "clear-favorites" and noctalia.tr("route.clear_favorites")
                or page.kind == "clear-later" and noctalia.tr("route.clear_later")
                or page.kind == "clear" and noctalia.tr("route.clear_history")
                or page.kind == "clear-cache" and noctalia.tr("route.clear_cache")
                or page.kind == "queue" and noctalia.tr("route.queue", subst)
                or page.kind == "clear-queue" and noctalia.tr("route.clear_queue")
                or page.kind == "reset-queue" and noctalia.tr("route.reset_queue")
                or page.kind == "reset-library" and noctalia.tr("route.reset_library")
                or page.kind == "channel-search-input" and noctalia.tr("route.channel_input", subst)
                or page.kind == "channel-search" and noctalia.tr("route.channel_search", subst)
                or page.kind == "channel" and noctalia.tr("route.channel", subst)
                or (page.number == 1 and page.text or noctalia.tr("route.search", subst))
            -- Repeated visits share a label; different channels with the same
            -- display name remain distinguishable by their actual channel ID.
            if routes[label] and not sameDestination(routes[label], page) and page.id then
                label = label .. " · " .. page.id
            end
            local base, suffix = label, 1
            while routes[label] and not sameDestination(routes[label], page) do
                suffix = suffix + 1
                label = base .. " (" .. suffix .. ")"
            end
            page.label = label
        end
        -- Bind the visible route to this visit so Back uses its current origin.
        routes[page.label] = page
        -- Noctalia prepends the provider prefix to result.query itself.
        return "Search " .. page.label
    end
    local function navigation(title, page, glyph)
        return {id = "navigation:" .. title, title = title, glyph = glyph or "arrow-left", query = route(page)}
    end
    local function videoRoute(item, page)
        page.details = page.details or {}
        local detail = page.details[item.id] or {kind = "video", origin = page}
        detail.item, page.details[item.id] = item, detail
        return route(detail)
    end
    local function favoriteAction(page)
        return {id = "toggle-channel", title = contains(libraryStore.data.favorites, page.id)
            and noctalia.tr("action.remove_favorite") or noctalia.tr("action.add_favorite"), glyph = "star"}
    end
    local function channelSearchAction(page)
        page.searchInput = page.searchInput or {kind = "channel-search-input", id = page.id,
            name = page.name, origin = page, searches = {}}
        local query = route(page.searchInput)
        channelSearchInputs[page.searchInput.label] = page.searchInput
        return {id = "search-channel", title = noctalia.tr("action.search_channel"), subtitle = page.name,
            glyph = "search", query = query .. " "}
    end
    render = function()
        local page = currentPage
        if not page then return end
        local rows = {}
        allowed = {}
        if page.kind == "channel" then
            table.insert(rows, favoriteAction(page))
            table.insert(rows, copyUrlAction())
            table.insert(rows, channelSearchAction(page))
        end
        if page.groups then
            page.items = {}
            for _, group in ipairs(page.groups) do
                table.insert(page.items, {key = "channel-" .. group.channel.id, title = group.channel.title, titleKind = "original",
                    subtitle = "Channel", subtitleKind = "channel", glyph = "user-circle", destination = group.destination,
                    image = api.channelImage(group.channel.image)})
                if group.error or not group.items or #group.items == 0 then
                    table.insert(page.items, {key = "feed-status-" .. group.channel.id,
                        title = group.channel.title .. " · " .. (group.error or (group.items and noctalia.tr("status.no_videos") or noctalia.tr("status.loading"))),
                        subtitle = "", glyph = group.error and "alert-circle" or "loader", status = true})
                end
                for _, item in ipairs(group.items or {}) do table.insert(page.items, item) end
            end
        end
        if page.error then
            table.insert(rows, {id = "status", title = page.error, glyph = "alert-circle"})
        elseif not page.items or #page.items == 0 then
            table.insert(rows, {id = "status", title = page.kind == "feed"
                and noctalia.tr("status.no_favorites") or noctalia.tr("status.no_results"),
                glyph = page.kind == "feed" and "star" or "search"})
        end
        for _, item in ipairs(page.items or {}) do
            local path = thumbnails.path(item.key)
            local icon = path and noctalia.fileExists(path) and path or nil
            local progress = playback.progress(item.id)
            local row = {id = item.key, title = progress and (progress .. " · " .. displayTitle(item)) or displayTitle(item),
                subtitle = itemSubtitle(item),
                icon = icon, glyph = not icon and item.glyph or nil}
            if item.destination then row.query = route(item.destination)
            elseif not item.status then row.query = videoRoute(item, page) end
            table.insert(rows, row)
        end
        if page.next then table.insert(rows, navigation(noctalia.tr("nav.next"), page.next, "arrow-right")) end
        if page.previous then table.insert(rows, navigation(noctalia.tr("nav.previous"), page.previous)) end
        if page.origin then
            table.insert(rows, navigation(page.origin.kind == "favorites" and noctalia.tr("nav.back_favorites")
                or page.origin.kind == "feed" and noctalia.tr("nav.back_feed")
                or page.origin.kind == "channel" and noctalia.tr("nav.back_channel") or noctalia.tr("nav.back_search"), page.origin))
        end
        table.insert(rows, {id = "refresh", title = page.error and noctalia.tr("nav.retry") or noctalia.tr("nav.refresh"), glyph = "refresh"})
        table.insert(rows, {id = "home", title = "YouTube", glyph = "arrow-left", query = ""})
        publish(currentQuery, rows)
    end
    local laterPage, historyPage = {kind = "later", number = 1}, {kind = "history", number = 1}
    local listPages = {later = {laterPage}, history = {historyPage}, favorites = {{kind = "favorites", number = 1}},
        feed = {{kind = "feed", number = 1}}, queue = {{kind = "queue", number = 1}}}
    local clearFavoritesPage = {kind = "clear-favorites", origin = listPages.favorites[1]}
    local clearLaterPage = {kind = "clear-later", origin = laterPage}
    local clearPage = {kind = "clear", origin = historyPage}
    local clearCachePage = {kind = "clear-cache"}
    local clearQueuePage = {kind = "clear-queue", origin = listPages.queue[1]}
    local resetQueuePage = {kind = "reset-queue", origin = listPages.queue[1]}
    local resetLibraryPage = {kind = "reset-library"}
    function M.cacheQuery() return route(clearCachePage) end
    local function listPage(kind, number)
        local pages = listPages[kind]
        pages[number] = pages[number] or {kind = kind, number = number}
        return pages[number]
    end
    function M.libraryQuery(kind)
        return route(listPages[kind][1])
    end
    if next(routes) == nil then
        for _, kind in ipairs({"later", "history", "favorites", "queue", "feed"}) do route(listPages[kind][1]) end
        for _, page in ipairs({clearPage, clearCachePage, clearLaterPage, clearFavoritesPage, clearQueuePage, resetQueuePage}) do
            route(page)
        end
    end
    local avatarBusy, avatarAttempts = nil, {}
    local function resolveFavoriteImage(items)
        if avatarBusy == generation then return end
        for _, item in ipairs(items) do
            if not item.image and not noctalia.fileExists(thumbnails.path(item.key) or "")
                and avatarAttempts[item.id] ~= generation then
                local requestedGeneration = generation
                avatarBusy, avatarAttempts[item.id] = requestedGeneration, requestedGeneration
                api.channelInfo(item.id, function(result)
                    if avatarBusy == requestedGeneration then avatarBusy = nil end
                    if result.image and not libraryStore.error then
                        local favorites = {}
                        for _, known in ipairs(libraryStore.data.favorites) do
                            table.insert(favorites, {id = known.id, title = known.title, subtitle = known.subtitle,
                                image = known.id == item.id and result.image or known.image})
                        end
                        libraryStore.save(libraryStore.data.later, libraryStore.data.history, favorites)
                    end
                    if currentPage and currentPage.kind == "favorites" then renderLocal(currentPage) end
                end)
                return
            end
        end
    end
    renderLocal = function(page)
        local rows = {}
        local localImages = {}
        allowed = {}
        if playback.error and (page.kind == "queue" or page.kind == "clear-queue") then
            table.insert(rows, {id = "status", title = playback.error, glyph = "alert-circle"})
            table.insert(rows, {id = "recover-queue", title = playback.text("reset"), glyph = "refresh",
                query = route(resetQueuePage)})
        elseif libraryStore.error and page.kind ~= "video" and page.kind ~= "clear-cache"
            and page.kind ~= "queue" and page.kind ~= "clear-queue" and page.kind ~= "reset-queue"
            and page.kind ~= "reset-library" then
            table.insert(rows, {id = "status", title = libraryStore.error, glyph = "alert-circle"})
            resetLibraryPage.origin = page
            table.insert(rows, {id = "recover-library", title = noctalia.tr("library.reset"), glyph = "refresh",
                query = route(resetLibraryPage)})
        elseif page.kind == "video" then
            allowed.play, allowed.toggle = page.item, page.item
            allowed["copy-url"] = page.item
            allowed["queue-toggle"] = page.item
            rows = {
                {id = "play", title = contains(playback.items, page.item.id) and playback.text("play_from_here")
                    or noctalia.tr("action.play"), subtitle = records.displayTitle(page.item), glyph = "player-play"},
                {id = "copy-url", title = noctalia.tr("action.copy_url"), glyph = "copy"},
                {id = "queue-toggle", title = playback.text(contains(playback.items, page.item.id) and "remove" or "add"),
                    glyph = "list"},
                {id = "toggle", title = contains(libraryStore.data.later, page.item.id)
                    and noctalia.tr("action.remove_later") or noctalia.tr("action.add_later"), glyph = "bookmark"},
            }
            if contains(libraryStore.data.history, page.item.id) then
                allowed["remove-history"] = page.item
                table.insert(rows, {id = "remove-history", title = noctalia.tr("action.remove_history"), glyph = "trash"})
            end
        elseif page.kind == "reset-library" then
            rows = {{id = "reset-library", title = noctalia.tr("library.reset_confirm"),
                subtitle = noctalia.tr("library.reset_description"), glyph = "refresh"}}
        elseif page.kind == "reset-queue" then
            rows = {{id = "reset-queue", title = playback.text("reset_confirm"),
                subtitle = playback.text("reset_description"), glyph = "refresh"}}
        elseif page.kind == "clear-queue" then
            rows = {{id = "clear-queue", title = playback.text("clear_confirm"),
                subtitle = playback.text("clear_description"), glyph = "trash"}}
        elseif page.kind == "clear-cache" then
            rows = {{id = "clear-cache", title = noctalia.tr("cache.confirm"),
                subtitle = noctalia.tr("cache.confirm_hint"), glyph = "trash"}}
        elseif page.kind == "clear-favorites" then
            rows = {{id = "clear-favorites", title = noctalia.tr("favorites.confirm"),
                subtitle = noctalia.tr("favorites.confirm_hint"), glyph = "trash"}}
        elseif page.kind == "clear-later" then
            rows = {{id = "clear-later", title = noctalia.tr("later.confirm"),
                subtitle = noctalia.tr("later.confirm_hint"), glyph = "trash"}}
        elseif page.kind == "clear" then
            rows = {{id = "clear", title = noctalia.tr("history.confirm"), subtitle = noctalia.tr("history.confirm_hint"),
                glyph = "trash"}}
        else
            local records = page.kind == "history" and libraryStore.data.history
                or page.kind == "favorites" and libraryStore.sortedFavorites()
                or page.kind == "queue" and playback.items or libraryStore.data[page.kind]
            if page.kind == "queue" and #records > 0 then
                clearQueuePage.origin = page
                table.insert(rows, {id = "queue-play", title = playback.text("play"),
                    subtitle = playback.text("play_description"), glyph = "player-play"})
                table.insert(rows, {id = "queue-clear", title = playback.text("clear"),
                    glyph = "trash", query = route(clearQueuePage)})
                if playback.autoplay then
                    table.insert(rows, {id = "queue-refresh", title = playback.text("refresh"),
                        subtitle = playback.text("refresh_description"), glyph = "refresh"})
                end
            end
            if page.kind == "favorites" and #records > 0 then
                table.insert(rows, {id = "feed", title = noctalia.tr("action.feed"), glyph = "player-play",
                    query = route(listPages.feed[1])})
            end
            local lastPage = math.max(1, math.ceil(#records / LIST_PAGE_SIZE))
            if page.number > lastPage then
                currentPage = listPage(page.kind, lastPage)
                currentQuery = route(currentPage)
                launcher.setQuery(currentQuery)
                renderLocal(currentPage); return
            end
            if #records == 0 then
                table.insert(rows, {id = "status", title = page.kind == "later"
                    and noctalia.tr("status.later_empty") or page.kind == "favorites"
                    and noctalia.tr("status.no_favorites") or page.kind == "queue" and playback.text("empty")
                    or noctalia.tr("status.history_empty"), glyph = page.kind == "history" and "history"
                        or page.kind == "queue" and "list" or page.kind == "favorites" and "star" or "bookmark"})
            end
            for index = (page.number - 1) * LIST_PAGE_SIZE + 1, math.min(page.number * LIST_PAGE_SIZE, #records) do
                local item = record(records[index])
                item.image = records[index].image
                if page.kind == "history" then item.progress = playback.progress(item.id) end
                local channel = page.kind == "favorites"
                local key = (channel and "channel-" or "video-") .. item.id
                local path = thumbnails.path(key)
                local icon = path and noctalia.fileExists(path) and path or nil
                local query
                local image
                if channel then image = api.channelImage(item.image)
                else image = "https://i.ytimg.com/vi/" .. item.id .. "/hqdefault.jpg" end
                table.insert(localImages, {key = key, id = item.id, image = image})
                if channel then
                    page.channels = page.channels or {}
                    local destination = page.channels[item.id] or {kind = "channel", id = item.id,
                        name = item.title, number = 1, origin = page, image = api.channelImage(item.image)}
                    page.channels[item.id] = destination
                    query = route(destination)
                else query = videoRoute(item, page) end
                table.insert(rows, {id = key, title = channel and ("☆ " .. item.title)
                    or (page.kind == "queue" and (index .. ". " .. displayTitle(item)))
                    or (item.progress and (item.progress .. " · " .. displayTitle(item)) or displayTitle(item)),
                    subtitle = itemSubtitle(item), icon = icon,
                    glyph = not icon and (channel and "user-circle" or "player-play") or nil, query = query})
            end
            if page.number < lastPage then
                table.insert(rows, navigation(noctalia.tr("nav.next"), listPage(page.kind, page.number + 1), "arrow-right"))
            end
            if page.number > 1 then
                table.insert(rows, navigation(noctalia.tr("nav.previous"), listPage(page.kind, page.number - 1)))
            end
            if page.kind == "favorites" and #records > 0 then
                clearFavoritesPage.origin = page
                table.insert(rows, {id = "confirm-clear-favorites", title = noctalia.tr("action.clear_favorites"),
                    glyph = "trash", query = route(clearFavoritesPage)})
            end
            if page.kind == "later" and #records > 0 then
                clearLaterPage.origin = page
                table.insert(rows, {id = "confirm-clear-later", title = noctalia.tr("action.clear_later"),
                    glyph = "trash", query = route(clearLaterPage)})
            end
            if page.kind == "history" and #records > 0 then
                clearPage.origin = page
                table.insert(rows, {id = "confirm-clear", title = noctalia.tr("action.clear_history"), glyph = "trash",
                    query = route(clearPage)})
            end
        end
        if page.kind == "later" or page.kind == "history" or page.kind == "favorites" or page.kind == "queue" then
            table.insert(rows, {id = "refresh", title = noctalia.tr("nav.refresh"), glyph = "refresh"})
        end
        if page.origin then table.insert(rows, navigation(noctalia.tr("nav.back"), page.origin)) end
        table.insert(rows, {id = "home", title = "YouTube", glyph = "arrow-left", query = ""})
        publish(currentQuery, rows)
        if page.kind == "favorites" or page.kind == "later" or page.kind == "history" or page.kind == "queue" then
            thumbnails.request(localImages)
            if page.kind == "favorites" then resolveFavoriteImage(localImages) end
        end
    end
    function M.collectQueueEvents()
        libraryStore.reload()
        playback.reload()
        if libraryStore.error then return end
        playback.collectEvents(function(item, token)
            return libraryStore.rememberPlayed(enrichRecord(item), token)
        end)
    end
    local feedCache = {}
    trimCaches = function(rows)
        local roots = {clearFavoritesPage, clearLaterPage, clearPage, clearCachePage,
            clearQueuePage, resetQueuePage, resetLibraryPage}
        for _, pages in pairs(listPages) do table.insert(roots, pages[1]) end
        local kept = Routes.trim(routes, currentPage, rows, roots)
        if not kept then return end
        for _, pages in pairs(listPages) do
            for number, page in pairs(pages) do if not kept[page] then pages[number] = nil end end
        end
        for label, page in pairs(channelSearchInputs) do if not kept[page] then channelSearchInputs[label] = nil end end
    end
    local FEED_CHANNELS_PER_PAGE = 8
    local function queryFeed(page, requestGeneration)
        local now = noctalia.nowMs()
        for id, cached in pairs(feedCache) do
            if now < cached.loadedAt or now - cached.loadedAt >= PAGE_TTL_MS then feedCache[id] = nil end
        end
        local cachedIds = {}
        for id in pairs(feedCache) do table.insert(cachedIds, id) end
        table.sort(cachedIds, function(a, b) return feedCache[a].loadedAt > feedCache[b].loadedAt end)
        for index = 57, #cachedIds do feedCache[cachedIds[index]] = nil end
        local favorites = libraryStore.sortedFavorites()
        local lastPage = math.max(1, math.ceil(#favorites / FEED_CHANNELS_PER_PAGE))
        if page.number > lastPage then
            page = listPage("feed", lastPage)
            currentPage = page
            currentQuery = route(page)
            launcher.setQuery(currentQuery)
        end
        page.groups, page.items, page.error = {}, {}, nil
        page.origin = listPages.favorites[1]
        page.previous = page.number > 1 and listPage("feed", page.number - 1) or nil
        page.next = page.number < lastPage and listPage("feed", page.number + 1) or nil
        page.channels = page.channels or {}
        for index = (page.number - 1) * FEED_CHANNELS_PER_PAGE + 1,
            math.min(page.number * FEED_CHANNELS_PER_PAGE, #favorites) do
            local channel = favorites[index]
            local destination = page.channels[channel.id] or {kind = "channel", id = channel.id,
                name = channel.title, number = 1, origin = page}
            page.channels[channel.id] = destination
            local cached = feedCache[channel.id]
            local age = cached and (noctalia.nowMs() - cached.loadedAt)
            table.insert(page.groups, {channel = channel, destination = destination,
                items = age and age >= 0 and age < PAGE_TTL_MS and cached.items or nil})
        end
        render()
        thumbnails.request()
        -- Fetch channels one at a time, reusing cached results during navigation.
        local index = 1
        local fetchNext
        fetchNext = function()
            if generation ~= requestGeneration then return end
            while page.groups[index] and page.groups[index].items do index = index + 1 end
            local group = page.groups[index]
            if not group then return end
            index = index + 1
            api.channelVideos(group.channel.id, FAVORITE_VIDEO_COUNT, function(result)
                if generation ~= requestGeneration then return end
                if result.error then
                    group.error = result.error
                else
                    group.items = {}
                    for _, item in ipairs(result.items) do
                        if item.id then table.insert(group.items, item) end
                        if #group.items == FAVORITE_VIDEO_COUNT then break end
                    end
                    feedCache[group.channel.id] = {items = group.items, loadedAt = noctalia.nowMs()}
                end
                render()
                fetchNext()
                thumbnails.request()
            end)
        end
        fetchNext()
    end
    function M.query(query)
        generation = generation + 1
        api.cancel()
        local requestGeneration = generation
        currentQuery, currentPage, allowed = query, nil, {}
        thumbnails.cancel()
        local text = clean(query)
        if text == "Search" then text = "" else text = text:match("^Search%s+(.+)$") or text end
        if text == "" then
            publish(query, {
                {id = "hint", title = noctalia.tr("status.search_hint"), glyph = "search", query = "Search "},
                {id = "home", title = "YouTube", glyph = "arrow-left", query = ""},
            })
            return
        end
        local page = routes[text]
        if not page and query:match("^%s*Search%s+") then
            local template = noctalia.tr("route.video", {title = "TITLEMARKER", id = "IDMARKER"})
            local pattern = template:gsub("(%W)", "%%%1")
                :gsub("TITLEMARKER", function() return "(.+)" end)
                :gsub("IDMARKER", function() return "([A-Za-z0-9_-]+)" end)
            local title, id = text:match("^" .. pattern .. "$")
            if not id then title, id = text:match("^" .. pattern .. " %(%d+%)$") end
            if template:find("IDMARKER", 1, true) < template:find("TITLEMARKER", 1, true) then title, id = id, title end
            if not id then title, id = text:match("^Video · (.+) · ([A-Za-z0-9_-]+)$") end
            if not id then title, id = text:match("^Video · (.+) · ([A-Za-z0-9_-]+) %(%d+%)$") end
            if validId(id, false) then
                page = {kind = "video", item = enrichRecord({id = id, title = title, subtitle = "YouTube"})}
                local canonical = route(page)
                currentQuery = canonical
                if canonical ~= query then launcher.setQuery(canonical) end
            end
        end
        if not page then
            local matchedLabel, matchedInput
            for label, inputPage in pairs(channelSearchInputs) do
                if text:sub(1, #label + 1) == label .. " " and (not matchedLabel or #label > #matchedLabel) then
                    matchedLabel, matchedInput = label, inputPage
                end
            end
            if matchedInput then
                local term = clean(text:sub(#matchedLabel + 2))
                page = matchedInput.searches[term]
                if not page then
                    page = {kind = "channel-search", id = matchedInput.id, name = matchedInput.name,
                        text = term, number = 1, origin = matchedInput.origin}
                    matchedInput.searches[term] = page
                end
            end
        end
        page = page or {kind = "search", text = text, number = 1}
        route(page)
        currentPage = page
        if page.kind == "channel-search-input" then
            publish(query, {
                {id = "hint", title = noctalia.tr("status.channel_search_hint"), subtitle = page.name,
                    glyph = "search", query = route(page) .. " "},
                navigation(noctalia.tr("nav.back_channel"), page.origin),
                {id = "home", title = "YouTube", glyph = "arrow-left", query = ""},
            })
            return
        end
        if page.kind == "feed" then
            if libraryStore.error then
                renderLocal(page)
                return
            end
            queryFeed(page, requestGeneration); return
        end
        if page.kind == "video" or page.kind == "later" or page.kind == "history"
            or page.kind == "favorites" or page.kind == "clear" or page.kind == "clear-cache" or page.kind == "clear-later" or page.kind == "clear-favorites"
            or page.kind == "queue" or page.kind == "clear-queue" or page.kind == "reset-queue" or page.kind == "reset-library" then
            renderLocal(page); return
        end
        local age = page.loadedAt and (noctalia.nowMs() - page.loadedAt) or nil
        if page.items and not page.error and age and age >= 0 and age < PAGE_TTL_MS then
            render(); thumbnails.request(); return
        end
        page.items, page.next = nil, nil
        local rows = {{id = "status", title = noctalia.tr("status.loading"), subtitle = page.name or page.text, glyph = "loader"}}
        table.insert(rows, {id = "refresh", title = noctalia.tr("nav.refresh"), glyph = "refresh"})
        table.insert(rows, {id = "home", title = "YouTube", glyph = "arrow-left", query = ""})
        if page.kind == "channel" then
            table.insert(rows, 1, channelSearchAction(page))
            table.insert(rows, 1, copyUrlAction())
            table.insert(rows, 1, favoriteAction(page))
        end
        publish(query, rows)
        api.request(page, function(result)
            if generation ~= requestGeneration then return end
            page.error = result.error
            if not page.error then
                page.image = result.image or page.image
                page.items = result.items
                page.loadedAt = noctalia.nowMs()
                if result.hasMore then
                    page.next = {kind = page.kind, id = page.id, name = page.name, text = page.text,
                        number = page.number + 1, previous = page, origin = page.origin}
                end
            end
            render()
            if not page.error then thumbnails.request() end
        end)
    end
    function M.activate(id)
        -- Noctalia decides whether to close when onActivate returns, before
        -- asynchronous callbacks run. Keep list edits and status rows open here.
        if currentPage and id ~= "play" and id ~= "queue-play" and id ~= "copy-url" then
            launcher.setQuery(currentQuery)
        end
        if id == "reset-library" and currentPage and currentPage.kind == "reset-library" and libraryStore.error then
            if libraryStore.reset() then M.home() end
            return
        end
        if id == "reset-queue" and currentPage and currentPage.kind == "reset-queue" and playback.error then
            if not playback.reset() then return end
            playback.run("sync")
            local query = route(listPages.queue[1])
            launcher.setQuery(query)
            M.query(query)
            return
        end
        if id == "queue-play" and currentPage and currentPage.kind == "queue" and #playback.items > 0 and not playback.error then
            playback.run("play")
            return
        end
        if id == "queue-refresh" and currentPage and currentPage.kind == "queue" and playback.autoplay and not playback.error then
            playback.run("refresh")
            return
        end
        if id == "clear-queue" and currentPage and currentPage.kind == "clear-queue" then
            playback.run("clear")
            local query = route(listPages.queue[1])
            launcher.setQuery(query)
            M.query(query)
            return
        end
        if id == "clear-cache" and currentPage and currentPage.kind == "clear-cache" then
            if thumbnails.clear() then M.home() end
            return
        end
        if id == "copy-url" and currentPage and currentPage.kind == "channel" then
            copyUrl("https://www.youtube.com/channel/" .. currentPage.id)
            return
        end
        if id == "toggle-channel" and currentPage and currentPage.kind == "channel" then
            local favorites = without(libraryStore.data.favorites, currentPage.id)
            if not contains(libraryStore.data.favorites, currentPage.id) then
                table.insert(favorites, 1, {id = currentPage.id, title = currentPage.name,
                    subtitle = "Channel · Browse videos", subtitleKind = "channel-browse", image = api.channelImage(currentPage.image)})
            end
            libraryStore.save(libraryStore.data.later, libraryStore.data.history, favorites)
            launcher.setQuery(currentQuery)
            if currentPage.items or currentPage.error then render()
            else
                publish(currentQuery, {favoriteAction(currentPage), copyUrlAction(), channelSearchAction(currentPage),
                    {id = "status", title = noctalia.tr("status.loading"), subtitle = currentPage.name, glyph = "loader"}})
            end
            return
        end
        if currentPage and currentPage.kind == "video" then
            local item = allowed[id]
            if not item then return end
            if id == "play" then play(item, "https://www.youtube.com/watch?v=" .. item.id)
            elseif id == "copy-url" then copyUrl("https://www.youtube.com/watch?v=" .. item.id)
            elseif id == "queue-toggle" then
                toggleQueue(item)
                launcher.setQuery(currentQuery)
                renderLocal(currentPage)
            elseif id == "toggle" then
                toggleLater(item)
                launcher.setQuery(currentQuery)
                renderLocal(currentPage)
            elseif id == "remove-history" then
                local page = currentPage
                playback.clearProgress(item.id, function()
                    libraryStore.reload()
                    if not libraryStore.save(libraryStore.data.later, without(libraryStore.data.history, item.id)) then return end
                    if currentPage == page then
                        launcher.setQuery(currentQuery)
                        renderLocal(currentPage)
                    end
                end)
            end
            return
        elseif currentPage and currentPage.kind == "clear-favorites" and id == "clear-favorites" and not libraryStore.error then
            if not libraryStore.save(libraryStore.data.later, libraryStore.data.history, {}) then return end
            feedCache = {}
            local query = route(listPages.favorites[1])
            launcher.setQuery(query)
            M.query(query)
            return
        elseif currentPage and currentPage.kind == "clear-later" and id == "clear-later" and not libraryStore.error then
            if not libraryStore.save({}, libraryStore.data.history) then return end
            local query = route(laterPage)
            launcher.setQuery(query)
            M.query(query)
            return
        elseif currentPage and currentPage.kind == "clear" and id == "clear" and not libraryStore.error then
            local page = currentPage
            playback.clearProgress(nil, function()
                libraryStore.reload()
                if not libraryStore.save(libraryStore.data.later, {}, nil, {}, {}) then return end
                if currentPage == page then
                    M.home()
                end
            end)
            return
        end
        if id == "refresh" and currentPage then
            M.collectQueueEvents()
            currentPage.loadedAt = nil
            if currentPage.kind == "feed" then feedCache = {} end
            -- The host caches identical queries. Fetch here and use setQuery only to keep the panel open.
            launcher.setQuery(currentQuery)
            M.query(currentQuery)
            return
        end
    end

    function M.urlItem(url)
        local host, path = url:match("^https?://([^/]+)/(.+)$")
        local id
        if host == "youtu.be" then id = path:match("^([^?&#/]+)")
        elseif host == "youtube.com" or host == "www.youtube.com" or host == "m.youtube.com"
            or host == "music.youtube.com" then
            id = path:match("^watch%?v=([^&#]+)") or path:match("^watch%?.-&v=([^&#]+)")
                or path:match("^shorts/([^?&#/]+)") or path:match("^live/([^?&#/]+)")
                or path:match("^embed/([^?&#/]+)")
        end
        if not validId(id, false) then return nil end
        return enrichRecord({id = id, title = "YouTube · " .. id, subtitle = "Added from URL", subtitleKind = "url"})
    end
    M.play, M.toggleLater, M.toggleQueue = play, toggleLater, toggleQueue
    function M.isLater(item) return contains(libraryStore.data.later, item.id) end
    function M.queueTitle(item) return playback.text(contains(playback.items, item.id) and "remove" or "add") end
    function M.queueMenuTitle() return playback.text("title") end
    function M.playTitle(item, url)
        return item and contains(playback.items, item.id) and not playback.startTime(url) and playback.text("play_from_here") or noctalia.tr("action.play")
    end

    function M.refreshLocalState()
        M.collectQueueEvents()
        if not currentPage then return end
        local kind = currentPage.kind
        if kind == "video" or kind == "later" or kind == "history" or kind == "favorites" or kind == "queue" then
            renderLocal(currentPage)
        elseif currentPage.items then render() end
    end
    function M.cancel()
        generation = generation + 1
        api.cancel()
        currentPage, allowed = nil, {}
        thumbnails.cancel()
    end

    return M
end

return Module
