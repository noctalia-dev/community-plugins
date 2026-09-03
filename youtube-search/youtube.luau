--!nonstrict

local MAX_RESULTS = 5

local activeQuery = ""
local requestSequence = 0
local pendingThumbnails = {}
local updateResults

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function formatDuration(seconds)
    if type(seconds) ~= "number" or seconds < 0 then
        return nil
    end
    local wholeSeconds = math.floor(seconds)
    local hours = math.floor(wholeSeconds / 3600)
    local minutes = math.floor((wholeSeconds % 3600) / 60)
    local remainingSeconds = wholeSeconds % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, remainingSeconds)
    end
    return string.format("%d:%02d", minutes, remainingSeconds)
end

local function thumbnailPath(videoId)
    local pluginDir = noctalia.pluginDir()
    if pluginDir == nil then
        return nil, nil
    end
    return pluginDir .. "/cache/youtube/" .. videoId .. ".jpg", pluginDir .. "/cache/youtube"
end

local function subtitleFor(video)
    local channel = type(video.channel) == "string" and trim(video.channel) or ""
    if channel == "" and type(video.uploader) == "string" then
        channel = trim(video.uploader)
    end
    local duration = formatDuration(video.duration)
    if channel ~= "" and duration ~= nil then
        return channel .. " · " .. duration
    end
    return channel ~= "" and channel or duration
end

local function thumbnailFor(videoId, query, videos)
    local path, directory = thumbnailPath(videoId)
    if path == nil or directory == nil then
        return nil
    end
    if noctalia.fileExists(path) then
        return path
    end
    if pendingThumbnails[videoId] then
        return nil
    end

    local created = noctalia.mkdirAll(directory)
    if not created then
        return nil
    end
    pendingThumbnails[videoId] = true
    noctalia.download("https://i.ytimg.com/vi/" .. videoId .. "/hqdefault.jpg", path, function(ok)
        pendingThumbnails[videoId] = nil
        if ok and activeQuery == query then
            updateResults(query, videos)
        end
    end)
    return nil
end

local function errorRow(title, subtitle)
    return {
        id = "status",
        title = title,
        subtitle = subtitle,
        glyph = "brand-youtube",
    }
end

updateResults = function(query, videos)
    local rows = {}
    if #videos == 0 then
        launcher.setResults(query, { errorRow("No YouTube results", "Try a different search.") })
        return
    end

    for _, video in ipairs(videos) do
        local icon = thumbnailFor(video.id, query, videos)
        table.insert(rows, {
            id = "video:" .. video.id,
            title = video.title,
            subtitle = subtitleFor(video),
            glyph = icon and nil or "brand-youtube",
            icon = icon,
        })
    end
    launcher.setResults(query, rows)
end

function onQuery(query)
    local text = trim(query)
    activeQuery = query
    requestSequence += 1
    local sequence = requestSequence

    if text == "" then
        launcher.setResults(query, {})
        return
    end
    if not noctalia.commandExists("yt-dlp") then
        launcher.setResults(query, { errorRow("yt-dlp is not installed", "Install yt-dlp to search YouTube.") })
        return
    end

    launcher.setResults(query, { errorRow("Searching YouTube…", text) })
    local command = "yt-dlp --ignore-config --no-warnings --flat-playlist --dump-single-json "
        .. shellQuote("ytsearch" .. MAX_RESULTS .. ":" .. text)
    local started = noctalia.runAsync(command, function(result)
        if sequence ~= requestSequence or activeQuery ~= query then
            return
        end
        if result.exitCode ~= 0 or result.timedOut then
            launcher.setResults(query, { errorRow("YouTube search failed", "yt-dlp could not retrieve results.") })
            return
        end

        local payload = noctalia.json.decode(result.stdout or "")
        local source = type(payload) == "table" and payload.entries or nil
        if type(source) ~= "table" then
            launcher.setResults(query, { errorRow("YouTube search failed", "yt-dlp returned an unexpected response.") })
            return
        end

        local videos = {}
        local seen = {}
        for _, video in ipairs(source) do
            local id = type(video.id) == "string" and video.id or nil
            if id ~= nil and id:match("^[A-Za-z0-9_-]+$") and not seen[id] then
                seen[id] = true
                table.insert(videos, {
                    id = id,
                    title = type(video.title) == "string" and video.title or "Untitled video",
                    channel = video.channel,
                    uploader = video.uploader,
                    duration = video.duration,
                })
            end
        end
        updateResults(query, videos)
    end, 15000)
    if not started then
        launcher.setResults(query, { errorRow("YouTube search failed", "Could not start yt-dlp.") })
    end
end

function onActivate(id)
    local videoId = id:match("^video:([A-Za-z0-9_-]+)$")
    if videoId == nil then
        return
    end
    noctalia.runAsync("xdg-open " .. shellQuote("https://www.youtube.com/watch?v=" .. videoId .. "&autoplay=1") .. " >/dev/null 2>&1")
end
