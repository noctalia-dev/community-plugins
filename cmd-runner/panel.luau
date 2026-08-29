--!nonstrict
-- Panel entry for Command Runner plugin

local state = noctalia.state.get("cmd_runner_state") or {
  commands = {},
  runningMap = {},
  outputMap = {},
  exitCodeMap = {}
}

-- UI state
local isFormOpen = false
local formGen = 1
local editId = ""
local editName = ""
local editCommand = ""
local editIcon = "terminal"
local editIsSudo = false
local editSudoPassword = ""
local hasPassword = false
local activeLogId = ""

local render

local function tr(key, values)
  return noctalia.tr(key, values)
end

local function sendAction(actData)
  noctalia.state.set("cmd_runner_action", actData)
end

local function openAddForm()
  editId = ""
  editName = ""
  editCommand = ""
  editIcon = "terminal"
  editIsSudo = false
  editSudoPassword = ""
  hasPassword = false
  formGen = formGen + 1
  isFormOpen = true
  render()
end

local function openEditForm(cmd)
  if not cmd then return end
  editId = cmd.id or ""
  editName = cmd.name or ""
  editCommand = cmd.command or ""
  editIcon = cmd.icon or "terminal"
  editIsSudo = cmd.isSudo == true
  editSudoPassword = ""    -- never pre-fill; password lives only in the keyring
  hasPassword = cmd.hasPassword == true
  formGen = formGen + 1
  isFormOpen = true
  render()
end

local function closeForm()
  isFormOpen = false
  render()
end

local function saveForm()
  local trimmedName = noctalia.string.trim(editName)
  local trimmedCmd  = noctalia.string.trim(editCommand)
  if trimmedName == "" or trimmedCmd == "" then return end

  local item = {
    id          = editId ~= "" and editId or ("cmd_" .. tostring(math.random(100000, 999999))),
    name        = trimmedName,
    command     = trimmedCmd,
    icon        = editIcon ~= "" and editIcon or "terminal",
    isSudo      = editIsSudo,
    sudoPassword = editSudoPassword   -- sent to service; service stores in keyring, never on disk
  }

  sendAction({ action = editId ~= "" and "update" or "add", item = item })
  closeForm()
end

-- ── Form UI ──────────────────────────────────────────────────────────────────

local function renderForm()
  local isEditing = editId ~= ""

  local formItems = {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({
        text       = isEditing and tr("panel.edit") or tr("panel.add_button"),
        fontWeight = "bold",
        fontSize   = 14,
        color      = "primary"
      }),
      ui.button({ glyph = "close", variant = "ghost", onClick = function() closeForm() end })
    }),

    ui.column({ gap = 4 }, {
      ui.label({ text = tr("panel.name_label"), fontSize = 12, color = "on_surface_variant" }),
      ui.input({
        key         = "edit_name_" .. tostring(formGen),
        value       = editName,
        placeholder = tr("panel.name_placeholder"),
        onChange    = function(val) editName = val or "" end
      })
    }),

    ui.column({ gap = 4 }, {
      ui.label({ text = tr("panel.cmd_label"), fontSize = 12, color = "on_surface_variant" }),
      ui.input({
        key         = "edit_cmd_" .. tostring(formGen),
        value       = editCommand,
        placeholder = tr("panel.cmd_placeholder"),
        onChange    = function(val) editCommand = val or "" end
      })
    }),

    ui.button({
      text    = editIsSudo and tr("panel.sudo_enabled") or tr("panel.sudo_disabled"),
      variant = editIsSudo and "primary" or "secondary",
      onClick = function()
        editIsSudo = not editIsSudo
        render()
      end
    })
  }

  if editIsSudo then
    local placeholder = isEditing and hasPassword
      and tr("panel.sudo_pass_placeholder_saved")
      or  tr("panel.sudo_pass_placeholder")

    table.insert(formItems, ui.column({ gap = 4 }, {
      ui.label({ text = tr("panel.sudo_pass_label"), fontSize = 12, color = "primary", fontWeight = "bold" }),
      ui.input({
        key         = "edit_pass_" .. tostring(formGen),
        value       = editSudoPassword,
        placeholder = placeholder,
        secret      = true,
        onChange    = function(val) editSudoPassword = val or "" end
      })
    }))
  end

  table.insert(formItems, ui.row({ justify = "end", gap = 8 }, {
    ui.button({ text = tr("panel.cancel_button"), variant = "ghost",   onClick = function() closeForm() end }),
    ui.button({ text = tr("panel.save_button"),   variant = "primary", onClick = function() saveForm() end })
  }))

  return ui.column({ fill = "surface_variant/0.3", radius = 10, padding = 12, gap = 12 }, formItems)
end

-- ── Command card ──────────────────────────────────────────────────────────────

