--!nonstrict
-- Panel listing nwg-displays profiles; clicking a row applies it and closes.

local nwg = require("./lib/nwg.luau")

local tr = noctalia.tr

local profiles = {}
local active = nil
local listError = nil
local hovered = nil
local showClose = false

local function displayPath(path)
  local home = noctalia.expandPath("~")
  if path:sub(1, #home) == home then
    return "~" .. path:sub(#home + 1)
  end
  return path
end

local function refresh()
  local names, err = nwg.listProfiles()
  profiles = names or {}
  listError = err
  active = nwg.readActiveProfile()
  noctalia.state.set("active_profile", active or "")
end

local function applyProfile(name)
  -- The callback outlives the panel, so a failure still reaches the user.
  nwg.apply(name, function(ok, err)
    if not ok then
      noctalia.notifyError(tr("notify.apply_failed", { profile = name }), err or "")
    end
  end)
  panel.close()
end

local function profileRow(name)
  local isActive = name == active
  return ui.row({
    key = "profile-" .. name,
    gap = 10,
    align = "center",
    paddingH = 10,
    paddingV = 8,
    radius = 8,
    fill = isActive and "primary/0.15" or (hovered == name and "surface_container/0.5" or nil),
    onClick = function()
      applyProfile(name)
    end,
    onHover = function(state)
      if state == "true" then
        hovered = name
      elseif hovered == name then
        hovered = nil
      end
      render()
    end,
  }, {
    ui.row({ width = 22, height = 22, align = "center", justify = "center" }, {
      ui.glyph({
        name = isActive and "check" or "device-desktop",
        size = 16,
        color = isActive and "primary" or "on_surface_variant",
      }),
    }),
    ui.label({
      text = name,
      flexGrow = 1,
      color = "on_surface",
      fontWeight = isActive and "bold" or nil,
    }),
  })
end

local function body()
  if #profiles == 0 then
    local message
    if listError ~= nil then
      message = tr("panel.no_dir", { path = displayPath(nwg.profilesDir()) })
    else
      message = tr("panel.empty", { path = displayPath(nwg.profilesDir()) })
    end
    return ui.column({ flexGrow = 1, gap = 8, align = "center", justify = "center" }, {
      ui.label({ text = message, color = "on_surface_variant", textAlign = "center" }),
    })
  end

  local rows = {}
  for _, name in ipairs(profiles) do
    table.insert(rows, profileRow(name))
  end
  return ui.scroll({ flexGrow = 1, gap = 4 }, rows)
end

function render()
  local headerContent = {
    ui.label({
      text = tr("panel.title"),
      fontSize = 16,
      fontWeight = "bold",
      color = "on_surface",
      flexGrow = 1,
    }),
    ui.button({
      glyph = "refresh",
      tooltip = tr("panel.refresh"),
      onClick = "onRefreshClicked",
    }),
  }
  if showClose then
    table.insert(headerContent, ui.button({
      glyph = "close",
      tooltip = tr("panel.close"),
      onClick = "onCloseClicked",
    }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    ui.row({ align = "center", gap = 8 }, headerContent),
    body(),
  }))
end

function onOpen(_context)
  showClose = noctalia.getSetting("shell.show_close_buttons") ~= false
  hovered = nil
  refresh()
  render()
end

function onRefreshClicked()
  refresh()
  render()
end

function onCloseClicked()
  panel.close()
end
