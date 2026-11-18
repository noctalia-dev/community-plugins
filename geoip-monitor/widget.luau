--!nonstrict

local lastIpifyIp = nil
local cachedIp = nil
local cachedCity = nil
local cachedRegion = nil
local geoInFlight = false

local function getDisplayText(showCity, showState, showIp, separator)
    local geoParts = {}
    if showCity then
        table.insert(geoParts, cachedCity or "Loading...")
    end
    if showState then
        table.insert(geoParts, cachedRegion or "Loading...")
    end
    
    local geoStr = table.concat(geoParts, ", ")
    
    if (showCity or showState) and showIp then
        if geoStr ~= "" and cachedIp then
            return geoStr .. separator .. cachedIp
        elseif cachedIp then
            return cachedIp
        else
            return geoStr
        end
    elseif (showCity or showState) then
        return geoStr ~= "" and geoStr or "Loading..."
    elseif showIp then
        return cachedIp or "Loading..."
    else
        return ""
    end
end

local function renderWidget()
    local showIp = noctalia.getConfig("show_ip")
    if showIp == nil then showIp = true end

    local showCity = noctalia.getConfig("show_city")
    if showCity == nil then showCity = true end

    local showState = noctalia.getConfig("show_state")
    if showState == nil then showState = true end

    local showIcon = noctalia.getConfig("show_icon")
    if showIcon == nil then showIcon = true end

    local separator = noctalia.getConfig("separator")
    if separator == nil then separator = " | " end

    local container = barWidget.isVertical() and ui.column or ui.row
    local children = {}

    if showIcon then
        table.insert(children, ui.glyph({ name = "globe", size = 14 }))
    end

    local text = getDisplayText(showCity, showState, showIp, separator)
    if text ~= "" then
        table.insert(children, ui.label({ text = text }))
    end

    barWidget.render(container({ gap = 6, align = "center" }, children))
end

function update()
    local intervalSec = noctalia.getConfig("interval") or 5
    noctalia.setUpdateInterval(intervalSec * 1000)

    renderWidget()

    -- TIER 1: Lightweight tripwire check
    -- -f: treat HTTP errors as failures; --max-time: don't hang forever
    noctalia.runAsync({"curl", "-s", "-f", "--max-time", "5", "https://api.ipify.org"}, function(result)
        local currentIp = ""
        if result.exitCode == 0 then
            currentIp = string.gsub(result.stdout, "%s+", "")
        end

        -- Sanity check: IPv4/IPv6 characters only (guards against captive-portal HTML)
        local valid = currentIp ~= "" and string.match(currentIp, "^[%x%.:]+$") ~= nil

        if not valid then
            cachedCity = "Offline"
            cachedRegion = "Offline"
            -- Forget the last IP so that when we're back online (even with the
            -- same IP) Tier 2 reruns and overwrites "Offline"
            lastIpifyIp = nil
            renderWidget()
            return
        end

        -- Fire Tier 2 only if the IP changed (or the last lookup never succeeded)
        -- AND no geo request is already running
        if currentIp ~= lastIpifyIp and not geoInFlight then
            geoInFlight = true

            -- TIER 2: Sole source of truth for display
            noctalia.runAsync({"curl", "-s", "-f", "--max-time", "8", "https://ipwho.is/"}, function(geoResult)
                geoInFlight = false -- cleared first so every path below releases it

                -- Rate-limited / failed lookups come back as {"success":false,...}
                local failed = geoResult.exitCode ~= 0
                    or string.find(geoResult.stdout, '"success"%s*:%s*false') ~= nil

                local ip = nil
                if not failed then
                    ip = string.match(geoResult.stdout, '"ip"%s*:%s*"([^"]+)"')
                end

                if ip then
                    local city = string.match(geoResult.stdout, '"city"%s*:%s*"([^"]+)"')
                    local region = string.match(geoResult.stdout, '"region"%s*:%s*"([^"]+)"')

                    cachedIp = ip
                    cachedCity = city or "Unknown"
                    cachedRegion = region or "Unknown"
                    -- Only mark this IP as handled once geo actually succeeded
                    lastIpifyIp = currentIp
                else
                    cachedCity = "Geo Error"
                    cachedRegion = "Geo Error"
                    -- Leave unset so the next tick retries
                    lastIpifyIp = nil
                end

                renderWidget()
            end)
        end
    end)
end

function onClick()
    lastIpifyIp = nil
    cachedIp = nil
    cachedCity = nil
    cachedRegion = nil
    renderWidget()
    update()
end

