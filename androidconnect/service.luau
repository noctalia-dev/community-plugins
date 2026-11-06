--!nonstrict
-- One companion owns device IO. Other entries are thin state-driven clients.
local runtime = nil
local pending = {}
local sequence = 0
local lastStatus = 0
local helper = noctalia.pluginDir() .. "/backend.py"
local data, dataError = noctalia.pluginDataDir()

local function send(request)
  if not runtime then
    if #pending < 16 then table.insert(pending, request)
    else noctalia.notifyError(noctalia.tr("title"), noctalia.tr("errors.busy")) end
    return
  end
  local files = noctalia.listDir(runtime)
  if files and #files >= 24 then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("errors.busy"))
    return
  end
  sequence += 1
  local name = string.format("%013.0f-%06d", noctalia.nowMs(), sequence)
  local temporary = runtime .. "/" .. name .. ".pending"
  local contents = noctalia.json.encode(request)
  local ok, err = noctalia.writeFile(temporary, contents)
  if ok then ok, err = noctalia.renameFile(temporary, runtime .. "/" .. name .. ".json") end
  if not ok then
    noctalia.removeFile(temporary)
    noctalia.notifyError(noctalia.tr("title"), err or noctalia.tr("errors.companion"))
  end
end

local function configure()
  send({ action = "configure", options = {
    video_device = noctalia.getConfig("video_device"),
    auto_mirror = noctalia.getConfig("auto_mirror"),
    preview_height = noctalia.getConfig("preview_height"),
    fps = noctalia.getConfig("fps"),
  } })
end

noctalia.state.watch("command", function(request)
  if type(request) == "table" then
    send(request)
    noctalia.state.set("command", nil)
  end
end)

local function shellQuote(value)
  return "'" .. string.gsub(value, "'", "'\\''") .. "'"
end

if not data or not noctalia.commandExists("python3") then
  noctalia.state.set("status", { phase = "error", error = dataError or noctalia.tr("errors.python"), adb = {}, kde = {} })
else
  -- runStream only accepts a shell string. Only fixed argv and individually
  -- quoted local paths enter it; all actions use private JSON, not shell text.
  lastStatus = noctalia.nowMs()
  local started = noctalia.runStream("exec python3 -B -u " .. shellQuote(helper) .. " --data " .. shellQuote(data), function(line)
    local event = noctalia.json.decode(line)
    if type(event) ~= "table" then return end
    if event.kind == "status" and type(event.value) == "table" then
      local first = runtime == nil
      runtime = event.value.runtime
      lastStatus = noctalia.nowMs()
      noctalia.state.set("status", event.value)
      if first then
        configure()
        for _, request in pending do send(request) end
        table.clear(pending)
      end
    elseif event.kind == "notice" then
      local body = noctalia.tr(event.key)
      if event.detail and event.detail ~= "" then body ..= "\n" .. event.detail end
      if event.error then noctalia.notifyError(noctalia.tr("title"), body)
      else noctalia.notify(noctalia.tr("title"), body) end
    end
  end)
  if not started then
    noctalia.state.set("status", { phase = "error", error = noctalia.tr("errors.companion"), adb = {}, kde = {} })
  end
end

noctalia.setUpdateInterval(5000)

function update()
  if lastStatus > 0 and noctalia.nowMs() - lastStatus > 45000 then
    local status = noctalia.state.get("status") or {}
    status.phase = "error"
    status.error = noctalia.tr("errors.companion")
    noctalia.state.set("status", status)
  end
end

function onConfigChanged()
  if runtime then configure() end
  noctalia.state.set("preferences", {
    hide = noctalia.getConfig("hide_when_disconnected") == true,
    color = noctalia.getConfig("icon_color") or "primary",
  })
end

function onIpc(event)
  if event == "toggle" then noctalia.togglePanel("demencia89/androidconnect:panel")
  elseif event == "refresh" then send({ action = "refresh" }) end
end

onConfigChanged()
