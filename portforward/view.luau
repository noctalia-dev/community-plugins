--!nonstrict
local M = {}

function M.start(compact)
  local editor = require("./editor.luau")
  local cards = require("./cards.luau")
  local tr = noctalia.tr
  local snapshot = noctalia.state.get("snapshot") or { profiles = {} }
  local busy = noctalia.state.get("busy") or false
  local expanded, pendingDelete, form, logText = nil, nil, nil, nil
  local copied, copiedUntil, detailProfile = nil, 0, nil
  local sequence = 0
  local pending = nil
  local render

  local function backToProfiles()
    form, logText = nil, nil
    render()
  end

  local function request(args, kind)
    if busy then return end
    sequence += 1
    pending = { token = (compact and "compact:" or "panel:") .. os.time() .. ":" .. sequence, kind = kind }
    busy = true
    noctalia.state.set("request", { token = pending.token, args = args })
    render()
  end

  local function newMapping(key, mapping)
    mapping = mapping or {}
    return { key = key, local_port = mapping.local_port and tostring(mapping.local_port) or "",
      remote_host = mapping.remote_host or "localhost",
      remote_port = mapping.remote_port and tostring(mapping.remote_port) or "", scheme = mapping.scheme or "http" }
  end

  local function edit(profile)
    pendingDelete = nil
    sequence += 1
    form = { session = tostring(sequence), id = profile and profile.id or "p-" .. os.time() .. "-" .. math.random(10000, 99999),
      existing = profile ~= nil, live = profile and (profile.state == "connected" or profile.state == "connecting" or profile.state == "reconnecting"),
      name = profile and profile.name or "", host = profile and profile.host or "", mappings = {} }
    if profile then
      for index, mapping in ipairs(profile.mappings) do table.insert(form.mappings, newMapping(index, mapping)) end
    else
      table.insert(form.mappings, newMapping(1))
    end
    form.nextKey = #form.mappings + 1
    render()
  end

  local function saveForm()
    if not editor.validate(form) then render(); return end
    local mappings = {}
    for _, mapping in ipairs(form.mappings) do
      table.insert(mappings, { local_port = tonumber(mapping.local_port) or 0,
        remote_host = mapping.remote_host, remote_port = tonumber(mapping.remote_port) or 0, scheme = mapping.scheme })
    end
    local value = { id = form.id, name = form.name, host = form.host, mappings = mappings }
    request({ "put", noctalia.json.encode(value) }, "save")
  end

  local function resolveHost()
    if form.host == "" then form.hostError = tr("editor.host_required"); render(); return end
    busy = true
    render()
    local accepted = noctalia.runAsync({ noctalia.expandPath("~/.local/bin/portforward"), "resolve", form.host }, function(result)
      busy = false
      if not form then return end
      if result.exitCode ~= 0 then form.hostError = result.stderr; render(); return end
      local settings = noctalia.json.decode(result.stdout)
      if settings then
        form.resolved = (settings.user or "") .. " @ " .. (settings.hostname or "") .. " · SSH " .. (settings.port or "22")
        if settings.proxyjump then form.resolved ..= " · " .. settings.proxyjump end
        form.hostError = nil
      else
        form.error = tr("backend.invalid")
      end
      render()
    end)
    if not accepted then busy = false; form.error = tr("backend.failed"); render() end
  end

  local function logs(profile)
    logText = ""
    detailProfile = profile
    busy = true
    render()
    local accepted = noctalia.runAsync({ noctalia.expandPath("~/.local/bin/portforward"), "logs", profile.id }, function(result)
      busy = false
      logText = result.exitCode == 0 and result.stdout or result.stderr
      render()
    end)
    if not accepted then busy = false; logText = tr("backend.failed"); render() end
  end

  local function profileCard(profile)
    local active = profile.state == "connected" or profile.state == "connecting" or profile.state == "reconnecting"
    return cards.render(profile, {
      expanded = expanded == profile.id, pendingDelete = pendingDelete == profile.id,
      copied = copied, busy = busy,
    }, {
      expand = function()
        if expanded == profile.id then expanded = nil else expanded = profile.id end
        pendingDelete = nil
        render()
      end,
      edit = function() edit(profile) end,
      details = function() logs(profile) end,
      delete = function() pendingDelete = profile.id; render() end,
      cancelDelete = function() pendingDelete = nil; render() end,
      confirmDelete = function() request({ "delete", profile.id }, "delete") end,
      control = function() pendingDelete = nil; request({ active and "disconnect" or "connect", profile.id }, "control") end,
      open = function(port) request({ "open", profile.id, tostring(port) }, "control") end,
      copy = function(port, address)
        if noctalia.copyToClipboard(address, "text/plain") then
          copied, copiedUntil = profile.id .. ":" .. port, noctalia.nowMs() + 1800
          panel.setWantsSecondTicks(true)
          render()
        else
          noctalia.notifyError(tr("title"), tr("copy_failed"))
        end
      end,
    })
  end

  function render()
    if form then
      panel.render(editor.render(form, busy, {
        changed = function() render() end,
        cancel = backToProfiles, save = saveForm, resolve = resolveHost,
        addPort = function()
          table.insert(form.mappings, newMapping(form.nextKey)); form.nextKey += 1; render()
        end,
        removePort = function(index) table.remove(form.mappings, index); render() end,
      }))
      return
    end
    if logText then
      panel.render(ui.column({ key = "details", flexGrow = 1, gap = 12, paddingH = 16, paddingV = 14 }, {
        ui.row({ gap = 8, align = "center" }, {
          ui.button({ key = "details-back", glyph = "arrow-left", tooltip = tr("back"), variant = "ghost",
            enabled = true, onClick = backToProfiles }),
          ui.label({ text = tr("details"), fontSize = 17, fontWeight = "medium" }),
        }),
        ui.scroll({ flexGrow = 1 }, { ui.column({ gap = 12 }, {
          ui.label({ text = detailProfile.name, fontSize = 15, fontWeight = "semibold" }),
          ui.label({ text = detailProfile.error or "", color = "on_surface_variant", fontSize = 12, visible = detailProfile.error ~= "" }),
          ui.label({ text = tr("logs"), fontWeight = "medium" }),
          ui.label({ text = logText, fontSize = 12, fontFamily = "monospace" }),
        }) }),
      }))
      return
    end
    local profiles = {}
    for _, profile in ipairs(snapshot.profiles or {}) do table.insert(profiles, profileCard(profile)) end
    if snapshot.error then table.insert(profiles, ui.label({ text = snapshot.error, color = "error" })) end
    if #profiles == 0 then
      table.insert(profiles, ui.column({ paddingV = 30, gap = 12, align = "center" }, {
        ui.glyph({ name = "arrows-left-right", size = 30, color = "on_surface_variant" }),
        ui.label({ text = tr("empty_title"), fontSize = 15, fontWeight = "medium" }),
        ui.label({ text = tr("empty"), fontSize = 12, color = "on_surface_variant", textAlign = "center" }),
        ui.button({ text = tr("add_profile"), glyph = "plus", variant = "primary", onClick = function() edit(nil) end }),
      }))
    end
    panel.render(ui.column({ key = "profiles", flexGrow = 1, gap = 0 }, {
      ui.row({ gap = 8, align = "center", paddingH = 16, paddingV = 12 }, {
        ui.glyph({ name = "arrows-left-right", size = 20, color = "on_surface_variant" }),
        ui.label({ text = tr("title"), fontSize = 17, fontWeight = "medium", flexGrow = 1 }),
        ui.button({ glyph = "plus", tooltip = tr("add_profile"), variant = "ghost", width = 32, controlSize = "sm",
          enabled = not busy, onClick = function() edit(nil) end }),
        ui.button({ glyph = "x", tooltip = tr("close"), variant = "ghost", width = 32, controlSize = "sm", onClick = function() panel.close() end }),
      }),
      ui.scroll({ flexGrow = 1 }, { ui.column({ gap = 10, paddingH = 16, paddingV = 4 }, profiles) }),
    }))
  end

  local function onOpen()
    noctalia.state.set("visible_panel", "ghillb/portforward:" .. (compact and "compact" or "panel"))
    pendingDelete, copied = nil, nil
    local profiles = snapshot.profiles or {}
    expanded = #profiles == 1 and profiles[1].id or nil
    panel.setWantsSecondTicks(false)
    noctalia.state.set("refresh", os.time())
    render()
  end

  local function onClose()
    noctalia.state.set("visible_panel", nil)
  end

  local function update()
    if copied and noctalia.nowMs() >= copiedUntil then
      copied = nil
      panel.setWantsSecondTicks(false)
      render()
    end
  end

  noctalia.state.watch("snapshot", function(value)
    local previousCount = #(snapshot.profiles or {})
    snapshot = value or snapshot
    local profiles = snapshot.profiles or {}
    if #profiles == 1 and previousCount ~= 1 then expanded = profiles[1].id end
    if #profiles == 0 then expanded = nil end
    render()
  end)
  noctalia.state.watch("busy", function(value) busy = value or false; render() end)
  noctalia.state.watch("result", function(result)
    if not pending or result.token ~= pending.token then return end
    if result.ok then
      if pending.kind == "save" then expanded = form.id; form = nil end
      if pending.kind == "delete" then expanded = nil end
      pendingDelete = nil
    elseif form then
      form.error = result.error
    elseif pending.kind ~= "control" or string.find(result.error or "", "Cannot listen", 1, true) == nil then
      noctalia.notifyError(tr("title"), result.error)
    end
    pending = nil
    render()
  end)
  render()
  return { onOpen = onOpen, onClose = onClose, update = update }
end

return M
