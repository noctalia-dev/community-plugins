--!nonstrict

local MAX_VISIBLE_ITEMS = 32
local snapshot = noctalia.state.get("docker_snapshot") or {
  available = false,
  loading = true,
  busy = false,
  containers = {},
  images = {},
  volumes = {},
  networks = {},
  error = "",
}
local currentTab = "containers"
local selectedKey = ""
local selectSlots = {}
local requestCounter = 0
local pendingRunRequest = nil
local pendingInspectRequest = nil
local feedback = ""
local feedbackError = false

local showRunForm = false
local runFormGeneration = 0
local runImage = ""
local runName = ""
local runPort = "8080"
local runPublishPort = true
local runEnvironment = ""
local runNetworkIndex = 0
local runFormError = ""
local dirty = true

local render

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function itemsForTab()
  local value = snapshot[currentTab]
  return type(value) == "table" and value or {}
end

local function keyForItem(item)
  if currentTab == "containers" or currentTab == "images" or currentTab == "networks" then
    return tostring(item.id or "")
  end
  return tostring(item.name or "")
end

local function selectedItem()
  if selectedKey == "" then
    return nil
  end
  for _, item in ipairs(itemsForTab()) do
    if keyForItem(item) == selectedKey then
      return item
    end
  end
  return nil
end

local function nextRequestId()
  requestCounter += 1
  return `panel-{requestCounter}`
end

local function sendCommand(action, values)
  local command = {
    action = action,
    requestId = nextRequestId(),
  }
  if type(values) == "table" then
    for key, value in pairs(values) do
      command[key] = value
    end
  end
  noctalia.state.set("docker_command", command)
  return command.requestId
end

local function guessPort(image)
  local lower = tostring(image):lower()
  if lower:find("mongo", 1, true) then return "27017" end
  if lower:find("postgres", 1, true) then return "5432" end
  if lower:find("redis", 1, true) then return "6379" end
  if lower:find("mysql", 1, true) or lower:find("mariadb", 1, true) then return "3306" end
  if lower:find("nginx", 1, true) or lower:find("apache", 1, true) or lower:find("httpd", 1, true) then return "80" end
  if lower:find("node", 1, true) or lower:find("react", 1, true) then return "3000" end
  return "8080"
end

local function networkNames()
  local names = {}
  for _, network in ipairs(snapshot.networks or {}) do
    table.insert(names, tostring(network.name or ""))
  end
  if #names == 0 then
    names[1] = "bridge"
  end
  return names
end

local function chooseDefaultNetwork()
  local names = networkNames()
  local configured = noctalia.getConfig("default_network")
  if type(configured) ~= "string" or configured == "" then
    configured = "bridge"
  end
  runNetworkIndex = 0
  for index, name in ipairs(names) do
    if name == configured then
      runNetworkIndex = index - 1
      break
    end
  end
end

local function detailLabel(key, value)
  local text = tostring(value or "")
  if text == "" then text = "—" end
  return ui.label({
    text = tr(key, { value = text }),
    color = "on_surface_variant",
    fontSize = 12,
    maxLines = 1,
  })
end

local function itemTitle(item)
  if currentTab == "containers" then return item.name end
  if currentTab == "images" then return item.name end
  return item.name
end

local function itemGlyph()
  if currentTab == "containers" then return "brand-docker" end
  if currentTab == "images" then return "photo" end
  if currentTab == "volumes" then return "database" end
  return "network"
end

local function itemDetails(item)
  if currentTab == "containers" then
    return {
      detailLabel("details.image", item.image),
      detailLabel("details.status", item.status),
      detailLabel("details.ports", item.ports),
    }
  elseif currentTab == "images" then
    return {
      detailLabel("details.id", item.id),
      detailLabel("details.size", item.size),
      detailLabel("details.created", item.created),
    }
  elseif currentTab == "volumes" then
    return {
      detailLabel("details.driver", item.driver),
      detailLabel("details.mountpoint", item.mountpoint),
    }
  end
  return {
    detailLabel("details.id", item.id),
    detailLabel("details.driver", item.driver),
    detailLabel("details.scope", item.scope),
  }
end

local function itemSummary(item)
  if currentTab == "containers" then
    return `{item.name}  ·  {item.image}  ·  {item.status}`
  elseif currentTab == "images" then
    return `{item.name}  ·  {item.size}  ·  {item.created}`
  elseif currentTab == "volumes" then
    return `{item.name}  ·  {item.driver}  ·  {item.mountpoint}`
  end
  return `{item.name}  ·  {item.driver}  ·  {item.scope}`
end

