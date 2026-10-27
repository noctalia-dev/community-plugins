--!nonstrict
-- rbw-enhanced panel — the [[panel]] entry.
--
-- The vault state and how it unlocks, then the actions: open rbw tui,
-- unlock or lock, sync, and the security settings (rbw tui --settings).
-- Everything runs in the service; the panel only sends commands.

-- Must match height = … in the [[panel]] entry of plugin.toml
local PANEL_HEIGHT = 285

local snapshot = nil
local isOpen = false

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function sendCmd(action)
  noctalia.state.set("rbw.cmd", noctalia.json.encode({
    n = `{noctalia.nowMs()}-{math.random(1, 1e9)}`,
    action = action,
  }))
end

local function stateOf()
  return snapshot and snapshot.state or "stopped"
end

local GLYPHS = {
  unlocked = { "lock-open", "primary" },
  locked = { "lock", "on_surface" },
  stopped = { "lock", "on_surface/0.6" },
  expired = { "lock-exclamation", "error" },
  ["logged-out"] = { "lock-off", "error" },
  ["not-installed"] = { "lock-off", "outline_variant" },
  error = { "alert-triangle", "error" },
}

-- "synced 5 min ago"
local function syncedText()
  if not snapshot or not snapshot.lastSync then
    return tr("panel.never-synced")
  end
  local age = math.max(0, os.time() - snapshot.lastSync)
  if age < 60 then
    return tr("panel.synced-now")
  elseif age < 3600 then
    return tr("panel.synced-minutes", { value = math.floor(age / 60) })
  elseif age < 86400 then
    return tr("panel.synced-hours", { value = math.floor(age / 3600) })
  end
  return tr("panel.synced-days", { value = math.floor(age / 86400) })
end

-- how the next unlock will go: "PIN or system authentication", …
local function unlockText()
  if not snapshot then
    return ""
  end
  if snapshot.systemAuth and snapshot.pin then
    return tr("panel.unlock-with-both")
  elseif snapshot.systemAuth then
    return tr("panel.unlock-with-system")
  elseif snapshot.pin then
    return tr("panel.unlock-with-pin")
  end
  return tr("panel.unlock-with-password")
end

-- the state as a small colored pill next to the title
local CHIP = {
  unlocked = { "primary/0.18", "primary" },
  expired = { "error/0.15", "error" },
  ["logged-out"] = { "error/0.15", "error" },
  error = { "error/0.15", "error" },
}

local function chip(state)
  local c = CHIP[state] or { "surface_container", "on_surface/0.8" }
  return ui.row({ padding = 4, radius = 8, fill = c[1] }, {
    ui.label({ text = tr(`state.{state}`), fontSize = 11, fontWeight = "bold", color = c[2] }),
  })
end

local function header()
  local state = stateOf()
  local g = GLYPHS[state] or GLYPHS.error
  local account = snapshot and snapshot.email
  if account and snapshot.server then
    account = `{account} · {snapshot.server}`
  end
  local lines = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Bitwarden", fontWeight = "bold", fontSize = 15 }),
      chip(state),
    }),
  }
  if account then
    table.insert(lines, ui.label({ text = account, fontSize = 11, color = "on_surface/0.7", maxLines = 1 }))
  end
  if state == "error" and snapshot and snapshot.detail then
    table.insert(lines, ui.label({ text = snapshot.detail, fontSize = 11, color = "error", maxLines = 3 }))
  elseif state ~= "not-installed" then
    table.insert(lines, ui.label({ text = syncedText(), fontSize = 11, color = "on_surface/0.6" }))
  end
  return ui.row({ gap = 12, align = "center" }, {
    ui.column({ width = 44, height = 44, radius = 22, fill = "surface_container", align = "center", justify = "center" }, {
      ui.glyph({ name = g[1], size = 22, color = g[2] }),
    }),
    ui.column({ gap = 2, flexGrow = 1 }, lines),
  })
end

-- how the vault opens: at login, and for the tui
local function securityBox()
  if not snapshot or snapshot.state == "not-installed" then
    return nil
  end
  local unlock
  if snapshot.autoUnlock then
    unlock = tr("panel.unlock-auto")
  else
    unlock = unlockText()
  end
  local row = function(glyph, text)
    return ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = glyph, size = 14, color = "on_surface/0.6" }),
      ui.label({ text = text, fontSize = 11, color = "on_surface/0.8", maxLines = 2, flexGrow = 1 }),
    })
  end
  return ui.column({ gap = 6, padding = 10, radius = 10, fill = "surface_container/0.5" }, {
    row("key", unlock),
    row("terminal-2", tr(snapshot.tuiAuth and "panel.tui-auth" or "panel.tui-open")),
  })
end

local function actions()
  local state = stateOf()
  if state == "not-installed" then
    return ui.label({ text = tr("panel.not-installed"), color = "on_surface/0.7", maxLines = 4 })
  end
  if state == "expired" or state == "logged-out" then
    return ui.column({ gap = 8 }, {
      ui.label({ text = tr(`panel.{state}-hint`), color = "on_surface/0.7", maxLines = 3 }),
      ui.button({ text = tr("panel.login"), glyph = "login", variant = "primary", onClick = "onLogin" }),
    })
  end

  local unlocked = state == "unlocked"
  -- all the same weight: the right click on the bar already opens the vault
  local children = {
    ui.row({ gap = 8 }, {
      ui.button({ text = tr("panel.open"), glyph = "terminal-2", flexGrow = 1, onClick = "onTui" }),
      ui.button({ text = tr("panel.settings"), glyph = "shield-lock", flexGrow = 1, onClick = "onSettings" }),
    }),
    ui.row({ gap = 8 }, {
      ui.button({
        text = tr(unlocked and "panel.lock" or "panel.unlock"),
        glyph = unlocked and "lock" or "lock-open",
        flexGrow = 1,
        onClick = unlocked and "onLock" or "onUnlock",
      }),
      ui.button({
        text = tr("panel.sync"),
        glyph = "refresh",
        flexGrow = 1,
        enabled = unlocked,
        tooltip = if unlocked then nil else tr("panel.sync-locked"),
        onClick = "onSync",
      }),
    }),
  }
  return ui.column({ gap = 8 }, children)
end

local function render()
  if not isOpen then
    return
  end
  local children = { header() }
  local box = securityBox()
  if box then
    table.insert(children, box)
  end
  table.insert(children, actions())
  panel.render(ui.column({ gap = 14, padding = 16, height = PANEL_HEIGHT }, children))
end

noctalia.state.watch("rbw.snapshot", function(encoded)
  snapshot = encoded and noctalia.json.decode(encoded) or nil
  render()
end)

function onOpen(_context)
  isOpen = true
  local encoded = noctalia.state.get("rbw.snapshot")
  snapshot = encoded and noctalia.json.decode(encoded) or nil
  render()
  sendCmd("refresh")
end

function onClose()
  isOpen = false
end

function onTui()
  sendCmd("tui")
  panel.close()
end

function onSettings()
  sendCmd("settings")
  panel.close()
end

function onUnlock()
  sendCmd("unlock")
  panel.close()
end

function onLock()
  sendCmd("lock")
end

function onSync()
  sendCmd("sync")
end

function onLogin()
  sendCmd("login")
  panel.close()
end
