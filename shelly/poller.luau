--!nonstrict

type Update = { Name: string, Version: string, OldVersion: string?, DownloadSize: string? }

type UpdateResult = {
    Packages: { [number]: Update },
    Aur: { [number]: Update },
    Flatpak: { [number]: Update },
}

local updates: UpdateResult = { Packages = {}, Aur = {}, Flatpak = {} }
local updateError: string | nil = nil
local updateInterval = (noctalia.getConfig("interval") or 300)*1000
local isPolling = false

noctalia.setUpdateInterval(updateInterval)

function refresh()
  isPolling = true

  noctalia.runAsync("shelly check-updates --json", function(result)
    isPolling = false

    if result.exitCode ~= 0 then
        updateError = result.stderr
        noctalia.state.set("updates", nil)
        noctalia.state.set("update_error", updateError)
        return
    end

    local decoded = noctalia.json.decode(result.stdout)
    if type(decoded) ~= "table" then
        updateError = noctalia.tr("bar.tooltip.error.decode_json")
        noctalia.state.set("update_error", updateError)
        return
    end

    updates = {
        Packages = decoded.Packages or {},
        Aur = decoded.Aur or {},
        Flatpak = decoded.Flatpak or {},
    }

    noctalia.state.set("updates", updates)
    noctalia.state.set("update_error", nil)
  end)
end

function update()
  if isPolling then
    return
  end

  refresh()
end

refresh()
