--!nonstrict
-- USB Manager panel — the [[panel]] entry.
--
-- Header with the drive count and the mount-all / remove-all / refresh
-- buttons, then one card per drive: name, size, USB link speed, a single
-- "remove safely" action that does what the drive supports (power off a USB
-- drive, eject a card or a disc), and one row per volume with its usage bar
-- and open / copy / mount or unlock actions. Encrypted volumes ask for the
-- passphrase inline.

local shared = require("./shared.luau")

-- Up to this many drives and volumes the panel grows with its content and
-- never scrolls; beyond, the list scrolls inside SCROLL_HEIGHT, which keeps
-- the panel within max_height = 640 of the [[panel]] entry (header included).
local MAX_UNSCROLLED_DRIVES = 3
local MAX_UNSCROLLED_VOLUMES = 6
local SCROLL_HEIGHT = 540

local snapshot = nil
local isOpen = false
local unlocking = nil -- device path of the volume asking for its passphrase
local passphrase = ""

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function drives()
  return snapshot and snapshot.drives or {}
end

local function pendingOf(dev)
  return snapshot and snapshot.pending and snapshot.pending[dev] or nil
end

-- Every prop is always set: rows are rebuilt in place, and a button that
-- takes the slot of a disabled one would otherwise keep it disabled.
local function iconButton(glyph, tooltip, onClick, opts)
  local props = {
    key = glyph,
    enabled = true,
    glyph = glyph,
    variant = "ghost",
    controlSize = "sm",
    tooltip = tooltip,
    onClick = onClick,
  }
  for key, value in opts or {} do
    props[key] = value
  end
  return ui.button(props)
end

-- A nil in the middle of an array literal would cut the siblings after it.
local function compact(list)
  local out = {}
  for _, node in list do
    if node then
      table.insert(out, node)
    end
  end
  return out
end

-- ── Sections ─────────────────────────────────────────────────────────────────

local function header()
  local list = drives()
  local count = #list
  local mounted = shared.mountedCount(list)
  local subtitle
  if count == 0 then
    subtitle = tr("panel.empty")
  else
    subtitle = count == 1 and tr("panel.count-one") or tr("panel.count", { count = count })
    if mounted > 0 then
      subtitle ..= ` · {(mounted == 1 and tr("panel.mounted-count-one") or tr("panel.mounted-count", { count = mounted }))}`
    end
  end
  local anyUnmounted = false
  for _, drive in list do
    for _, volume in drive.volumes do
      if not volume.luks and not volume.mountPoint then
        anyUnmounted = true
      end
    end
  end
  -- Actions that have nothing to act on are left out rather than shown
  -- disabled: a greyed icon reads as broken.
  return ui.row({ gap = 8, align = "center" }, compact({
    ui.glyph({ name = "usb", size = 20, color = count > 0 and "primary" or "on_surface/0.5" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold" }),
      ui.label({ text = subtitle, fontSize = 12, color = mounted > 0 and "primary" or "on_surface/0.65" }),
    }),
    anyUnmounted and iconButton("folders", tr("panel.mount-all"), function()
      shared.sendCmd("mount_all")
    end) or nil,
    count > 0 and iconButton("plug-x", tr("panel.remove-all"), function()
      shared.sendCmd("remove_all")
    end) or nil,
    iconButton("settings", tr("panel.settings"), function()
      noctalia.openSettings()
    end),
    ui.button({
      glyph = "refresh",
      variant = "outline",
      controlSize = "sm",
      tooltip = tr("panel.refresh"),
      onClick = function()
        shared.sendCmd("refresh")
      end,
    }),
  }))
end

local function emptyState()
  return ui.column({ gap = 6, padding = 18, align = "center", fill = "surface_container/0.5", radius = 10 }, {
    ui.glyph({ name = "usb", size = 28, color = "on_surface/0.35" }),
    ui.label({ text = tr("panel.empty"), fontSize = 13, fontWeight = "bold", color = "on_surface/0.75" }),
    ui.label({ text = tr("panel.empty-hint"), fontSize = 11, color = "on_surface/0.55" }),
  })
end

local function badge(text, color)
  return ui.row({ paddingH = 6, paddingV = 1, radius = 6, fill = `{color}/0.15`, align = "center" }, {
    ui.label({ text = text, fontSize = 10, fontWeight = "bold", color = color }),
  })
end

