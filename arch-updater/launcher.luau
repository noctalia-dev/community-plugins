-- launcher.luau -- Arch Updater: launcher provider behind /au prefix

local function getUpdates()
    local raw = noctalia.state.get("updates_raw")
    if raw and raw ~= "" then
        local decoded = noctalia.json.decode(raw)
        if decoded then return decoded end
    end
    return {}
end

function onQuery(text)
    local query = noctalia.string.trim(text)

    if query == "" then
        launcher.setResults(query, {
            {
                id = "__cmd_refresh",
                title = noctalia.tr("launcher.refresh") or "Refresh updates",
                glyph = "refresh",
                subtitle = noctalia.tr("launcher.refresh") or "Refresh updates",
            },
            {
                id = "__cmd_update",
                title = noctalia.tr("launcher.update") or "Update system",
                glyph = "arrow-big-down-lines",
                subtitle = noctalia.tr("launcher.update") or "Update system",
            },
            {
                id = "__cmd_search_hint",
                title = noctalia.tr("launcher.search") or "Search packages",
                glyph = "search",
                subtitle = noctalia.tr("launcher.searchHint") or "Type package name",
            },
        })
        return
    end

    local updates = getUpdates()
    if #updates == 0 then
        launcher.setResults(query, {
            {
                id = "__no_updates",
                title = noctalia.tr("launcher.noUpdates") or "No updates available",
                glyph = "check",
            },
        })
        return
    end

    local results = {}
    for _, u in ipairs(updates) do
        local score = noctalia.fuzzyScore(query, u.name)
        if score then
            local icon = "package"
            if u.source == "aur" then icon = "code"
            elseif u.source == "flatpak" then icon = "box" end

            table.insert(results, {
                id = "pkg:" .. u.id .. ":" .. u.source,
                title = u.name,
                subtitle = u.oldVer .. " -> " .. u.newVer,
                glyph = icon,
                score = score,
            })
        end
    end

    table.sort(results, function(a, b) return (a.score or 0) > (b.score or 0) end)

    if #results == 0 then
        launcher.setResults(query, {
            {
                id = "__no_match",
                title = noctalia.tr("launcher.noMatch") or "No match found",
                glyph = "search",
            },
        })
    else
        launcher.setResults(query, results)
    end
end

function onActivate(id)
    if id == "__cmd_refresh" then
        noctalia.state.set("refresh_request", (noctalia.state.get("refresh_request") or 0) + 1)
        return
    end

    if id == "__cmd_update" then
        noctalia.state.set("update_request", (noctalia.state.get("update_request") or 0) + 1)
        return
    end

    if string.sub(id, 1, 4) == "pkg:" then
        local parts = {}
        for part in string.gmatch(string.sub(id, 5), "[^:]+") do
            table.insert(parts, part)
        end
        if #parts >= 3 then
            local pkgId = parts[1]
            local source = parts[3]
            openPkgURL(source, pkgId)
        end
    end
end

function openPkgURL(source, pkgId)
    if source == "system" then
        noctalia.runAsync(
            "LC_ALL=C pacman -Si " .. pkgId .. " 2>/dev/null | awk '/^Repository/ {print $3; exit}'",
            function(result)
                local repo = noctalia.string.trim(result.stdout or "")
                local url = ""
                if repo == "extra" or repo == "core" or repo == "multilib" then
                    url = "https://archlinux.org/packages/" .. repo .. "/x86_64/" .. pkgId
                elseif repo == "cachyos-znver4" or repo == "cachyos-extra-znver4" or repo == "cachyos-core-znver4" then
                    url = "https://packages.cachyos.org/package/" .. repo .. "/x86_64_v4/" .. pkgId
                else
                    url = "https://archlinux.org/packages/extra/x86_64/" .. pkgId
                end
                noctalia.runAsync("xdg-open '" .. url .. "'")
            end
        )
    elseif source == "aur" then
        noctalia.runAsync("xdg-open 'https://aur.archlinux.org/packages/" .. pkgId .. "'")
    elseif source == "flatpak" then
        noctalia.runAsync("xdg-open 'https://flathub.org/en/apps/" .. pkgId .. "'")
    end
end
