--!nonstrict
-- kuma-status — the status pages added in the panel: one URL per line in
-- <pluginDataDir>/status_pages.txt.
local S = {}

local function path()
    local dir = noctalia.pluginDataDir()
    return dir and (dir .. "/status_pages.txt") or nil
end

function S.load()
    local p = path()
    local text = p and noctalia.readFile(p) or nil
    local out, seen = {}, {}
    for line in (text or ""):gmatch("[^\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not seen[line] then
            seen[line] = true
            out[#out + 1] = line
        end
    end
    return out
end

function S.save(list)
    local p = path()
    if p == nil then return false end
    local body = #list > 0 and (table.concat(list, "\n") .. "\n") or ""
    return (noctalia.writeFile(p, body))
end

return S
