--!nonstrict
-- Printers panel: the CUPS destinations with a "set default" action, the
-- active job queue with per-job and cancel-all actions, and the quick actions
-- (open CUPS, printer settings, print clipboard).

local printers = {}
local jobs = {}
local devices = {}
local showAdd = false
local pendingRemove = nil
local status = { defaultPrinter = "", printerCount = 0, jobCount = 0, hasFault = false }

local pendingCancelAll = false

-- Appends to the command queue rather than overwriting it, so two commands
-- sent in quick succession (cancel job A, then job B) both reach the service
-- instead of the second silently replacing the first.
local function send(cmd)
  local queue = noctalia.state.get("printer.cmd")
  if type(queue) ~= "table" then
    queue = {}
  end
  table.insert(queue, cmd)
  noctalia.state.set("printer.cmd", queue)
end

local function sectionLabel(text)
  return ui.label({ text = text, fontSize = 11, fontWeight = "medium", color = "on_surface_variant" })
end

local function emptyLabel(text)
  return ui.label({ text = text, fontSize = 12, color = "on_surface_variant" })
end

local function printerRow(row)
  local isDefault = row.name == status.defaultPrinter
  local ok = row.enabled
  local stateText = row.discovered and noctalia.tr("panel.discovered") or row.state

  local children = {
    ui.glyph({
      name = ok and "printer" or "printer-off",
      size = 16,
      color = if not ok then "error" elseif row.discovered then "on_surface_variant" else "on_surface",
    }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({
        text = row.name,
        fontSize = 13,
        fontWeight = isDefault and "bold" or "normal",
        maxLines = 1,
      }),
      ui.label({
        text = isDefault and noctalia.tr("panel.state_default", { state = stateText }) or stateText,
        fontSize = 11,
        color = ok and "on_surface_variant" or "error",
        maxLines = 1,
      }),
    }),
  }

  if pendingRemove == row.name then
    table.insert(
      children,
      ui.button({
        key = "remove-yes-" .. row.name,
        glyph = "check",
        variant = "destructive",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.remove_confirm", { printer = row.name }),
        onClick = function()
          pendingRemove = nil
          send({ op = "remove", name = row.name })
        end,
      })
    )
    table.insert(
      children,
      ui.button({
        key = "remove-no-" .. row.name,
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          pendingRemove = nil
          render()
        end,
      })
    )
  else
    if not isDefault then
      table.insert(
        children,
        ui.button({
          key = "default-" .. row.name,
          text = noctalia.tr("panel.set_default"),
          variant = "outline",
          controlSize = "sm",
          onClick = function()
            send({ op = "set_default", name = row.name })
          end,
        })
      )
    end
    if not row.discovered then
      table.insert(
        children,
        ui.button({
          key = "remove-" .. row.name,
          glyph = "trash",
          variant = "ghost",
          controlSize = "sm",
          tooltip = noctalia.tr("panel.remove"),
          onClick = function()
            pendingRemove = row.name
            render()
          end,
        })
      )
    end
  end

  return ui.row({ key = "printer-" .. row.name, gap = 8, align = "center" }, children)
end

local function printersSection()
  local rows = { sectionLabel(noctalia.tr("panel.printers")) }

  if #printers == 0 then
    table.insert(rows, emptyLabel(noctalia.tr("panel.no_printers")))
  else
    for _, row in ipairs(printers) do
      table.insert(rows, printerRow(row))
    end
  end

  return ui.column({ gap = 6 }, rows)
end

local function jobRow(row)
  -- A stuck job is only actionable if you can see why it is stuck, so the
  -- filter chain's own message replaces the user/time line when one arrives.
  local subtitle = row.when ~= "" and `{row.user} · {row.when}` or row.user
  local detail = row.status ~= "" and row.status or ""
  if row.failed and detail == "" then
    detail = row.alerts
  end

  local lines = {
    ui.label({ text = row.id, fontSize = 13, maxLines = 1 }),
    ui.label({
      text = subtitle,
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 1,
    }),
  }
  if detail ~= "" then
    table.insert(
      lines,
      ui.label({
        text = detail,
        fontSize = 11,
        color = row.failed and "error" or "on_surface_variant",
        maxLines = 2,
      })
    )
  end

  return ui.row({ key = "job-" .. row.id, gap = 8, align = "center" }, {
    ui.glyph({
      name = row.failed and "alert-triangle" or "file-description",
      size = 16,
      color = row.failed and "error" or "on_surface",
    }),
    ui.column({ gap = 1, flexGrow = 1 }, lines),
    ui.button({
      key = "cancel-" .. row.id,
      glyph = "x",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.cancel"),
      onClick = function()
        send({ op = "cancel", id = row.id })
      end,
    }),
  })
end

