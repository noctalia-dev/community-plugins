local M = {}

local function getBaseConfigPath()
    local niriConfig = noctalia.getenv("NIRI_CONFIG")
    if niriConfig and niriConfig ~= "" and noctalia.fileExists(niriConfig) then
        return niriConfig
    end
    local xdgConfig = noctalia.getenv("XDG_CONFIG_HOME")
    if xdgConfig and xdgConfig ~= "" then
        local p = xdgConfig .. "/niri/config.kdl"
        if noctalia.fileExists(p) then return p end
    end
    local home = noctalia.getenv("HOME") or ""
    if home ~= "" then
        local p = home .. "/.config/niri/config.kdl"
        if noctalia.fileExists(p) then return p end
    end
    return (xdgConfig and xdgConfig ~= "") and (xdgConfig .. "/niri/config.kdl") or (home .. "/.config/niri/config.kdl")
end

local home = noctalia.getenv("HOME") or ""
local xdgRuntime = noctalia.getenv("XDG_RUNTIME_DIR")
local runtimeDir = (xdgRuntime and xdgRuntime ~= "") and (xdgRuntime .. "/noctalia-performance-plus") or (home .. "/.cache/noctalia-performance-plus")

local PERF_CONFIG_PATH = runtimeDir .. "/niri-perf.kdl"

function M.enable(opts)
    if opts.animations == false and opts.blur == false and opts.shadows == false then
        return
    end

    local parts = {}
    local baseConfig = getBaseConfigPath()
    if noctalia.fileExists(baseConfig) then
        table.insert(parts, string.format('include "%s"', baseConfig))
    end

    if opts.animations ~= false then
        table.insert(parts, [[
animations {
    off
}]])
    end

    if opts.blur ~= false then
        table.insert(parts, [[
window-rule {
    background-effect {
        blur false
    }
    opacity 1.0
}

layer-rule {
    match namespace="^noctalia-"
    background-effect {
        blur false
    }
}]])
    end

    if opts.shadows ~= false then
        table.insert(parts, [[
layout {
    shadow {
        off
    }
}]])
    end

    if #parts == 0 or (#parts == 1 and noctalia.fileExists(baseConfig)) then
        return
    end

    local kdl = table.concat(parts, "\n\n") .. "\n"

    -- Write temp override securely and load it in Niri only if write succeeds
    local cmd = string.format([[sh -c 'mkdir -p -m 0700 "%s"
    rm -f "%s"
    if cat << "EOF" > "%s"
%s
EOF
    then
        niri msg action load-config-file --path "%s"
    fi']], runtimeDir, PERF_CONFIG_PATH, PERF_CONFIG_PATH, kdl, PERF_CONFIG_PATH)
    noctalia.runAsync(cmd)

    noctalia.log("[Niri] Performance mode enabled (animations, opacity & effects optimized)")
end

function M.disable(opts)
    local baseConfig = getBaseConfigPath()
    local reloadCmd = ""
    if noctalia.fileExists(baseConfig) then
        reloadCmd = string.format('niri msg action load-config-file --path "%s"', baseConfig)
    else
        reloadCmd = "niri msg action load-config-file"
    end

    -- Reload base config in Niri and cleanup temp override only if override exists
    local cmd = string.format('sh -c \'if [ -f "%s" ]; then %s; rm -f "%s"; fi\'', PERF_CONFIG_PATH, reloadCmd, PERF_CONFIG_PATH)
    noctalia.runAsync(cmd)

    noctalia.log("[Niri] Performance mode disabled (restored base config)")
end

return M
