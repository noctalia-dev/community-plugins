local M = {}

local home = noctalia.getenv("HOME") or ""
local xdgConfig = noctalia.getenv("XDG_CONFIG_HOME")
local configDir = (xdgConfig and xdgConfig ~= "") and xdgConfig or (home .. "/.config")

local xdgRuntime = noctalia.getenv("XDG_RUNTIME_DIR")
local runtimeDir = (xdgRuntime and xdgRuntime ~= "") and (xdgRuntime .. "/noctalia-performance-plus") or (home .. "/.cache/noctalia-performance-plus")

local PERF_CONFIG_PATH = runtimeDir .. "/mango-perf.conf"
local BASE_CONFIG_PATH = configDir .. "/mango/config.conf"

function M.enable(opts)
    if opts.animations == false and opts.blur == false and opts.shadows == false then
        return
    end

    local lines = {
        string.format("source=%s", BASE_CONFIG_PATH)
    }

    if opts.blur ~= false then
        table.insert(lines, "blur=0")
        table.insert(lines, "blur_layer=0")
    end

    if opts.animations ~= false then
        table.insert(lines, "animations=0")
        table.insert(lines, "layer_animations=0")
    end

    if opts.shadows ~= false then
      table.insert(lines, "shadows=0")
      table.insert(lines, "layer_shadows=0")
    end

    local content = table.concat(lines, "\n") .. "\n"

    -- Write temp override securely and hot-load it in Mango only if base config exists and write succeeds
    local cmd = string.format([[sh -c 'mkdir -p -m 0700 "%s" && if [ -f "%s" ]; then
    rm -f "%s"
    if cat << "EOF" > "%s"
%sEOF
    then
        mmsg dispatch load_config_file,%s
    fi
fi']], runtimeDir, BASE_CONFIG_PATH, PERF_CONFIG_PATH, PERF_CONFIG_PATH, content, PERF_CONFIG_PATH)
    noctalia.runAsync(cmd)

    noctalia.log("[Mango] Performance mode enabled (effects disabled via load_config_file)")
end

function M.disable(opts)
    -- Reset to default config and clean up temp file only if override exists
    local cmd = string.format("sh -c 'if [ -f \"%s\" ]; then mmsg dispatch load_config_file,; mmsg dispatch reload_config 2>/dev/null; rm -f \"%s\"; fi'", PERF_CONFIG_PATH, PERF_CONFIG_PATH)
    noctalia.runAsync(cmd)

    noctalia.log("[Mango] Performance mode disabled (restored default config)")
end

return M
