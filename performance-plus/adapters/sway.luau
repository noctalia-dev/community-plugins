local M = {}

function M.enable(opts)
    if opts.blur == false and opts.animations == false and opts.shadows == false then
        return
    end

    local cmds = {}
    if opts.blur ~= false then
        table.insert(cmds, "swaymsg blur disable 2>/dev/null || true")
    end
    if opts.shadows ~= false then
        table.insert(cmds, "swaymsg shadows disable 2>/dev/null || true")
    end
    if opts.animations ~= false then
        table.insert(cmds, "swaymsg corner_radius 0 2>/dev/null || true")
        table.insert(cmds, "swaymsg default_dim_inactive 0.0 2>/dev/null || true")
    end

    if #cmds == 0 then
        return
    end

    local script = table.concat(cmds, "; ")
    noctalia.runAsync(string.format("sh -c '%s'", script))
    noctalia.log("[Sway] Performance mode enabled (SwayFX effects disabled)")
end

function M.disable(opts)
    -- Reload Sway configuration to cleanly restore the user's original corner_radius, dimming, blur, and shadows
    local script = "swaymsg reload 2>/dev/null || true"
    noctalia.runAsync(string.format("sh -c '%s'", script))
    noctalia.log("[Sway] Performance mode disabled (restored base Sway config)")
end

return M
