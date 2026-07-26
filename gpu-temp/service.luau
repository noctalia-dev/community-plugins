-- service.luau -- System Monitor Config: enables GPU temp polling + adds widgets to bar

local patched = false

local function setupConfig()
    if patched then return end
    patched = true

    local home = os.getenv("HOME")
    local configPath = home .. "/.local/state/noctalia/settings.toml"

    local cmd = [[
CONFIG="]] .. configPath .. [["

# 1. Ensure [system.monitor] with gpu_poll_seconds
if grep -q '^\[system\.monitor\]' "$CONFIG" 2>/dev/null; then
    if ! grep -q 'gpu_poll_seconds' "$CONFIG"; then
        sed -i '/^\[system\.monitor\]/a gpu_poll_seconds = 5.0' "$CONFIG"
    else
        sed -i '/^\[system\.monitor\]/,/^\[/s/gpu_poll_seconds = .*/gpu_poll_seconds = 5.0/' "$CONFIG"
    fi
    if ! grep -q 'cpu_poll_seconds' "$CONFIG"; then
        sed -i '/^\[system\.monitor\]/a cpu_poll_seconds = 2.0' "$CONFIG"
    fi
else
    printf '\n[system.monitor]\ncpu_poll_seconds = 2.0\ngpu_poll_seconds = 5.0\n' >> "$CONFIG"
fi

# 2. Ensure [widget.sysmon] stat = "cpu_temp"
if ! grep -q '^\[widget\.sysmon\]' "$CONFIG" 2>/dev/null; then
    printf '\n[widget.sysmon]\nstat = "cpu_temp"\n' >> "$CONFIG"
fi

# 3. Ensure [widget.temp] stat = "gpu_temp"
if ! grep -q '^\[widget\.temp\]' "$CONFIG" 2>/dev/null; then
    printf '\n[widget.temp]\nstat = "gpu_temp"\n' >> "$CONFIG"
fi

# 4. Add sysmon + temp to bar start if not present
if grep -q '^start = \[' "$CONFIG" 2>/dev/null; then
    if ! echo "$(grep '^start = \[' "$CONFIG")" | grep -q '"sysmon"'; then
        sed -i '/^start = \[/ s/\]/, "sysmon"\]/' "$CONFIG"
    fi
    if ! echo "$(grep '^start = \[' "$CONFIG")" | grep -q '"temp"'; then
        sed -i '/^start = \[/ s/\]/, "temp"\]/' "$CONFIG"
    fi
fi
]]

    noctalia.runAsync(cmd, function(result)
        if result.exitCode == 0 then
            noctalia.log("gpu-temp: system monitor configured successfully")
        else
            noctalia.log("gpu-temp: failed to configure: " .. (result.stderr or "unknown"))
        end
    end)
end

noctalia.setUpdateInterval(300000)
setupConfig()

function update()
    setupConfig()
end