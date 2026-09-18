local ANSI_CSI_PATTERN = "\27%[[0-9;:<?]*[ -/]*[@-~]"

local function trim(value)
    return value:match("^%s*(.-)%s*$") or ""
end

local function stripAnsi(value)
    return value:gsub(ANSI_CSI_PATTERN, "")
end

local function unquote(value)
    local pairs = {
        { "'", "'" },
        { '"', '"' },
        { "‘", "’" },
        { "“", "”" },
    }

    for _, quotes in ipairs(pairs) do
        local opening, closing = quotes[1], quotes[2]
        if value:sub(1, #opening) == opening and value:sub(-#closing) == closing then
            return value:sub(#opening + 1, -#closing - 1)
        end
    end

    return nil
end

local function parseHeader(line)
    for _, entry in ipairs({
        { action = "Updated", kind = "updated" },
        { action = "Added", kind = "added" },
        { action = "Removed", kind = "removed" },
    }) do
        local headerPattern = "^%s*•%s*" .. entry.action .. " input%s+"
        local quotedName = line:match(headerPattern .. "(.+):%s*$")
            or line:match(headerPattern .. "(.+)%s*$")
        if quotedName ~= nil then
            local name = unquote(trim(quotedName))
            if name ~= nil then
                return name, entry.kind
            end
        end
    end

    return nil, nil
end

local function shortRevision(reference)
    local revision = reference:match("[?&]rev=([^&#]+)")
    if revision == nil then
        local path = reference:gsub("[?#].*$", ""):gsub("/+$", "")
        revision = path:match("/([^/]+)$")
    end

    if revision == nil or revision == "" then
        return "?"
    end

    return revision:sub(1, 8)
end

local function parseDetail(line)
    if line:match("^%s") == nil then
        return nil
    end

    local text = trim(line)
    local isNew = false

    if text:sub(1, 3) == "→" then
        isNew = true
        text = trim(text:sub(4))
    elseif text:sub(1, 2) == "->" then
        isNew = true
        text = trim(text:sub(3))
    end

    local reference = nil
    local first = text:sub(1, 1)
    if first == "'" or first == '"' then
        reference = text:match("^" .. first .. "(.-)" .. first)
    elseif text:sub(1, 3) == "‘" then
        reference = text:match("^‘(.-)’")
    elseif text:sub(1, 3) == "“" then
        reference = text:match("^“(.-)”")
    else
        local candidate = text:match("^([^%s%(]+)")
        if candidate ~= nil and (candidate:find(":", 1, true) or candidate:find("/", 1, true)) then
            reference = candidate
        end
    end

    if reference == nil then
        return nil
    end

    local date = trim(text:match("%(([^()]*)%)%s*$") or "")

    return {
        isNew = isNew,
        revision = shortRevision(reference),
        date = date ~= "" and date or "?",
    }
end

local function parseUpdateOutput(output)
    local changedInputs = {}
    local current = nil
    local normalized = stripAnsi(output):gsub("\r\n", "\n"):gsub("\r", "\n")

    for line in (normalized .. "\n"):gmatch("(.-)\n") do
        local name, kind = parseHeader(line)
        if name ~= nil and kind ~= nil then
            current = {
                name = name,
                kind = kind,
                oldRev = kind == "added" and "—" or "?",
                newRev = kind == "removed" and "—" or "?",
                oldDate = kind == "added" and "—" or "?",
                newDate = kind == "removed" and "—" or "?",
            }
            table.insert(changedInputs, current)
        elseif current ~= nil then
            local detail = parseDetail(line)
            if detail ~= nil then
                if current.kind == "added" or detail.isNew then
                    current.newRev = detail.revision
                    current.newDate = detail.date
                elseif current.kind == "removed" then
                    current.oldRev = detail.revision
                    current.oldDate = detail.date
                elseif current.oldRev == "?" then
                    current.oldRev = detail.revision
                    current.oldDate = detail.date
                else
                    current.newRev = detail.revision
                    current.newDate = detail.date
                end
            end
        end
    end

    return changedInputs
end

return {
    parseUpdateOutput = parseUpdateOutput,
}
