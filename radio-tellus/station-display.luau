--!nonstrict
-- Format sanitized station fields for compact UI display.
-- Stored and search values remain unchanged.

local station = require("./station-utils.luau")
local display = {}

local COUNTRY_ALIASES = {
    ["the united states of america"] = "United States",
    ["united states of america"] = "United States",
    ["usa"] = "United States",
    ["us"] = "United States",
    ["the united kingdom of great britain and northern ireland"] = "United Kingdom",
    ["united kingdom of great britain and northern ireland"] = "United Kingdom",
    ["great britain"] = "United Kingdom",
    ["uk"] = "United Kingdom",
    ["russian federation"] = "Russia",
    ["republic of korea"] = "South Korea",
    ["korea, republic of"] = "South Korea",
    ["korea, democratic people's republic of"] = "North Korea",
    ["iran, islamic republic of"] = "Iran",
    ["syrian arab republic"] = "Syria",
    ["lao people's democratic republic"] = "Laos",
    ["moldova, republic of"] = "Moldova",
    ["tanzania, united republic of"] = "Tanzania",
    ["venezuela, bolivarian republic of"] = "Venezuela",
    ["bolivia, plurinational state of"] = "Bolivia",
    ["viet nam"] = "Vietnam",
    ["brunei darussalam"] = "Brunei",
    ["czech republic"] = "Czechia",
    ["the netherlands"] = "Netherlands",
}

local COUNTRY_CODE_FALLBACKS = {
    US = "United States", GB = "United Kingdom", KR = "South Korea",
    KP = "North Korea", RU = "Russia", CZ = "Czechia", VA = "Vatican City",
}

function display.countryName(value, countryCode)
    local name = station.singleLine(value, 100)
    local normalized = name:lower():gsub("%s+", " ")
    if COUNTRY_ALIASES[normalized] then return COUNTRY_ALIASES[normalized] end
    if name ~= "" then return name end
    local code = station.singleLine(countryCode, 2):upper()
    return COUNTRY_CODE_FALLBACKS[code] or (code:match("^[A-Z][A-Z]$") and code or "")
end

function display.voteCount(value)
    local votes = math.max(0, math.floor(tonumber(value) or 0))
    if votes < 1000 then return tostring(votes) .. (votes == 1 and " vote" or " votes") end

    local divisor, suffix = 1000, "k"
    -- Round up at unit boundaries to avoid misleading labels.
    if votes >= 999500000 then divisor, suffix = 1000000000, "B"
    elseif votes >= 999500 then divisor, suffix = 1000000, "M" end
    local scaled = votes / divisor
    local amount
    if scaled < 10 then
        amount = string.format("%.1f", scaled):gsub("%.0$", "")
    else
        amount = tostring(math.floor(scaled + 0.5))
    end
    return amount .. suffix .. " votes"
end

function display.tags(value, maximum)
    local result, seen = {}, {}
    local limit = math.max(0, math.min(5, math.floor(tonumber(maximum) or 3)))
    if limit == 0 then return result end
    for raw in tostring(value or ""):gmatch("[^,]+") do
        local tag = station.singleLine(raw:gsub("_+", " "):gsub("%s+", " "), 28)
        local key = tag:lower()
        if tag ~= "" and not seen[key] then
            seen[key] = true
            table.insert(result, tag)
            if #result >= limit then break end
        end
    end
    return result
end

function display.stationMeta(value)
    if type(value) ~= "table" then return "Live internet radio" end
    local parts = {}
    local country = display.countryName(value.country, value.country_code)
    if country ~= "" then table.insert(parts, country) end
    if tostring(value.url_resolved or ""):match("^http://") then table.insert(parts, "HTTP") end
    if (tonumber(value.votes) or 0) > 0 then table.insert(parts, display.voteCount(value.votes)) end
    local tags = display.tags(value.tags, 3)
    if #tags > 0 then table.insert(parts, table.concat(tags, ", ")) end
    return #parts > 0 and table.concat(parts, "  ·  ") or "Live internet radio"
end

return display
