-- Pure string/number helpers shared across modules and api layers.

local Utils = {}

function Utils.sanitize(s)
    s = tostring(s or "")
    return s:gsub("[\r\n]", "")
end

function Utils.fmt_duration(secs)
    secs = tonumber(secs) or 0
    local m = math.floor(secs / 60)
    local s = secs % 60
    return string.format("%d:%02d", m, s)
end

function Utils.fmt_seconds(text)
    text = tostring(text or "")
    local h, m, s = text:match("(%d+):(%d%d):(%d%d)")
    if h then
        return (tonumber(h) or 0) * 3600 + (tonumber(m) or 0) * 60 + (tonumber(s) or 0)
    end
    local mm, ss = text:match("(%d+):(%d%d)")
    if mm then
        return (tonumber(mm) or 0) * 60 + (tonumber(ss) or 0)
    end
    return 0
end

function Utils.clean_artist(meta)
    meta = tostring(meta or "")
    meta = meta:gsub("%s*•%s*[%d.,]+[KMB]?%s*views.*$", "")
    meta = meta:gsub("%s*•%s*%d+:?%d*$", "")
    local parts = {}
    for part in (meta .. " • "):gmatch("([^•]+) • ") do
        local p = part:gsub("^%s+", ""):gsub("%s+$", "")
        if p ~= "Song" and p ~= "Video" and p ~= "Episode" and p ~= "" then
            table.insert(parts, p)
        end
    end
    if #parts > 0 then return parts[1] end
    return (meta:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Utils.extract_thumb_url(node)
    if type(node) ~= "table" then return nil end
    local th = node.thumbnail or node.thumbnailRenderer
    if type(th) == "table" then
        local tr = th.musicThumbnailRenderer or th
        local t_list = type(tr) == "table" and (tr.thumbnail and tr.thumbnail.thumbnails or tr.thumbnails) or nil
        if type(t_list) == "table" and #t_list > 0 then
            local last = t_list[#t_list]
            if type(last) == "table" and type(last.url) == "string" and last.url ~= "" then
                return last.url
            end
        end
    end
    return nil
end

return Utils