local function itemCard(item, slotIndex)
  local key = keyForItem(item)
  local selected = key == selectedKey
  selectSlots[slotIndex] = key
  return ui.button({
    key = key,
    text = itemSummary(item),
    glyph = itemGlyph(),
    contentAlign = "start",
    variant = selected and "primary" or "outline",
    selected = selected,
    onClick = `onSelect{slotIndex}`,
  })
end

local function actionButton(text, glyph, callback, destructive, enabled)
  return ui.button({
    text = text,
    glyph = glyph,
    variant = destructive and "destructive" or "outline",
    enabled = enabled ~= false and snapshot.busy ~= true,
    onClick = callback,
  })
end

local function selectionToolbar()
  local item = selectedItem()
  if item == nil then
    return ui.label({ text = tr("panel.select_hint"), color = "on_surface_variant" })
  end

  local buttons = {}
  if currentTab == "containers" then
    local running = item.state == "running"
    table.insert(buttons, actionButton(tr("actions.start"), "player-play", "onStart", false, not running))
    table.insert(buttons, actionButton(tr("actions.stop"), "player-stop", "onStop", false, running))
    table.insert(buttons, actionButton(tr("actions.restart"), "refresh", "onRestart", false, running))
    table.insert(buttons, actionButton(tr("actions.remove"), "trash", "onRemove", true, not running))
  elseif currentTab == "images" then
    table.insert(buttons, actionButton(tr("actions.run"), "player-play", "onRunImage", false, true))
    table.insert(buttons, actionButton(tr("actions.remove"), "trash", "onRemove", true, item.isRunning ~= true))
  elseif currentTab == "volumes" then
    table.insert(buttons, actionButton(tr("actions.remove"), "trash", "onRemove", true, true))
  else
    table.insert(buttons, actionButton(tr("actions.remove"), "trash", "onRemove", true, item.isDefault ~= true))
  end

  local details = itemDetails(item)
  table.insert(details, 1, ui.row({ gap = 8, align = "center" }, {
    ui.label({ text = tostring(itemTitle(item)), fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
    ui.row({ gap = 6, align = "center" }, buttons),
  }))
  return ui.column({ gap = 3, padding = 8, fill = "surface_variant/0.45", radius = 10 }, details)
end

local function emptyMessage()
  if currentTab == "containers" then return tr("panel.no_containers") end
  if currentTab == "images" then return tr("panel.no_images") end
  if currentTab == "volumes" then return tr("panel.no_volumes") end
  return tr("panel.no_networks")
end

local function itemList()
  local items = itemsForTab()
  if #items == 0 then
    return ui.column({ align = "center", padding = 24 }, {
      ui.glyph({ name = itemGlyph(), size = 42, color = "on_surface_variant" }),
      ui.label({ text = emptyMessage(), color = "on_surface_variant", textAlign = "center" }),
    })
  end
  local rows = {}
  local count = math.min(#items, MAX_VISIBLE_ITEMS)
  for index = 1, count do
    table.insert(rows, itemCard(items[index], index - 1))
  end
  if #items > MAX_VISIBLE_ITEMS then
    table.insert(rows, ui.label({
      text = tr("panel.showing_limit", { count = MAX_VISIBLE_ITEMS }),
      color = "on_surface_variant",
      textAlign = "center",
    }))
  end
  return ui.column({ gap = 8 }, rows)
end

local function runForm()
  local names = networkNames()
  return ui.scroll({ flexGrow = 1, gap = 12 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = tr("run_form.title", { image = runImage }), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "close", onClick = "onCancelRun" }),
    }),
    ui.label({ text = tr("run_form.container_name"), color = "on_surface_variant" }),
    ui.input({
      key = `run-name-{runFormGeneration}`,
      value = runName,
      placeholder = tr("run_form.container_name_placeholder"),
      onChange = "onRunNameChange",
    }),
    ui.label({ text = tr("run_form.network"), color = "on_surface_variant" }),
    ui.select({
      key = `run-network-{runFormGeneration}`,
      options = names,
      selectedIndex = runNetworkIndex,
      onChange = "onRunNetworkChange",
    }),
    ui.row({ gap = 10, align = "center" }, {
      ui.toggle({ checked = runPublishPort, onChange = "onRunPublishPortChange" }),
      ui.label({ text = tr("run_form.publish_port"), flexGrow = 1 }),
    }),
    ui.label({ text = tr("run_form.port"), color = "on_surface_variant", visible = runPublishPort }),
    ui.input({
      key = `run-port-{runFormGeneration}`,
      value = runPort,
      placeholder = tr("run_form.port_placeholder"),
      onChange = "onRunPortChange",
      visible = runPublishPort,
    }),
    ui.label({ text = tr("run_form.environment"), color = "on_surface_variant" }),
    ui.input({
      key = `run-environment-{runFormGeneration}`,
      value = runEnvironment,
      placeholder = tr("run_form.environment_placeholder"),
      multiline = true,
      height = 130,
      onChange = "onRunEnvironmentChange",
    }),
    ui.label({ text = tr("run_form.environment_help"), color = "on_surface_variant", fontSize = 12 }),
    ui.label({ text = runFormError, color = "error", visible = runFormError ~= "" }),
    ui.row({ justify = "end", gap = 8 }, {
      ui.button({ text = tr("actions.cancel"), variant = "outline", onClick = "onCancelRun" }),
      ui.button({ text = tr("actions.run"), glyph = "player-play", variant = "primary", enabled = snapshot.busy ~= true, onClick = "onConfirmRun" }),
    }),
  })