local function passphraseRow(volume, title)
  return ui.row({ gap = 6, align = "center" }, {
    ui.input({
      key = `pass-{volume.dev}`,
      value = "",
      password = true,
      focus = true,
      placeholder = tr("panel.passphrase", { name = title }),
      controlSize = "sm",
      flexGrow = 1,
      onChange = function(value)
        passphrase = value
      end,
      onSubmit = function()
        if passphrase ~= "" then
          shared.sendCmd("unlock", { dev = volume.dev, passphrase = passphrase })
          passphrase = ""
          unlocking = nil
          render()
        end
      end,
    }),
    ui.button({
      text = tr("panel.unlock"),
      variant = "primary",
      controlSize = "sm",
      onClick = function()
        if passphrase ~= "" then
          shared.sendCmd("unlock", { dev = volume.dev, passphrase = passphrase })
          passphrase = ""
          unlocking = nil
          render()
        end
      end,
    }),
    iconButton("x", tr("panel.cancel"), function()
      passphrase = ""
      unlocking = nil
      render()
    end),
  })
end

local function volumeRow(volume, drive)
  local name = shared.volumeName(volume) or tr("panel.unnamed")
  local mounted = volume.mountPoint ~= nil
  local busy = pendingOf(volume.dev) or (volume.clear and pendingOf(volume.clear.dev))
  local locked = volume.luks and not volume.unlocked
  local fsType = volume.luks and (volume.clear and volume.clear.fsType ~= "" and volume.clear.fsType or "LUKS")
    or volume.fsType

  local dot = mounted and "primary" or (locked and "tertiary" or "outline_variant")
  local status
  if busy then
    status = tr(`panel.pending-{busy}`)
  elseif mounted then
    status = volume.mountPoint
  elseif locked then
    status = tr("panel.encrypted")
  else
    status = tr("panel.not-mounted")
  end

  local actions = {}
  if mounted then
    table.insert(actions, iconButton("folder-open", tr("panel.open"), function()
      shared.sendCmd("open", { dev = volume.dev })
    end))
    table.insert(actions, iconButton("copy", tr("panel.copy-path"), function()
      noctalia.copyToClipboard(volume.mountPoint, "text/plain")
      noctalia.notify(tr("title"), `{tr("panel.copied")}: {volume.mountPoint}`)
    end))
  end
  if volume.luks then
    if locked then
      table.insert(actions, iconButton("lock-open", tr("panel.unlock"), function()
        unlocking = volume.dev
        passphrase = ""
        render()
      end, { enabled = not busy }))
    else
      if not mounted and volume.clear then
        table.insert(actions, iconButton("player-play", tr("panel.mount"), function()
          shared.sendCmd("mount", { dev = volume.clear.dev })
        end, { enabled = not busy }))
      end
      table.insert(actions, iconButton("lock", tr("panel.lock"), function()
        shared.sendCmd("lock", { dev = volume.dev })
      end, { enabled = not busy }))
    end
  elseif mounted then
    table.insert(actions, iconButton("player-eject", tr("panel.unmount"), function()
      shared.sendCmd("unmount", { dev = volume.dev })
    end, { enabled = not busy }))
  else
    table.insert(actions, iconButton("player-play", tr("panel.mount"), function()
      shared.sendCmd("mount", { dev = volume.dev })
    end, { enabled = not busy }))
  end

  local titleRow = ui.row({ gap = 6, align = "center" }, compact({
    ui.label({ text = name, fontWeight = "bold", fontSize = 13, maxLines = 1 }),
    fsType ~= "" and badge(fsType, "secondary") or nil,
    volume.luks and badge(volume.unlocked and tr("panel.unlocked") or tr("panel.locked"), "tertiary") or nil,
    volume.readOnly and badge(tr("panel.read-only"), "error") or nil,
  }))

  local info = { titleRow, ui.label({ text = status, fontSize = 11, color = busy and "tertiary" or "on_surface/0.65", maxLines = 1 }) }
  if mounted and volume.total then
    local fraction = math.clamp((volume.used or 0) / volume.total, 0, 1)
    table.insert(info, ui.progress({
      progress = fraction,
      fill = fraction > 0.9 and "error" or "primary",
      track = "on_surface/0.12",
      height = 4,
      radius = 2,
    }))
    table.insert(info, ui.label({
      text = tr("panel.free", { free = shared.formatBytes(volume.free), total = shared.formatBytes(volume.total) }),
      fontSize = 10,
      color = "on_surface/0.55",
    }))
  elseif not mounted then
    table.insert(info, ui.label({ text = shared.formatBytes(volume.size), fontSize = 10, color = "on_surface/0.55" }))
  end

  local row = { ui.box({ width = 8, height = 8, radius = 4, fill = dot }), ui.column({ gap = 3, flexGrow = 1 }, info) }
  for _, action in actions do
    table.insert(row, action)
  end

  local children = { ui.row({ gap = 8, align = "center" }, row) }
  if unlocking == volume.dev then
    table.insert(children, passphraseRow(volume, name))
  end
  return ui.column({
    key = `vol-{volume.dev}`,
    gap = 8,
    padding = 8,
    radius = 8,
    fill = "surface_container_high/0.6",
  }, children)
