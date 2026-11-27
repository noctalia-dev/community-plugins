-- Loaded into mpv with --script by scripts/mpv.sh.
--
-- A freshly resolved googlevideo URL answers 403 for its first ~2 s (measured
-- 0.3-2.7 s after yt-dlp returns). mpv opens the URL immediately, the open
-- fails, and the plugin treats the resulting end-file error as a dead track.
-- on_load_fail holds the failed open and retries the same URL once it is old
-- enough, so mpv never leaves the track. The extra query parameter makes mpv
-- treat it as a new URL; googlevideo ignores parameters outside its signature.

local WARM_AFTER = 2.9 -- seconds after mpv started (yt-dlp has exited by then)
local started_at = mp.get_time()
local retried = false

mp.add_hook("on_load_fail", 50, function(hook)
	local url = mp.get_property("stream-open-filename") or ""
	if retried or mp.get_property_number("playlist-pos") ~= 1 or not url:match("^https?://") then
		return
	end
	retried = true
	hook:defer()
	mp.add_timeout(math.max(0.5, WARM_AFTER - (mp.get_time() - started_at)), function()
		mp.set_property("stream-open-filename", url .. "&ytmretry=1")
		hook:cont()
	end)
end)