end

local function tabButton(label, tab, callback)
  return ui.button({
    text = label,
    selected = currentTab == tab,
    variant = currentTab == tab and "primary" or "ghost",
    onClick = callback,
  })
end

render = function()
  dirty = false
  selectSlots = {}
  local statusRows = {}
  if snapshot.loading == true then
    table.insert(statusRows, ui.label({ text = tr("panel.loading"), color = "on_surface_variant" }))
  end
  if snapshot.busy == true then
    table.insert(statusRows, ui.label({ text = tr("panel.busy"), color = "primary" }))
  end
  if type(snapshot.error) == "string" and snapshot.error ~= "" then
    table.insert(statusRows, ui.label({ text = snapshot.error, color = "error", maxLines = 2 }))
  end
  if feedback ~= "" then
    table.insert(statusRows, ui.label({ text = feedback, color = feedbackError and "error" or "tertiary", maxLines = 2 }))
  end

  local content = showRunForm and runForm() or ui.column({ flexGrow = 1, gap = 10 }, {
    selectionToolbar(),
    ui.scroll({ flexGrow = 1, gap = 8 }, { itemList() }),
  })

  panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "brand-docker", size = 24, color = snapshot.available and "primary" or "on_surface_variant" }),
      ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ text = tr("actions.refresh"), glyph = "refresh", variant = "outline", onClick = "onRefresh" }),
      ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    }),
    ui.row({ gap = 4, align = "center" }, {
      tabButton(tr("tabs.containers"), "containers", "onTabContainers"),
      tabButton(tr("tabs.images"), "images", "onTabImages"),
      tabButton(tr("tabs.volumes"), "volumes", "onTabVolumes"),
      tabButton(tr("tabs.networks"), "networks", "onTabNetworks"),
      ui.spacer({ flexGrow = 1 }),
      ui.label({
        text = (snapshot.updatedAt or 0) > 0 and tr("panel.updated", { time = noctalia.formatTime("%H:%M:%S", snapshot.updatedAt) }) or "",
        color = "on_surface_variant",
        fontSize = 11,
      }),
    }),
    ui.column({ gap = 3 }, statusRows),
    content,
  }))
end

local function selectAt(index)
  local key = selectSlots[index]
  if key ~= nil then
    selectedKey = key
    feedback = ""
    render()
  end
end

local function switchTab(tab)
  currentTab = tab
  selectedKey = ""
  showRunForm = false
  feedback = ""
  render()
end

local function environmentValues()
  local values = {}
  for line in (runEnvironment .. "\n"):gmatch("(.-)\n") do
    line = noctalia.string.trim(line)
    if line ~= "" then
      local key = line:match("^([^=]+)=") or ""
      if key:match("^[A-Za-z_][A-Za-z0-9_]*$") == nil then
        return nil, tr("run_form.invalid_environment", { line = line })
      end
      table.insert(values, line)
    end
  end
  return values, nil
end

noctalia.state.watch("docker_snapshot", function(value)
  if type(value) == "table" then
    local changed = value.revision ~= snapshot.revision
      or value.available ~= snapshot.available
      or value.busy ~= snapshot.busy
      or value.error ~= snapshot.error
    snapshot = value
    if selectedKey ~= "" and selectedItem() == nil then
      selectedKey = ""
    end
    if changed then
      dirty = true
    end
  end
end)

