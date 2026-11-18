local M = {}

local EFFECTS_TO_DISABLE = {
    "blur",
    "slide",
    "scale",
    "fade",
    "windowgeometry",
    "translucency",
    "sheet",
}

local function runKwinEffects(action, effects)
    local effectArgs = table.concat(effects, " ")
    local script = string.format([[
sh -c '
kwin_call() {
    if command -v qdbus6 >/dev/null 2>&1; then
        qdbus6 org.kde.KWin /Effects "$1" "$2" 2>/dev/null || true
    elif command -v qdbus >/dev/null 2>&1; then
        qdbus org.kde.KWin /Effects "$1" "$2" 2>/dev/null || true
    elif command -v busctl >/dev/null 2>&1; then
        busctl --user call org.kde.KWin /Effects org.kde.kwin.Effects "$1" s "$2" >/dev/null 2>&1 || true
    fi
}
for effect in %s; do
    kwin_call %s "$effect"
done
if [ "%s" = "loadEffect" ]; then
    if command -v qdbus6 >/dev/null 2>&1; then
        qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null || true
    elif command -v qdbus >/dev/null 2>&1; then
        qdbus org.kde.KWin /KWin reconfigure 2>/dev/null || true
    elif command -v busctl >/dev/null 2>&1; then
        busctl --user call org.kde.KWin /KWin org.kde.KWin reconfigure >/dev/null 2>&1 || true
    fi
fi
'
]], effectArgs, action, action)

    noctalia.runAsync(script)
end

function M.enable(opts)
    if opts.blur == false and opts.animations == false and opts.shadows == false then
        return
    end

    local targetEffects = {}
    if opts.blur ~= false then
        table.insert(targetEffects, "blur")
    end

    if opts.shadows ~= false then
        table.insert(targetEffects, "shadow")
    end

    if opts.animations ~= false then
        for _, effect in ipairs(EFFECTS_TO_DISABLE) do
            if effect ~= "blur" then
                table.insert(targetEffects, effect)
            end
        end
    end

    if #targetEffects == 0 then
        return
    end

    -- Query loaded effects in KWin so we only restore what was originally active
    local queryScript = string.format([[
sh -c '
kwin_is_loaded() {
    if command -v qdbus6 >/dev/null 2>&1; then
        qdbus6 org.kde.KWin /Effects isEffectLoaded "$1" 2>/dev/null
    elif command -v qdbus >/dev/null 2>&1; then
        qdbus org.kde.KWin /Effects isEffectLoaded "$1" 2>/dev/null
    elif command -v busctl >/dev/null 2>&1; then
        busctl --user call org.kde.KWin /Effects org.kde.kwin.Effects isEffectLoaded s "$1" 2>/dev/null | grep -q "true" && echo "true" || echo "false"
    fi
}
loaded=""
for eff in %s; do
    if [ "$(kwin_is_loaded "$eff")" = "true" ]; then
        loaded="$loaded $eff"
    fi
done
echo "$loaded"
'
]], table.concat(targetEffects, " "))

    noctalia.runAsync(queryScript, function(result)
        if noctalia.state.get("performance") ~= true or noctalia.state.get("kwin_snapshot") ~= nil then
            return
        end

        local activeLoaded = {}
        if result and result.stdout then
            for word in string.gmatch(result.stdout, "%S+") do
                table.insert(activeLoaded, word)
            end
        end

        noctalia.state.set("kwin_snapshot", activeLoaded)

        if #activeLoaded > 0 then
            runKwinEffects("unloadEffect", activeLoaded)
        end
        noctalia.log("[KWin] Performance mode enabled (blur & desktop effects unloaded)")
    end)
end

function M.disable(opts)
    local activeLoaded = noctalia.state.get("kwin_snapshot")
    if activeLoaded == nil then
        return
    end

    if #activeLoaded > 0 then
        runKwinEffects("loadEffect", activeLoaded)
    end
    noctalia.state.set("kwin_snapshot", nil)
    noctalia.log("[KWin] Performance mode disabled (restored recorded desktop effects)")
end

return M
