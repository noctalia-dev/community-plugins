--!nonstrict

local M = {}


local function applyWallpapers(profile)
    if not profile.wallpapers then
        return true
    end

    local monitors =
        profile.wallpapers.monitors or {}

    if profile.wallpapers.default
        and profile.wallpapers.default ~= ""
    then
        local path =
            noctalia.expandPath(
                profile.wallpapers.default
            )

        if noctalia.fileExists(path) then
            noctalia.setWallpaper(path)
        else
            noctalia.notifyError(
                noctalia.tr("common.plugin_name"),
                noctalia.tr(
                    "error.default_wallpaper_not_found",
                    { path = path }
                )
            )
        end
    end

    for connector, wallpaper in pairs(monitors) do
        local path =
            noctalia.expandPath(wallpaper)

        if noctalia.fileExists(path) then
            noctalia.setWallpaper(
                connector,
                path
            )
        else
            noctalia.notifyError(
                noctalia.tr("common.plugin_name"),
                noctalia.tr(
                    "error.monitor_wallpaper_not_found",
                    {
                        monitor = connector,
                        path = path,
                    }
                )
            )
        end
    end

    return true
end


local function applyPalette(profile)
    if not profile.palette
        or not profile.palette.source
        or not profile.palette.name
    then
        return true
    end

    noctalia.runAsync({
        "noctalia",
        "msg",
        "color-scheme-set",
        profile.palette.source,
        profile.palette.name,
    })

    return true
end


local function applyThemeMode(profile)
    if not profile.theme_mode then
        return true
    end

    noctalia.runAsync({
        "noctalia",
        "msg",
        "theme-mode-set",
        profile.theme_mode,
    })

    return true
end


function M.apply(profile)
    if not profile then
        return false, noctalia.tr("error.profile_does_not_exist")
    end

    applyWallpapers(profile)
    applyPalette(profile)
    applyThemeMode(profile)

    return true
end


return M
