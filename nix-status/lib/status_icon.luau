--!strict

type Host = {
    getConfig: (key: string) -> any,
    getenv: (name: string) -> string?,
    expandPath: (path: string) -> string,
    fileInfo: (path: string) -> ({ size: number, mtime: number, isDir: boolean }?, string?),
}

type Widget = {
    setImage: (path: string, watch: boolean?, width: number?, height: number?) -> (),
    setGlyph: (name: string) -> (),
    setGlyphColor: (role: string, mode: string?) -> (),
}

local function show(host: Host, widget: Widget, state: string)
    local role = "on_surface"
    local filename = "nix-logo.svg"
    if state == "updates" then
        role = "primary"
        filename = "nix-logo-updates.svg"
    elseif state == "error" then
        role = "error"
        filename = "nix-logo-error.svg"
    end

    if host.getConfig("use_themed_logos") == true then
        local configuredCache = host.getenv("XDG_CACHE_HOME")
        local cache: string = if configuredCache ~= nil and configuredCache ~= ""
            then configuredCache
            else host.expandPath("~/.cache")
        local path = cache .. "/noctalia/" .. filename
        local info = host.fileInfo(path)
        if info ~= nil and not info.isDir and info.size > 0 then
            widget.setImage(path, true, 28, 28)
            return
        end
    end

    -- setGlyph also clears the previous image and its file watcher.
    widget.setGlyph("snowflake")
    widget.setGlyphColor(role, "script")
end

return {
    show = show,
}