end

local function driveCard(drive)
  local busyAction = pendingOf(drive.dev)
  local details = { shared.formatBytes(drive.size) }
  if drive.noMedia then
    details = { tr("panel.no-media") }
  end
  local speed = shared.usbSpeed(drive.usb)
  if speed then
    table.insert(details, speed)
  elseif drive.bus ~= "usb" then
    table.insert(details, tr(`bus.{drive.bus}`))
  end
  if drive.readOnly then
    table.insert(details, tr("panel.read-only"))
  end

  local removeHint = drive.canPowerOff and tr("panel.power-off-hint")
    or (drive.canEject and tr("panel.eject-hint") or tr("panel.release-hint"))

  local subtitle = table.concat(details, " · ")
  local subtitleColor = "on_surface/0.65"
  if busyAction then
    subtitle = tr(`panel.pending-{busyAction}`)
    subtitleColor = "tertiary"
  elseif drive.busy then
    subtitle = `{subtitle} · {tr("panel.busy")}`
    subtitleColor = "tertiary"
  end

  local head = ui.row({ gap = 10, align = "center" }, {
    ui.row({ width = 34, height = 34, radius = 10, fill = "primary/0.14", align = "center", justify = "center" }, {
      ui.glyph({ name = shared.driveGlyph(drive), size = 18, color = "primary" }),
    }),
    -- the title is cut when the remove button is wide (longer translations):
    -- the tooltip keeps the full name, with the serial to tell twins apart
    ui.column({
      gap = 2,
      flexGrow = 1,
      tooltip = drive.serial ~= "" and `{drive.title} · {drive.serial}` or drive.title,
    }, {
      ui.label({ text = drive.title, fontWeight = "bold", fontSize = 14, maxLines = 1 }),
      ui.label({ text = subtitle, fontSize = 11, color = subtitleColor, maxLines = 1 }),
    }),
    ui.button({
      text = tr("panel.remove"),
      glyph = drive.canEject and not drive.canPowerOff and "player-eject" or "plug-x",
      variant = "outline",
      controlSize = "sm",
      tooltip = removeHint,
      enabled = busyAction == nil,
      onClick = function()
        shared.sendCmd("remove", { dev = drive.dev })
      end,
    }),
  })

  local children = { head }
  for _, volume in drive.volumes do
    table.insert(children, volumeRow(volume, drive))
  end
  return ui.column({
    key = `drive-{drive.dev}`,
    gap = 8,
    padding = 10,
    radius = 10,
    fill = "surface_container/0.5",
    opacity = busyAction == "remove" and 0.7 or 1,
  }, children)
end

function render()
  if not isOpen then
    return
  end
  local list = drives()
  local cards = {}
  if #list == 0 then
    table.insert(cards, emptyState())
  else
    for _, drive in list do
      table.insert(cards, driveCard(drive))
    end
  end
  -- The panel takes the height of its content, so up to a few drives the
  -- cards sit in a plain column and nothing scrolls. Past that the list gets a
  -- fixed height inside a scroll view: a scroll view has no natural height of
  -- its own, so it cannot share a content-sized panel with a growing list.
  local volumes = 0
  for _, drive in list do
    volumes += #drive.volumes
  end
  local body
  if #list <= MAX_UNSCROLLED_DRIVES and volumes <= MAX_UNSCROLLED_VOLUMES then
    body = ui.column({ gap = 8 }, cards)
  else
    body = ui.scroll({ gap = 8, height = SCROLL_HEIGHT }, cards)
  end
  panel.render(ui.column({ gap = 10, padding = 14 }, { header(), body }))
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

noctalia.state.watch("usbm.snapshot", function(encoded)
  snapshot = encoded and noctalia.json.decode(encoded) or nil
  if unlocking then
    -- the volume went away or was unlocked elsewhere: drop the prompt
    local still = false
    for _, drive in drives() do
      for _, volume in drive.volumes do
        if volume.dev == unlocking and volume.luks and not volume.unlocked then
          still = true
        end
      end
    end
    if not still then
      unlocking = nil
      passphrase = ""
    end
  end
  render()
end)

function onOpen(_context)
  isOpen = true
  snapshot = shared.snapshot()
  render()
  shared.sendCmd("refresh")
end

function onClose()
  isOpen = false
  unlocking = nil
  passphrase = ""
end