noctalia.state.watch("docker_action_result", function(result)
  if type(result) ~= "table" then return end
  if result.requestId == pendingInspectRequest then
    pendingInspectRequest = nil
    if type(result.exposedPort) == "string" and result.exposedPort ~= "" then
      runPort = result.exposedPort
      runFormGeneration += 1
      dirty = true
    end
    return
  end
  if type(result.requestId) ~= "string" or not result.requestId:match("^panel%-") then return end
  feedback = tostring(result.message or "")
  feedbackError = result.ok ~= true
  if result.requestId == pendingRunRequest and result.ok == true then
    showRunForm = false
    pendingRunRequest = nil
  end
  dirty = true
end)

panel.setWantsSecondTicks(true)

function onOpen(_context)
  sendCommand("refresh")
  render()
end

function update()
  if dirty then
    render()
  end
end

function onCloseClicked() panel.close() end
function onRefresh() sendCommand("refresh") end
function onTabContainers() switchTab("containers") end
function onTabImages() switchTab("images") end
function onTabVolumes() switchTab("volumes") end
function onTabNetworks() switchTab("networks") end

function onStart()
  local item = selectedItem()
  if item then sendCommand("start_container", { id = item.id }) end
end

function onStop()
  local item = selectedItem()
  if item then sendCommand("stop_container", { id = item.id }) end
end

function onRestart()
  local item = selectedItem()
  if item then sendCommand("restart_container", { id = item.id }) end
end

function onRemove()
  local item = selectedItem()
  if not item then return end
  if currentTab == "containers" then
    sendCommand("remove_container", { id = item.id })
  elseif currentTab == "images" then
    sendCommand("remove_image", { id = item.id })
  elseif currentTab == "volumes" then
    sendCommand("remove_volume", { name = item.name })
  else
    sendCommand("remove_network", { id = item.id, name = item.name })
  end
end

function onRunImage()
  local item = selectedItem()
  if not item then return end
  showRunForm = true
  runImage = tostring(item.name or "")
  runName = ""
  runPort = guessPort(runImage)
  runPublishPort = true
  runEnvironment = ""
  runFormError = ""
  runFormGeneration += 1
  chooseDefaultNetwork()
  pendingInspectRequest = sendCommand("inspect_image", { image = runImage })
  render()
end

function onCancelRun()
  showRunForm = false
  runFormError = ""
  render()
end

function onRunNameChange(value) runName = value end
function onRunPortChange(value) runPort = value end
function onRunEnvironmentChange(value) runEnvironment = value end

function onRunNetworkChange(index, _text)
  runNetworkIndex = tonumber(index) or 0
end

function onRunPublishPortChange(value)
  runPublishPort = value == "true"
  render()
end

function onConfirmRun()
  local name = noctalia.string.trim(runName)
  if name ~= "" and name:match("^[%w][%w_.-]*$") == nil then
    runFormError = tr("run_form.invalid_name")
    render()
    return
  end
  local port = runPublishPort and noctalia.string.trim(runPort) or ""
  local portNumber = tonumber(port)
  if port ~= "" and (portNumber == nil or portNumber < 1 or portNumber > 65535 or math.floor(portNumber) ~= portNumber) then
    runFormError = tr("run_form.invalid_port")
    render()
    return
  end
  local environment, err = environmentValues()
  if environment == nil then
    runFormError = err
    render()
    return
  end
  local names = networkNames()
  local network = names[runNetworkIndex + 1] or "bridge"
  runFormError = ""
  pendingRunRequest = sendCommand("run_image", {
    image = runImage,
    name = name,
    network = network,
    port = port,
    environment = environment,
  })
  render()
end

function onSelect0() selectAt(0) end
function onSelect1() selectAt(1) end
function onSelect2() selectAt(2) end
function onSelect3() selectAt(3) end
function onSelect4() selectAt(4) end
function onSelect5() selectAt(5) end
function onSelect6() selectAt(6) end
function onSelect7() selectAt(7) end
function onSelect8() selectAt(8) end
function onSelect9() selectAt(9) end
function onSelect10() selectAt(10) end
function onSelect11() selectAt(11) end
function onSelect12() selectAt(12) end
function onSelect13() selectAt(13) end
function onSelect14() selectAt(14) end
function onSelect15() selectAt(15) end
function onSelect16() selectAt(16) end
function onSelect17() selectAt(17) end
function onSelect18() selectAt(18) end
function onSelect19() selectAt(19) end
function onSelect20() selectAt(20) end
function onSelect21() selectAt(21) end
function onSelect22() selectAt(22) end
function onSelect23() selectAt(23) end
function onSelect24() selectAt(24) end
function onSelect25() selectAt(25) end
function onSelect26() selectAt(26) end
function onSelect27() selectAt(27) end
function onSelect28() selectAt(28) end
function onSelect29() selectAt(29) end
function onSelect30() selectAt(30) end
function onSelect31() selectAt(31) end
