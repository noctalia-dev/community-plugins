local interval = noctalia.getConfig("interval")
local secret = noctalia.getConfig("api-secret")
local host = noctalia.getConfig("host"):gsub("/+$", "")

if host == "" then
  noctalia.notifyError("Missing host address")
  return
end
if secret == "" then
  noctalia.notifyError("Missing API secret")
  return
end

noctalia.setUpdateInterval(interval * 1000)

function fetch()
    noctalia.http({ url = host .. "/api/v1/entries/sgv.json?count=1", headers={'API-SECRET: ' .. secret}, }, function(res)
      if res.ok and (res.status == 200) then
        local sgv = res.body:match('"sgv"%s*:%s*(%d+)')
        local direction = res.body:match('"direction"%s*:%s*"([^"]+)"')
        if sgv and direction then
          noctalia.state.set("glucose", tonumber(sgv))
          noctalia.state.set("trend", direction)
        else
          noctalia.notifyError("Failed to parse NS response")
        end
      elseif res.status == 401 then
        noctalia.notifyError("Invalid API secret")
      elseif res.status == 404 then
        noctalia.notifyError("Invalid host")
      else
        noctalia.notifyError(`HTTP request failed. Status {res.status}`)
      end
    end)
end

function update()
  noctalia.runAsync("noctalia msg plugin nuddel69/nightscout-monitor:ticker all fetch", function() end)
end

function onIpc(event, payload)
  if event == "fetch" then
    fetch()
  end
end