local function renderCommandCard(cmd)
  local runningMap  = (type(state) == "table" and type(state.runningMap)  == "table") and state.runningMap  or {}
  local outputMap   = (type(state) == "table" and type(state.outputMap)   == "table") and state.outputMap   or {}
  local exitCodeMap = (type(state) == "table" and type(state.exitCodeMap) == "table") and state.exitCodeMap or {}

  local isRunning = runningMap[cmd.id] == true
  local hasOutput = outputMap[cmd.id] ~= nil
  local exitCode  = exitCodeMap[cmd.id]
  local isLogOpen = activeLogId == cmd.id

  -- Status glyph
  local statusGlyph = nil
  if isRunning then
    statusGlyph = ui.glyph({ name = "loader-2", size = 14, color = "primary" })
  elseif exitCode == 0 then
    statusGlyph = ui.glyph({ name = "check",    size = 14, color = "success" })
  elseif exitCode ~= nil then
    statusGlyph = ui.glyph({ name = "x",        size = 14, color = "error"   })
  end

  local cardHeader = {
    ui.glyph({ name = cmd.icon or "terminal", size = 16, color = "primary" }),
    ui.label({ text = cmd.name or "", fontWeight = "bold", fontSize = 13, color = "on_surface", flexGrow = 1, maxLines = 1 })
  }
  if cmd.isSudo then
    table.insert(cardHeader, ui.label({ text = "[sudo]", fontSize = 10, color = "primary", fontWeight = "bold" }))
  end
  if statusGlyph then table.insert(cardHeader, statusGlyph) end

  local actionButtons = {
    ui.button({
      text    = isRunning and tr("panel.running") or tr("panel.run_button"),
      glyph   = isRunning and "loader-2" or "player-play",
      variant = "primary",
      enabled = not isRunning,
      onClick = function() sendAction({ action = "run", id = cmd.id }) end
    }),
    ui.button({
      glyph   = "edit",
      text    = tr("panel.edit"),
      variant = "secondary",
      onClick = function() openEditForm(cmd) end
    }),
    ui.button({
      glyph   = "trash",
      variant = "destructive",
      onClick = function()
        sendAction({ action = "delete", id = cmd.id })
        if activeLogId == cmd.id then activeLogId = "" end
        render()
      end
    })
  }

  if hasOutput then
    table.insert(actionButtons, ui.button({
      glyph   = isLogOpen and "chevron-up" or "code",
      text    = tr("panel.logs"),
      variant = "ghost",
      onClick = function()
        activeLogId = isLogOpen and "" or cmd.id
        render()
      end
    }))
  end

  local cardItems = {
    ui.row({ align = "center", gap = 8 }, cardHeader),
    ui.label({ text = cmd.command or "", fontSize = 11, color = "on_surface_variant", maxLines = 2 }),
    ui.row({ align = "center", gap = 6, justify = "end" }, actionButtons)
  }

  if isLogOpen and hasOutput then
    local outText  = outputMap[cmd.id] or ""
    local logLines = {}
    if exitCode == 0 then
      table.insert(logLines, ui.label({ text = tr("panel.status_success"), fontSize = 10, color = "success", fontWeight = "bold" }))
    elseif exitCode ~= nil then
      table.insert(logLines, ui.label({ text = tr("panel.status_failed", { code = tostring(exitCode) }), fontSize = 10, color = "error", fontWeight = "bold" }))
    end
    table.insert(logLines, ui.label({ text = outText, fontSize = 10, color = "on_surface_variant", maxLines = 12 }))
    table.insert(cardItems, ui.column({ fill = "surface_variant/0.5", radius = 6, padding = 8, gap = 4 }, logLines))
  end

  return ui.column({ fill = "surface_variant/0.25", radius = 8, padding = 10, gap = 8 }, cardItems)
end

-- ── Root render ───────────────────────────────────────────────────────────────

render = function()
  local commands = (type(state) == "table" and type(state.commands) == "table") and state.commands or {}
  local children = {}

  -- Row 1: icon · title · close
  table.insert(children, ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = "terminal", size = 18, color = "primary" }),
    ui.label({ text = tr("panel.title"), fontSize = 15, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
    ui.button({ glyph = "close", variant = "ghost", onClick = function() panel.close() end })
  }))

  -- Row 2: subtitle · add button (hidden when form is open)
  if not isFormOpen then
    table.insert(children, ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.column({ flexGrow = 1, overflow = "hidden" }, {
        ui.label({ text = tr("panel.subtitle"), fontSize = 10, color = "on_surface_variant", maxLines = 1 })
      }),
      ui.button({ glyph = "plus", text = tr("panel.add_button"), variant = "primary", onClick = function() openAddForm() end })
    }))
  end

  if isFormOpen then
    table.insert(children, renderForm())
  elseif #commands == 0 then
    table.insert(children, ui.column({ align = "center", gap = 12, padding = 32 }, {
      ui.glyph({ name = "terminal", size = 42, color = "on_surface_variant" }),
      ui.label({ text = tr("panel.no_commands"), color = "on_surface_variant", fontSize = 13 }),
      ui.button({ glyph = "plus", text = tr("panel.add_button"), variant = "primary", onClick = function() openAddForm() end })
    }))
  else
    local cardList = {}
    for _, cmd in ipairs(commands) do
      table.insert(cardList, renderCommandCard(cmd))
    end
    table.insert(children, ui.scroll({ flexGrow = 1, gap = 8 }, cardList))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 4 }, children))
end

-- ── State & lifecycle ─────────────────────────────────────────────────────────

noctalia.state.watch("cmd_runner_state", function(val)
  if type(val) == "table" then
    state = val
    render()
  end
end)

function onOpen()
  render()
end
