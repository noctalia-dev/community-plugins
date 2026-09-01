--!nonstrict
-- Remmina panel — the [[panel]] entry.
--
-- Header with the connection count and a button that opens Remmina's own
-- window, a filter input, then the profiles grouped exactly as Remmina groups
-- them. Clicking a row opens that connection and closes the panel.
--
-- Rows pass a closure that captures their profile, so the list has no length
-- limit and no numbered callback globals.

local shared = require("./shared.luau")

-- Must match height = … in the [[panel]] entry of plugin.toml: the root
-- column's height is what actually sizes the panel content.
local PANEL_HEIGHT = 520

local isOpen = false
local filterText = ""

-- Declared here because the rows' star buttons call it, and render() is built
-- out of those rows.
local render

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function openProfile(profile)
  if not shared.open(profile.path) then
    noctalia.notifyError(tr("title"), tr("err-launch"))
    return
  end
  panel.close()
end

local function profileRow(profile)
  local pinned = shared.isPinned(profile.path)
  local target = shared.targetOf(profile)
  local detail = target
  if profile.protocol ~= "" then
    detail = detail ~= "" and (detail .. " · " .. profile.protocol) or profile.protocol
  end

  return ui.row({
    key = `profile-{profile.path}`,
    gap = 8,
    padding = 8,
    align = "center",
    fill = "surface_variant/0.5",
    radius = 8,
    tooltip = tr("panel.open-tooltip", { name = profile.name }),
    onClick = function()
      openProfile(profile)
    end,
  }, {
    ui.glyph({ name = shared.glyphFor(profile.protocol), size = 16, color = "on_surface/0.7" }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = profile.name, fontWeight = "bold", fontSize = 13, maxLines = 1 }),
      ui.label({ text = detail, fontSize = 11, color = "on_surface/0.65", maxLines = 1 }),
    }),
    -- The star sits inside the clickable row, so it has to swallow the click:
    -- a button consumes it, the row's onClick does not fire underneath.
    ui.button({
      glyph = pinned and "star-filled" or "star",
      variant = "ghost",
      controlSize = "sm",
      tooltip = pinned and tr("panel.unpin-tooltip") or tr("panel.pin-tooltip"),
      onClick = function()
        shared.togglePin(profile.path)
        render()
      end,
    }),
  })
end

local function groupLabel(name)
  return ui.label({
    text = name ~= "" and name or tr("panel.ungrouped"),
    fontSize = 11,
    fontWeight = "bold",
    color = "on_surface/0.55",
  })
end

-- Pinned profiles come first under their own heading and are left out of their
-- own group below, so a connection never shows up twice. The rest arrives
-- sorted by group then name, so a group heading is emitted whenever the group
-- changes rather than by bucketing first.
local function profileList(profiles)
  local rows = {}
  local pinned, rest = shared.partitionPinned(profiles)

  local pinnedShown = false
  for _, profile in ipairs(pinned) do
    if shared.matches(filterText, profile) then
      if not pinnedShown then
        pinnedShown = true
        table.insert(rows, groupLabel(tr("panel.pinned")))
      end
      table.insert(rows, profileRow(profile))
    end
  end

  local currentGroup = nil
  for _, profile in ipairs(rest) do
    if shared.matches(filterText, profile) then
      if profile.group ~= currentGroup then
        currentGroup = profile.group
        table.insert(rows, groupLabel(profile.group))
      end
      table.insert(rows, profileRow(profile))
    end
  end
  if #rows == 0 then
    table.insert(rows, ui.label({
      text = filterText ~= "" and tr("no-profiles-found") or tr("profiles-empty"),
      fontSize = 12,
      color = "on_surface/0.6",
    }))
  end
  return ui.scroll({ gap = 6, flexGrow = 1 }, rows)
end

local function header(count)
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "screen-share", size = 18 }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = tr("title"), fontWeight = "bold", fontSize = 14 }),
      ui.label({
        text = tr("panel.count", { count = count }),
        fontSize = 11,
        color = "on_surface/0.6",
      }),
    }),
    ui.button({
      glyph = "app-window",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.open-remmina"),
      onClick = function()
        if noctalia.runAsync({ "remmina" }) then
          panel.close()
        end
      end,
    }),
  })
end

local function errorBox(message)
  return ui.column({ gap = 8, padding = 10, fill = "error/0.12", radius = 8 }, {
    ui.label({ text = tr("profiles-missing"), fontSize = 12, fontWeight = "bold" }),
    ui.label({ text = message, fontSize = 11, maxLines = 3, color = "on_surface/0.7" }),
  })
end

function render()
  if not isOpen then
    return
  end

  if not noctalia.commandExists("remmina") then
    panel.render(ui.column({ gap = 10, padding = 14, height = PANEL_HEIGHT }, {
      header(0),
      errorBox(tr("err-no-remmina-subtitle")),
    }))
    return
  end

  local profiles, err = shared.profiles(noctalia.getConfig("profiles_path"))
  if profiles == nil then
    panel.render(ui.column({ gap = 10, padding = 14, height = PANEL_HEIGHT }, {
      header(0),
      errorBox(err ~= nil and err or shared.profilesPath(noctalia.getConfig("profiles_path"))),
    }))
    return
  end

  local children = { header(#profiles) }
  if #profiles > 0 then
    table.insert(children, ui.input({
      key = "filter",
      value = filterText,
      placeholder = tr("panel.filter"),
      controlSize = "sm",
      onChange = "onFilter",
    }))
  end
  table.insert(children, profileList(profiles))

  -- height pins the root to the [[panel]] size so the scroll area actually
  -- scrolls instead of growing past the panel background.
  panel.render(ui.column({ gap = 10, padding = 14, height = PANEL_HEIGHT }, children))
end

-- The filter text is deliberately *not* reset here: the input keeps whatever
-- was typed across an open/close (it is the same keyed node), so clearing the
-- state behind it would show an unfiltered list under a stale filter string.
function onOpen(_context)
  isOpen = true
  render()
end

function onClose()
  isOpen = false
end

function onFilter(value)
  filterText = noctalia.string.trim(value)
  render()
end
