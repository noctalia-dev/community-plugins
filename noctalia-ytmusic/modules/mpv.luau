local Mpv = {}
local Bash = require("../utils/bash.luau")
local scratch = require("../utils/scratch.luau")

-- url/title go through per-call scratch slots (rotating pool, overwritten on
-- reuse) so a fast track switch can never clobber the previous launch inputs.
function Mpv.play(url, title, volume, on_ready)
    local url_file = scratch.path("mpv-url")
    local title_file = scratch.path("mpv-title")
    noctalia.writeFile(url_file, url)
    noctalia.writeFile(title_file, title or "")
    Bash.run_script("mpv.sh", "mpv_play", function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        if type(on_ready) == "function" then
            on_ready(out:find("READY=1") ~= nil)
        end
    end, 10000, tostring(volume or 100), url_file, title_file)
end

function Mpv.send(payload_json)
    Bash.run_script("mpv.sh", "mpv_send", function() end, 5000, payload_json)
end

function Mpv.kill()
    Bash.run_script("mpv.sh", "mpv_kill", function() end, 2000)
end

-- Persistent push stream. One handle per mpv instance; the stream ends on its
-- own when mpv dies (socket closes). Each emitted JSON line goes to on_line.
function Mpv.stream(on_line)
    return Bash.run_stream("mpv.sh", "mpv_stream", on_line)
end

return Mpv
