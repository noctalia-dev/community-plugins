--!nonstrict

local M = {}

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function stripComment(line)
    local quoted = false
    local escaped = false

    for i = 1, #line do
        local c = line:sub(i, i)

        if escaped then
            escaped = false
        elseif c == "\\" and quoted then
            escaped = true
        elseif c == '"' then
            quoted = not quoted
        elseif c == "#" and not quoted then
            return line:sub(1, i - 1)
        end
    end

    return line
end

local function unquote(value)
    value = trim(value)

    if value:sub(1, 1) == '"' and value:sub(-1) == '"' then
        value = value:sub(2, -2)
        value = value:gsub("\\\\", "\0")
        value = value:gsub('\\"', '"')
        value = value:gsub("\\n", "\n")
        value = value:gsub("\\t", "\t")
        value = value:gsub("\0", "\\")
    end

    return value
end

local function splitArray(value)
    local result = {}
    local current = ""
    local quoted = false
    local escaped = false

    for i = 1, #value do
        local c = value:sub(i, i)

        if escaped then
            current = current .. c
            escaped = false
        elseif c == "\\" and quoted then
            current = current .. c
            escaped = true
        elseif c == '"' then
            quoted = not quoted
            current = current .. c
        elseif c == "," and not quoted then
            table.insert(result, trim(current))
            current = ""
        else
            current = current .. c
        end
    end

    if trim(current) ~= "" then
        table.insert(result, trim(current))
    end

    return result
end

local parseValue

parseValue = function(value)
    value = trim(value)

    if value == "true" then
        return true
    end

    if value == "false" then
        return false
    end

    if value:sub(1, 1) == '"' then
        return unquote(value)
    end

    if value:sub(1, 1) == "[" and value:sub(-1) == "]" then
        local inner = trim(value:sub(2, -2))
        local result = {}

        if inner == "" then
            return result
        end

        for _, part in ipairs(splitArray(inner)) do
            table.insert(result, parseValue(part))
        end

        return result
    end

    local number = tonumber(value)

    if number ~= nil then
        return number
    end

    return value
end

local function parseKey(value)
    return unquote(trim(value))
end

local function getSection(root, sectionName)
    local current = root

    for part in sectionName:gmatch("[^.]+") do
        part = parseKey(part)

        if current[part] == nil then
            current[part] = {}
        end

        current = current[part]
    end

    return current
end

function M.parse(contents)
    local root = {}
    local current = root

    for rawLine in (contents .. "\n"):gmatch("(.-)\n") do
        local line = trim(stripComment(rawLine))

        if line ~= "" then
            local section = line:match("^%[([^%]]+)%]$")

            if section then
                current = getSection(root, section)
            else
                local key, value =
                    line:match("^%s*(.-)%s*=%s*(.-)%s*$")

                if key and value then
                    current[parseKey(key)] = parseValue(value)
                end
            end
        end
    end

    return root
end

return M
