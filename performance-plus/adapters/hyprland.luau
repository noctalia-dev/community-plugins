local M = {}

local function apply(blur, animations, shadow)
    local decParts = {}
    local rootParts = {}
    local legacyCmds = {}

    if blur ~= nil then
        table.insert(decParts, string.format("blur = { enabled = %s }", tostring(blur)))
        table.insert(legacyCmds, string.format("hyprctl keyword decoration:blur:enabled %s", tostring(blur)))
    end

    if shadow ~= nil then
        table.insert(decParts, string.format("shadow = { enabled = %s }", tostring(shadow)))
        table.insert(legacyCmds, string.format("hyprctl keyword decoration:shadow:enabled %s", tostring(shadow)))
    end

    if #decParts > 0 then
        table.insert(rootParts, "decoration = { " .. table.concat(decParts, ", ") .. " }")
    end

    if animations ~= nil then
        table.insert(rootParts, string.format("animations = { enabled = %s }", tostring(animations)))
        table.insert(legacyCmds, string.format("hyprctl keyword animations:enabled %s", animations and "1" or "0"))
    end

    local luaConfig = "hl.config({ " .. table.concat(rootParts, ", ") .. " })"
    local legacyScript = table.concat(legacyCmds, "; ")

    -- Hybrid execution: try modern Hyprland Lua parser first (Hyprland 0.56+), fall back to legacy hyprctl keyword
    local cmd = string.format([[sh -c '
if hyprctl eval "%s" 2>&1 | grep -q "ok"; then
    exit 0
fi
%s
']], luaConfig, legacyScript)

    noctalia.runAsync(cmd)
end

function M.enable(opts)
    if opts.blur == false and opts.animations == false and opts.shadows == false then
        return
    end

    if noctalia.state.get("hyprland_snapshot") ~= nil then
        return
    end

    local probeCmd = [[sh -c 'echo "{\"blur\":$(hyprctl -j getoption decoration:blur:enabled 2>/dev/null | grep -o "\"bool\": *[a-z]*" | cut -d: -f2),\"anim\":$(hyprctl -j getoption animations:enabled 2>/dev/null | grep -o "\"bool\": *[a-z]*" | cut -d: -f2),\"shadow\":$(hyprctl -j getoption decoration:shadow:enabled 2>/dev/null | grep -o "\"bool\": *[a-z]*" | cut -d: -f2)}"' ]]
    noctalia.runAsync(probeCmd, function(result)
        if noctalia.state.get("performance") ~= true then
            return
        end
        if noctalia.state.get("hyprland_snapshot") ~= nil then
            return
        end

        local snap = { blur = true, anim = true, shadow = true }
        if result and result.stdout and result.stdout ~= "" then
            local decoded = noctalia.json.decode(result.stdout)
            if decoded then
                if decoded.blur ~= nil then snap.blur = decoded.blur end
                if decoded.anim ~= nil then snap.anim = decoded.anim end
                if decoded.shadow ~= nil then snap.shadow = decoded.shadow end
            end
        end
        noctalia.state.set("hyprland_snapshot", snap)

        local targetBlur = if opts.blur == true then false else nil
        local targetAnim = if opts.animations == true then false else nil
        local targetShadow = if opts.shadows == true then false else nil

        apply(targetBlur, targetAnim, targetShadow)
        noctalia.log("[Hyprland] Performance mode enabled (selected effects disabled)")
    end)
end

function M.disable(opts)
    local snap = noctalia.state.get("hyprland_snapshot")
    if not snap then
        return
    end

    local restoreBlur = if opts.blur == true then (if snap.blur ~= nil then snap.blur else true) else nil
    local restoreAnim = if opts.animations == true then (if snap.anim ~= nil then snap.anim else true) else nil
    local restoreShadow = if opts.shadows == true then (if snap.shadow ~= nil then snap.shadow else true) else nil

    apply(restoreBlur, restoreAnim, restoreShadow)
    noctalia.state.set("hyprland_snapshot", nil)
    noctalia.log("[Hyprland] Performance mode disabled (restored recorded effects)")
end

return M