local function queueHeader()
  local children = {
    sectionLabel(noctalia.trp("panel.queue", #jobs, { count = #jobs })),
    ui.spacer({ flexGrow = 1 }),
  }

  if #jobs > 0 then
    if pendingCancelAll then
      table.insert(
        children,
        ui.button({
          glyph = "check",
          variant = "destructive",
          controlSize = "sm",
          tooltip = noctalia.tr("panel.cancel_all_confirm"),
          onClick = function()
            pendingCancelAll = false
            send({ op = "cancel_all" })
          end,
        })
      )
      table.insert(
        children,
        ui.button({
          glyph = "x",
          variant = "ghost",
          controlSize = "sm",
          onClick = function()
            pendingCancelAll = false
            render()
          end,
        })
      )
    else
      table.insert(
        children,
        ui.button({
          text = noctalia.tr("panel.cancel_all"),
          variant = "outline",
          controlSize = "sm",
          onClick = function()
            pendingCancelAll = true
            render()
          end,
        })
      )
    end
  end

  return ui.row({ gap = 6, align = "center" }, children)
end

local function queueSection()
  local rows = { queueHeader() }

  if #jobs == 0 then
    table.insert(rows, emptyLabel(noctalia.tr("panel.no_jobs")))
  else
    for _, row in ipairs(jobs) do
      table.insert(rows, jobRow(row))
    end
  end

  return ui.column({ gap = 6 }, rows)
end


local function deviceRow(row)
  return ui.row({ key = "device-" .. row.uri, gap = 8, align = "center" }, {
    ui.glyph({ name = "plug-connected", size = 16, color = "on_surface_variant" }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = row.info, fontSize = 13, maxLines = 1 }),
      ui.label({
        text = row.alreadyQueued and noctalia.tr("panel.queued_as", { name = row.queuedAs })
          or noctalia.tr("panel.will_be_named", { name = row.suggestedName }),
        fontSize = 11,
        color = "on_surface_variant",
        maxLines = 1,
      }),
    }),
    ui.button({
      key = "add-" .. row.uri,
      text = noctalia.tr("panel.add"),
      variant = "outline",
      controlSize = "sm",
      enabled = not row.alreadyQueued,
      tooltip = row.alreadyQueued and noctalia.tr("panel.already_added") or row.uri,
      onClick = function()
        send({ op = "add", name = row.suggestedName, uri = row.uri })
      end,
    }),
  })
end

local function addSection()
  local rows = {
    ui.row({ gap = 6, align = "center" }, {
      sectionLabel(noctalia.tr("panel.add_printer")),
      ui.spacer({ flexGrow = 1 }),
      ui.button({
        glyph = showAdd and "chevron-up" or "chevron-down",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          showAdd = not showAdd
          -- Tells the service it's worth scanning lpinfo on the next poll;
          -- see wantDevices() in service.luau.
          noctalia.state.set("printer.wantDevices", showAdd)
          if showAdd then
            send({ op = "refresh" })
          end
          render()
        end,
      }),
    }),
  }

  if showAdd then
    if #devices == 0 then
      table.insert(rows, emptyLabel(noctalia.tr("panel.no_devices")))
    else
      for _, row in ipairs(devices) do
        table.insert(rows, deviceRow(row))
      end
    end
    table.insert(rows, ui.label({
      text = noctalia.tr("panel.add_note"),
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 3,
    }))
  end

  return ui.column({ gap = 6 }, rows)
end

local function actionsSection()
  return ui.column({ gap = 6 }, {
    ui.row({ gap = 6 }, {
      ui.button({
        text = noctalia.tr("panel.open_cups"),
        glyph = "external-link",
        variant = "outline",
        controlSize = "sm",
        flexGrow = 1,
        onClick = function()
          send({ op = "open_queue" })
        end,
      }),
      ui.button({
        text = noctalia.tr("panel.printer_settings"),
        glyph = "settings",
        variant = "outline",
        controlSize = "sm",
        flexGrow = 1,
        onClick = function()
          send({ op = "open_settings" })
        end,
      }),
    }),
    ui.button({
      text = noctalia.tr("panel.print_clipboard"),
      glyph = "clipboard",
      variant = "outline",
      controlSize = "sm",
      enabled = status.defaultPrinter ~= "",
      onClick = function()
        send({ op = "print_clipboard" })
      end,
    }),
  })
end

function render()
  panel.render(ui.column({ flexGrow = 1, gap = 10, padding = 10 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.refresh"),
        onClick = function()
          send({ op = "refresh" })
        end,
      }),
      ui.button({
        glyph = "settings",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.plugin_settings"),
        onClick = function()
          noctalia.openSettings()
        end,
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          panel.close()
        end,
      }),
    }),
    ui.scroll({ flexGrow = 1, gap = 12 }, {
      printersSection(),
      ui.separator({}),
      addSection(),
      ui.separator({}),
      queueSection(),
    }),
    actionsSection(),
  }))
end

function onOpen(_context)
  pendingCancelAll = false
  pendingRemove = nil
  showAdd = false
  noctalia.state.set("printer.wantDevices", false)
  devices = noctalia.state.get("printer.devices") or {}
  printers = noctalia.state.get("printer.printers") or {}
  jobs = noctalia.state.get("printer.jobs") or {}
  status = noctalia.state.get("printer.status") or status
  send({ op = "refresh" })
  render()
end

-- Stop the service scanning lpinfo once nobody can see the result.
function onClose()
  noctalia.state.set("printer.wantDevices", false)
end

noctalia.state.watch("printer.printers", function(value)
  printers = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("printer.jobs", function(value)
  jobs = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("printer.devices", function(value)
  devices = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("printer.status", function(value)
  if type(value) == "table" then
    status = value
  end
  render()
end)
