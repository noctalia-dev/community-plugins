-- reset section

noctalia.runAsync("pkill linux-wallpaper")
local entries = noctalia.listDir("/tmp")
for _, entrieName in entries do
    if entrieName:match("^w%-engine") then              -- match for w-engine tmp file
		noctalia.removeFile("/tmp/" .. entrieName)
	end
end

-- realod section