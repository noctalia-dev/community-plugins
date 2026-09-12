-- Pure string/number helpers shared across modules and api layers.

local Utils = {}

function Utils.clean_utf8(s)
    if type(s) ~= "string" or s == "" then return tostring(s or "") end
    return s
end

function Utils.sanitize(s)
    s = Utils.clean_utf8(s)
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
    if type(meta) ~= "string" or meta == "" then return "" end
    meta = meta:gsub("%s*•%s*[%d.,]+[KMB]?%s*views.*$", "")
    meta = meta:gsub("%s*•%s*%d+:?%d*$", "")
    local parts = {}
    local sep = " • "
    local start_pos = 1
    while true do
        local sep_start, sep_end = meta:find(sep, start_pos, true)
        if sep_start then
            local part = meta:sub(start_pos, sep_start - 1):gsub("^%s+", ""):gsub("%s+$", "")
            if part ~= "Song" and part ~= "Video" and part ~= "Episode" and part ~= "" then
                table.insert(parts, part)
            end
            start_pos = sep_end + 1
        else
            local part = meta:sub(start_pos):gsub("^%s+", ""):gsub("%s+$", "")
            if part ~= "Song" and part ~= "Video" and part ~= "Episode" and part ~= "" then
                table.insert(parts, part)
            end
            break
        end
    end
    if #parts > 0 then return parts[1] end
    return (meta:gsub("^%s+", ""):gsub("%s+$", ""))
end

return Utils
