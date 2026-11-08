--!nonstrict
-- YouTube discovery via yt-dlp.
local records = require("./records.luau")
local scheduler = require("./scheduler.luau")
local Module = {}

function Module.new()
    local M = {}
    local clean, validId, duration = records.clean, records.validId, records.duration
    local language = noctalia.getConfig("search_language")
    local languages = {tr = true, en = true, de = true, fr = true, es = true, ru = true, ar = true, ja = true}
    if not languages[language or ""] then language = "en" end
    local PAGE_SIZE = 20
    local active
    local dataDir, pluginDir = noctalia.pluginDataDir(), noctalia.pluginDir()
    local ticketPath = dataDir and (dataDir .. "/search-ticket")
    function M.cancel()
        if not active then return end
        scheduler.cancel(active.timer)
        scheduler.cancel(active.watchdog)
        if ticketPath and noctalia.readFile(ticketPath) == active.token then noctalia.removeFile(ticketPath) end
        active = nil
    end
    local function imageUrl(url, channel)
        if type(url) ~= "string" or url:find("[%c%s]") then return nil end
        url = url:gsub("^//", "https://")
        local host, path = url:match("^https?://([^/]+)/(.+)$")
        local allowed = channel and (host == "yt3.ggpht.com" or host == "yt3.googleusercontent.com")
            or not channel and (host == "i.ytimg.com" or host == "img.youtube.com")
        if allowed then return "https://" .. host .. "/" .. path end
        return nil
    end
    local function thumbnailUrl(item, channel)
        if type(item.thumbnails) == "table" then
            -- yt-dlp normally orders thumbnails from smaller to larger images.
            for index = #item.thumbnails, 1, -1 do
                local image = item.thumbnails[index]
                local url = type(image) == "table" and (not channel or (image.preference or 0) >= 0)
                    and imageUrl(image.url, channel)
                if url then return url end
            end
        end
        return imageUrl(item.thumbnail, channel)
    end
    local function normalize(source, page)
        local items, seen = {}, {}
        for _, item in ipairs(source) do
            if type(item) == "table" then
                if validId(item.id, true) then
                    local key = "channel-" .. item.id
                    if not seen[key] then
                        seen[key] = true
                        local name = clean(item.channel or item.title)
                        if name == "" then name = item.id end
                        table.insert(items, {
                            key = key, title = name, titleKind = "original",
                            subtitle = "Channel · Browse videos", subtitleKind = "channel-browse", glyph = "user-circle",
                            image = thumbnailUrl(item, true),
                            destination = {kind = "channel", id = item.id, name = name, number = 1, origin = page,
                                image = thumbnailUrl(item, true)},
                        })
                    end
                elseif validId(item.id, false) then
                    local key = "video-" .. item.id
                    if not seen[key] then
                        seen[key] = true
                        local details, title = {"Video"}, clean(item.title)
                        local author, length = clean(item.channel or item.uploader), duration(item.duration)
                        if author ~= "" then table.insert(details, author) end
                        if length then table.insert(details, length) end
                        if item.live_status == "is_live" then table.insert(details, "LIVE") end
                        table.insert(items, {
                            key = key, id = item.id, title = title ~= "" and title or "Untitled video",
                            titleKind = title == "" and "untitled" or "original", subtitleKind = "video",
                            author = author, durationText = length, isLive = item.live_status == "is_live",
                            channelId = validId(item.channel_id, true) and item.channel_id
                                or ((page.kind == "channel" or page.kind == "channel-search") and page.id or nil),
                            subtitle = table.concat(details, " · "), glyph = "player-play",
                            image = thumbnailUrl(item, false) or ("https://i.ytimg.com/vi/" .. item.id .. "/hqdefault.jpg"),
                        })
                    end
                end
            end
        end
        return items
    end
    function M.request(page, callback, limit)
        limit = limit or PAGE_SIZE
        local url
        if page.kind == "channel-search" then
            url = "https://www.youtube.com/channel/" .. page.id .. "/search?query="
                .. noctalia.string.urlEncode(page.text)
        elseif page.kind == "channel" or page.kind == "channel-info" then
            url = "https://www.youtube.com/channel/" .. page.id .. "/videos"
        else
            -- Search URLs retain channel results; ytsearch filters them out.
            url = "https://www.youtube.com/results?search_query=" .. noctalia.string.urlEncode(page.text)
        end
        M.cancel()
        local job = {attempt = 0}
        active = job
        local function complete(result)
            if active ~= job then return end
            M.cancel()
            callback(result)
        end
        local start
        local function failed(message, transient)
            if active ~= job then return end
            scheduler.cancel(job.watchdog)
            if transient and job.attempt < 2 then
                job.timer = scheduler.after(500, function() if active == job then start() end end)
            else complete({error = message}) end
        end
        start = function()
            if active ~= job then return end
            job.attempt = job.attempt + 1
            if not noctalia.commandExists("yt-dlp") then
                complete({error = noctalia.tr("error.ytdlp_missing")}); return
            end
            -- One extra entry tells us whether another page exists, without loading the entire channel.
            local first = (page.number - 1) * limit + 1
            local args = {"yt-dlp", "--ignore-config", "--no-cache-dir", "--no-warnings", "--force-ipv4",
                "--extractor-args", "youtube:lang=" .. language,
                "--flat-playlist", "--dump-single-json", "--socket-timeout", "5",
                "--retries", "0", "--extractor-retries", "0",
                "--playlist-items", first .. ":" .. (first + limit), "--", url}
            if not ticketPath or not pluginDir or not noctalia.commandExists("python3") then
                complete({error = noctalia.tr("error.search_helper")}); return
            end
            local serial = (noctalia.state.get("search_serial") or 0) + 1
            noctalia.state.set("search_serial", serial)
            job.token = tostring(noctalia.nowMs()) .. ":" .. tostring(serial)
            local temporary = ticketPath .. ".part"
            if not noctalia.writeFile(temporary, job.token) or not noctalia.renameFile(temporary, ticketPath) then
                noctalia.removeFile(temporary)
                complete({error = noctalia.tr("error.search_start")}); return
            end
            local attempt = job.attempt
            local command = {"python3", pluginDir .. "/helpers/search-runner.py", ticketPath, job.token}
            for _, value in ipairs(args) do table.insert(command, value) end
            local finished = false
            local function response(result)
                if finished or active ~= job or job.attempt ~= attempt then return end
                finished = true
                scheduler.cancel(job.watchdog)
                if result.timedOut or result.exitCode == 124 then
                    failed(noctalia.tr("error.search_timeout"), true); return
                end
                if result.stdoutTruncated then complete({error = noctalia.tr("error.search_limit")}); return end
                if result.exitCode ~= 0 then
                    local detail = clean(result.stderr):sub(1, 240)
                    local text = clean(result.stderr):lower()
                    local transient = not text:find("certificate_verify_failed", 1, true) and
                        (text:find("timed out", 1, true) or text:find("connection reset", 1, true)
                        or text:find("failed to resolve", 1, true) or text:find("temporary failure", 1, true)
                        or text:find("record_layer_failure", 1, true) or text:find("http error 503", 1, true))
                    failed(noctalia.tr("error.search_failed", {detail = detail}), transient); return
                end
                local ok, data = pcall(noctalia.json.decode, result.stdout or "")
                if page.kind == "channel-info" then
                    if not ok or type(data) ~= "table" or (data.id ~= page.id and data.channel_id ~= page.id) then
                        complete({error = noctalia.tr("error.search_response")}); return
                    end
                    complete({image = thumbnailUrl(data, true)}); return
                end
                local source = ok and type(data) == "table" and data.entries
                if type(source) ~= "table" or (next(source) ~= nil and source[1] == nil) then
                    complete({error = noctalia.tr("error.search_response")}); return
                end
                local hasMore = #source > limit
                source[limit + 1] = nil
                complete({items = normalize(source, page), hasMore = hasMore, image = thumbnailUrl(data, true)})
            end
            job.watchdog = scheduler.after(10000, function() response({timedOut = true}) end)
            if not noctalia.runAsync(command, response, 10000) then
                finished = true
                failed(noctalia.tr("error.search_start"), true)
            end
        end
        start()
    end
    function M.channelVideos(id, count, callback)
        M.request({kind = "channel", id = id, number = 1}, callback, count)
    end
    function M.channelInfo(id, callback)
        M.request({kind = "channel-info", id = id, number = 1}, callback, 0)
    end
    function M.channelImage(url) return imageUrl(url, true) end
    return M
end

return Module
