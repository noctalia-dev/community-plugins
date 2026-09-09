local ANSI_SGR_PATTERN = "\27%[[0-9;]*m"

local function trim(value)
    return value:match("^%s*(.-)%s*$") or ""
end

local function stripAnsi(value)
    return value:gsub(ANSI_SGR_PATTERN, "")
end

local function ansiChange(params)
    for code in params:gmatch("[^;]+") do
        if code == "31" or code == "91" then
            return "increase"
        elseif code == "32" or code == "92" then
            return "decrease"
        end
    end

    return nil
end

local function parse(output)
    local lines = {}

    for rawLine in output:gmatch("[^\r\n]+") do
        local text = stripAnsi(rawLine)
        local prefix, amount = text:match("^(.-)([%+%-]?[%d%.]+%s+[%a]+)$")

        if prefix ~= nil and amount ~= nil then
            local change = nil
            local first = amount:sub(1, 1)

            if first == "+" then
                change = "increase"
            elseif first == "-" then
                change = "decrease"
            else
                local params, coloredAmount = rawLine:match(
                    "\27%[([0-9;]*)m([%d%.]+%s+[%a]+)\27%[[0-9;]*m%s*$"
                )

                if coloredAmount == amount and params ~= nil then
                    change = ansiChange(params)
                    if change == "increase" then
                        amount = "+" .. amount
                    elseif change == "decrease" then
                        amount = "-" .. amount
                    end
                end
            end

            table.insert(lines, {
                prefix = prefix,
                amount = amount,
                change = change,
            })
        else
            table.insert(lines, { text = text })
        end
    end

    return trim(stripAnsi(output)), lines
end

return {
    clean = function(output)
        return trim(stripAnsi(output))
    end,
    parse = parse,
}
