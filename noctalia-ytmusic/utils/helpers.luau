-- Pure string/number helpers shared across modules and api layers.

local Utils = {}

function Utils.sanitize(s)
    s = tostring(s or "")
    return s:gsub("[\r\n]", "")
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

return Utils