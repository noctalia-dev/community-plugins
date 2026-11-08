--!nonstrict
local M = {}
local function clean(value)
    return type(value) == "string" and value:gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
end
local function validId(id, channel)
    return type(id) == "string" and #id == (channel and 24 or 11)
        and (not channel or id:sub(1, 2) == "UC") and id:match("^[A-Za-z0-9_-]+$") ~= nil
end
local function duration(seconds)
    if type(seconds) ~= "number" or seconds < 0 then return nil end
    seconds = math.floor(seconds)
    if seconds >= 3600 then
        return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
    end
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end
local function validPresentation(item)
    for _, key in ipairs({"titleKind", "subtitleKind", "author", "durationText"}) do
        if item[key] ~= nil and type(item[key]) ~= "string" then return false end
    end
    return item.isLive == nil or type(item.isLive) == "boolean"
end
local function validRecords(records, channel)
    if type(records) ~= "table" then return false end
    local seen, count = {}, 0
    for index, item in pairs(records) do
        if type(index) ~= "number" or index < 1 or index > #records or index % 1 ~= 0 or type(item) ~= "table"
            or not validId(item.id, channel) or type(item.title) ~= "string"
            or (item.channelId ~= nil and not validId(item.channelId, true))
            or type(item.subtitle) ~= "string" or not validPresentation(item) or seen[item.id] then return false end
        seen[item.id], count = true, count + 1
    end
    return count == #records
end
local function contains(records, id)
    for _, item in ipairs(records) do if item.id == id then return true end end
    return false
end
local function without(records, id)
    local result = {}
    for _, item in ipairs(records) do if item.id ~= id then table.insert(result, item) end end
    return result
end
local presentationFields = {"titleKind", "subtitleKind", "author", "durationText", "isLive"}
local function record(item)
    local result = {id = item.id, title = item.title, subtitle = item.subtitle, channelId = item.channelId}
    for _, key in ipairs(presentationFields) do result[key] = item[key] end
    return result
end

local function displayTitle(item)
    if item.titleKind == "untitled" or (not item.titleKind and item.title == "Untitled video") then
        return noctalia.tr("metadata.untitled_video")
    end
    return item.title
end
local function displaySubtitle(item)
    local kind, subtitle = item.subtitleKind, item.subtitle or ""
    if kind == "original" then return subtitle end
    if kind == "video" then
        local parts = {noctalia.tr("metadata.video")}
        if item.author and item.author ~= "" then table.insert(parts, item.author) end
        if item.durationText and item.durationText ~= "" then table.insert(parts, item.durationText) end
        if item.isLive then table.insert(parts, noctalia.tr("metadata.live")) end
        return table.concat(parts, " · ")
    end
    -- Legacy English markers remain readable; real titles and author names stay intact.
    if kind == "url" or subtitle == "Added from URL" then return noctalia.tr("metadata.added_from_url") end
    if kind == "channel-browse" or subtitle == "Channel · Browse videos" then return noctalia.tr("metadata.channel_browse") end
    if kind == "channel" or subtitle == "Channel" then return noctalia.tr("metadata.channel") end
    if subtitle == "Video" then return noctalia.tr("metadata.video") end
    if subtitle:sub(1, #"Video · ") == "Video · " then
        return noctalia.tr("metadata.video") .. subtitle:sub(#"Video" + 1)
    end
    return subtitle
end

local function enrich(item, sources)
    local result = record(item)
    local function genericTitle(title, kind)
        return kind == "untitled" or (kind ~= "original" and
            (title == "" or title == result.id or title == "YouTube · " .. result.id or title == "Untitled video"))
    end
    local function genericSubtitle(subtitle)
        return subtitle == "" or subtitle == "Video" or subtitle == "Added from URL"
    end
    for _, records in ipairs(sources) do
        for _, known in ipairs(records) do
            if known.id == result.id then
                if genericTitle(result.title, result.titleKind) and not genericTitle(known.title, known.titleKind) then
                    result.title, result.titleKind = known.title, known.titleKind
                end
                if genericSubtitle(result.subtitle) and not genericSubtitle(known.subtitle) then
                    result.subtitle = known.subtitle
                    for _, key in ipairs({"subtitleKind", "author", "durationText", "isLive"}) do result[key] = known[key] end
                end
                result.channelId = result.channelId or known.channelId
            end
        end
    end
    return result
end
M.displayTitle, M.displaySubtitle = displayTitle, displaySubtitle
M.enrich = enrich
M.clean = clean
M.validId = validId
M.duration = duration
M.validRecords = validRecords
M.contains = contains
M.without = without
M.record = record
return M
