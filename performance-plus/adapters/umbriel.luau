local M = {}

local home = noctalia.getenv("HOME") or ""
local xdgConfig = noctalia.getenv("XDG_CONFIG_HOME")
local configDir = (xdgConfig and xdgConfig ~= "") and xdgConfig or (home .. "/.config")

local xdgRuntime = noctalia.getenv("XDG_RUNTIME_DIR")
local runtimeDir = (xdgRuntime and xdgRuntime ~= "") and (xdgRuntime .. "/noctalia-performance-plus") or (home .. "/.cache/noctalia-performance-plus")

local PERF_CONFIG_PATH = runtimeDir .. "/umbriel-perf.toml"
local BASE_CONFIG_PATH = configDir .. "/umbriel/config.toml"

function M.enable(opts)
    if opts.blur == false and opts.animations == false and opts.shadows == false then
        return
    end

    if opts.blur ~= false then
        noctalia.runAsync({"umbriel", "msg", "effect-screen-set:off"})
    end

    local parts = {
        string.format('[include]\nfiles = ["%s"]', BASE_CONFIG_PATH)
    }

    if opts.blur ~= false then
        table.insert(parts, [==[
[appearance.blur]
enabled = false

[[layer_rule]]
match.namespace = "^noctalia-"
blur = false

[[window_rule]]
blur = false
]==])
    end

    if opts.shadows ~= false then
        table.insert(parts, [==[
[appearance.shadow]
enabled = false
]==])
    end

    if #parts == 1 then
        return
    end

    local toml = table.concat(parts, "\n\n") .. "\n"

    -- Write temp override securely and hot-replace config in Umbriel only if base config exists and write succeeds
    local cmd = string.format([==[sh -c 'mkdir -p -m 0700 "%s" && if [ -f "%s" ]; then
    rm -f "%s"
    if cat << "EOF" > "%s"
%s
EOF
    then
        umbriel config-replace "%s"
    fi
fi']==], runtimeDir, BASE_CONFIG_PATH, PERF_CONFIG_PATH, PERF_CONFIG_PATH, toml, PERF_CONFIG_PATH)
    noctalia.runAsync(cmd)

    noctalia.log("[Umbriel] Performance mode enabled (blur & screen effects disabled)")
end

function M.disable(opts)
    if opts.blur ~= false then
        noctalia.runAsync({"umbriel", "msg", "effect-screen-set:reset"})
    end

    local cmd = string.format("sh -c 'if [ -f \"%s\" ]; then if [ -f \"%s\" ]; then umbriel config-replace \"%s\"; fi; rm -f \"%s\"; fi'", PERF_CONFIG_PATH, BASE_CONFIG_PATH, BASE_CONFIG_PATH, PERF_CONFIG_PATH)
    noctalia.runAsync(cmd)

    noctalia.log("[Umbriel] Performance mode disabled (restored base config)")
end

return M
