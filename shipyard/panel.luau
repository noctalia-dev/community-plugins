--!nonstrict
-- Docker & Podman Shipyard Panel
-- Native declarative UI matching Noctalia v5 theming and design tokens.

local KEY_SNAPSHOT   = "shipyard_snapshot"
local KEY_COMMAND    = "shipyard_command"
local KEY_PANEL_OPEN = "shipyard_panel_open"

-- Panel-local state
local currentTab            = "stacks"
local showCloseButton       = true
local containerSearch       = ""
local imageSearch           = ""
local imageSubView          = "local"
local onlineSearchInput     = ""
local launchModalImage      = nil
local launchNameInput       = ""
local launchPortInput       = ""
local launchEnvInput        = ""
local confirmPending        = nil
local cmdNonce              = 0
local render

local function tr(key, params)
  return noctalia.tr(key, params)
end

local function openPluginSettings()
  if type(noctalia.openSettings) == "function" then
    local ok = pcall(noctalia.openSettings, "ishan0121/shipyard")
    if ok then return end
    local ok2 = pcall(noctalia.openSettings)
    if ok2 then return end
  end
  noctalia.runAsync("noctalia msg settings-open-plugin ishan0121/shipyard")
end

local function sendCommand(action, payload)
  cmdNonce += 1
  local cmd = { action = action, _n = cmdNonce }
  if type(payload) == "table" then
    for k, v in pairs(payload) do cmd[k] = v end
  end
  noctalia.state.set(KEY_COMMAND, cmd)
end

local function requestDestructiveAction(action, payload)
  local confirmConfig = noctalia.getConfig("confirm_destructive") ~= false
  if confirmConfig then
    local p = { action = action }
    if type(payload) == "table" then
      for k, v in pairs(payload) do p[k] = v end
    end
    confirmPending = p
    render()
  else
    local p = { confirmed = true }
    if type(payload) == "table" then
      for k, v in pairs(payload) do p[k] = v end
    end
    sendCommand(action, p)
  end
end

local function getSnapshot()
  return noctalia.state.get(KEY_SNAPSHOT) or {
    daemon             = "docker",
    available          = true,
    active             = true,
    busy               = false,
    activeTask         = nil,
    error              = "",
    globalStats        = { cpu = "0%", ram = "0B" },
    stacks             = {},
    containers         = {},
    images             = {},
    volumes            = {},
    networks           = {},
    pods               = {},
    confirmDestructive = true,
    isScanning         = false,
    scanningStacks     = false,
    scanMessage        = nil,
    scanError          = nil,
    scanDirsList       = {},
  }
end

-- ---------------------------------------------------------------------------
-- UI Helpers
-- ---------------------------------------------------------------------------

local function statusDot(color, tooltip)
  return ui.box({ width = 10, height = 10, radius = 5, fill = color, tooltip = tooltip })
end

local function pill(text, fillColor, textColor, tooltip)
  return ui.row({
    fill     = fillColor,
    radius   = 6,
    paddingH = 8,
    paddingV = 4,
    align    = "center",
    justify  = "center",
    tooltip  = tooltip,
  }, {
    ui.label({ text = text, fontSize = 10, fontWeight = "medium", color = textColor }),
  })
end

local function suggestPortForImage(imgName)
  local lower = imgName:lower()
  if lower:find("nginx", 1, true) or lower:find("httpd", 1, true) or lower:find("apache", 1, true) then
    return "8080:80"
  elseif lower:find("redis", 1, true) then
    return "6379:6379"
  elseif lower:find("postgres", 1, true) then
    return "5432:5432"
  elseif lower:find("mysql", 1, true) or lower:find("mariadb", 1, true) then
    return "3306:3306"
  elseif lower:find("mongo", 1, true) then
    return "27017:27017"
  elseif lower:find("caddy", 1, true) then
    return "80:80, 443:443"
  elseif lower:find("traefik", 1, true) then
    return "80:80, 8080:8080"
  elseif lower:find("memcached", 1, true) then
    return "11211:11211"
  elseif lower:find("elasticsearch", 1, true) then
    return "9200:9200"
  elseif lower:find("rabbitmq", 1, true) then
    return "5672:5672, 15672:15672"
  end
  return ""
end

local function defaultContainerName(imgName)
  local withoutTag = imgName:gsub(":[^:]*$", "")
  local base = withoutTag:match("[^/]+$") or withoutTag
  base = base:gsub("[^a-zA-Z0-9_%-]", "-")
  return base
end

local function openLaunchModal(imgName)
  launchModalImage = imgName
  launchNameInput  = defaultContainerName(imgName)
  launchPortInput  = suggestPortForImage(imgName)
  launchEnvInput   = ""
  render()
end

-- ---------------------------------------------------------------------------
-- Daemon Error / Missing Banner
-- ---------------------------------------------------------------------------

local function renderDaemonBanner(snapshot)
  if snapshot.available == false or snapshot.active == false then
    local msg = snapshot.error
    if msg == nil or msg == "" then
      msg = tr("header.daemon_inactive")
    end
    local daemonName = snapshot.daemon or "docker"
    if not noctalia.commandExists(daemonName) then
      msg = tr("header.daemon_missing", { daemon = daemonName })
    end
    return ui.row({
      key      = "panel-daemon-banner",
      fill     = "error/0.15",
      radius   = 10,
      paddingH = 12,
      paddingV = 8,
      align    = "center",
      gap      = 8,
      flexGrow = 0,
    }, {
      ui.glyph({ name = "alert-triangle", size = 16, color = "error" }),
      ui.label({ text = msg, color = "error", fontSize = 12, flexGrow = 1 }),
      ui.button({
        text        = "Retry",
        glyph       = "refresh",
        variant     = "outline",
        controlSize = "sm",
        tooltip     = "Retry connecting to daemon",
        onClick     = function() sendCommand("refresh") end,
      }),
    })
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Active Task & Progress Card (Streaming download/operation feedback)
-- ---------------------------------------------------------------------------

local function renderActiveTaskCard(task)
  if not task then
    return nil
  end

  local elapsedSec  = math.max(0, os.time() - (task.startTime or os.time()))
  local elapsedStr  = elapsedSec < 60 and `{elapsedSec}s` or string.format("%dm %02ds", math.floor(elapsedSec / 60), elapsedSec % 60)
  local progressVal = math.max(0.05, math.min(1.0, task.progress or 0.15))
  local pctStr      = task.progress and string.format("%d%%", math.floor(progressVal * 100)) or ""

  local recentLogs = task.recentLogs or {}
  local logItems   = {}
  local maxShown   = 3
  local startIdx   = math.max(1, #recentLogs - maxShown + 1)
  for i = startIdx, #recentLogs do
    table.insert(logItems, ui.label({
      text       = `› {recentLogs[i]}`,
      fontFamily = "monospace",
      fontSize   = 10,
      color      = "on_surface_variant",
      maxLines   = 1,
    }))
  end
  if #logItems == 0 and task.lastLog and task.lastLog ~= "" then
    table.insert(logItems, ui.label({
      text       = `› {task.lastLog}`,
      fontFamily = "monospace",
      fontSize   = 10,
      color      = "on_surface_variant",
      maxLines   = 1,
    }))
  end

  local stagePillText = task.stage or "Working…"
  if pctStr ~= "" then
    stagePillText = `{pctStr} · {stagePillText}`
  end

  local cardChildren = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.row({ align = "center", gap = 8, flexGrow = 1 }, {
        ui.glyph({ name = "loader", size = 16, color = "primary" }),
        ui.label({
          text       = task.title or tr("tasks.in_progress"),
          fontWeight = "bold",
          fontSize   = 13,
          color      = "on_surface",
          maxLines   = 1,
        }),
      }),
      ui.row({ align = "center", gap = 6 }, {
        pill(stagePillText, "primary/0.2", "primary"),
        ui.label({ text = elapsedStr, fontSize = 11, color = "on_surface_variant" }),
      }),
    }),
    ui.progress({
      progress = progressVal,
      height   = 4,
      radius   = 2,
      fill     = "primary",
      track    = "on_surface/0.10",
    }),
  }

  if #logItems > 0 then
    table.insert(cardChildren, ui.column({
      fill     = "surface_container_lowest/0.7",
      radius   = 6,
      paddingH = 8,
      paddingV = 6,
      gap      = 2,
    }, logItems))
  end

  return ui.column({
    key         = "panel-active-task",
    fill        = "surface_container_high",
    radius      = 10,
    paddingH    = 12,
    paddingV    = 10,
    gap         = 6,
    borderWidth = 1,
    border      = "primary/0.35",
    flexGrow    = 0,
    justify     = "start",
    align       = "stretch",
  }, cardChildren)
end

-- ---------------------------------------------------------------------------
-- Confirmation Modal
-- ---------------------------------------------------------------------------

local function renderConfirmModal(cmd, snapshot)
  if cmd == nil then return nil end

  local action = cmd.action or ""
  local name   = cmd.name or cmd.id or ""

  local msgKey = "confirm." .. action
  local msg    = tr(msgKey, { name = name })
  if msg == msgKey then
    msg = `Are you sure you want to perform "{action}" on "{name}"?`
  end

  return ui.column({
    key      = "modal-confirm",
    fill     = "surface_container_highest",
    radius   = 16,
    padding  = 20,
    gap      = 14,
    flexGrow = 0,
    justify  = "start",
    align    = "stretch",
  }, {
    ui.label({ text = tr("confirm.title"), fontWeight = "bold", fontSize = 15, color = "on_surface" }),
    ui.label({ text = msg, color = "on_surface_variant", fontSize = 13 }),
    ui.row({ justify = "end", gap = 8 }, {
      ui.button({
        text    = tr("confirm.no"),
        variant = "outline",
        tooltip = "Cancel action without making changes",
        onClick = function()
          confirmPending = nil
          render()
        end,
      }),
      ui.button({
        text    = tr("confirm.yes"),
        variant = "destructive",
        tooltip = "Permanently proceed with deletion",
        onClick = function()
          local action = cmd.action
          local confirmedCmd = { confirmed = true }
          for k, v in pairs(cmd) do confirmedCmd[k] = v end
          confirmPending = nil
          sendCommand(action, confirmedCmd)
          render()
        end,
      }),
    }),
  })
end

-- ---------------------------------------------------------------------------
-- Logs Viewer Modal
-- ---------------------------------------------------------------------------

local function renderLogsModal(snapshot)
  local text   = snapshot.logsOutput
  local target = snapshot.logsTarget or ""
  if text == nil then return nil end

  local displayText = (text == "") and tr("logs.empty") or text

  return ui.column({ key = "modal-logs", flexGrow = 1, gap = 8, justify = "start", align = "stretch" }, {
    ui.row({ align = "center", justify = "space_between", gap = 8, flexGrow = 0 }, {
      ui.label({ text = tr("logs.title", { name = target }), fontWeight = "bold", fontSize = 14, color = "on_surface", flexGrow = 1 }),
      ui.button({
        text        = tr("logs.close"),
        glyph       = "close",
        variant     = "outline",
        controlSize = "sm",
        tooltip     = "Close log viewer",
        onClick     = function()
          sendCommand("clear_logs")
        end,
      }),
    }),
    ui.scroll({ key = "modal-logs-scroll", flexGrow = 1, align = "stretch" }, {
      ui.label({
        text       = displayText,
        fontSize   = 11,
        color      = "on_surface",
        fontFamily = "monospace",
        selectable = true,
      }),
    }),
  })
end

-- ---------------------------------------------------------------------------
-- Generate Output Modal (Podman)
-- ---------------------------------------------------------------------------

local function renderGenerateModal(snapshot)
  local text  = snapshot.generateOutput
  local title = snapshot.generateTitle or ""
  if text == nil then return nil end

  return ui.column({ key = "modal-generate", flexGrow = 1, gap = 8, justify = "start", align = "stretch" }, {
    ui.row({ align = "center", justify = "space_between", gap = 8, flexGrow = 0 }, {
      ui.label({ text = title, fontWeight = "bold", fontSize = 13, color = "on_surface", flexGrow = 1 }),
      ui.row({ align = "center", gap = 6 }, {
        ui.button({
          text        = tr("pods.generate_copy"),
          glyph       = "copy",
          variant     = "outline",
          controlSize = "sm",
          tooltip     = "Copy to clipboard",
          onClick     = function()
            noctalia.copyToClipboard(text, "text/plain")
          end,
        }),
        ui.button({
          glyph       = "close",
          variant     = "outline",
          controlSize = "sm",
          tooltip     = "Close generated view",
          onClick     = function()
            sendCommand("clear_generate")
          end,
        }),
      }),
    }),
    ui.scroll({ key = "modal-generate-scroll", flexGrow = 1, align = "stretch" }, {
      ui.label({ text = text, fontSize = 11, color = "on_surface", fontFamily = "monospace", selectable = true }),
    }),
  })
end

-- ---------------------------------------------------------------------------
-- Sub-view: Stacks Tab
-- ---------------------------------------------------------------------------

local function renderStacksTab(snapshot)
  local stacks = snapshot.stacks or {}
  local daemon = snapshot.daemon or "docker"

  local busyTooltip = snapshot.busy and (snapshot.activeTask and snapshot.activeTask.title or tr("tasks.in_progress")) or nil

  local toolbar = ui.row({ key = "stacks-toolbar", align = "center", justify = "space_between", paddingV = 4, flexGrow = 0 }, {
    ui.label({ text = `{#stacks} Stacks detected`, color = "on_surface_variant", fontSize = 12 }),
    ui.button({
      text        = snapshot.scanningStacks and "Scanning…" or "Scan Directories",
      glyph       = snapshot.scanningStacks and "loader" or "refresh",
      variant     = "outline",
      controlSize = "sm",
      enabled     = not snapshot.scanningStacks and not snapshot.busy,
      tooltip     = snapshot.scanningStacks and "Scanning configured directories for compose files…" or (busyTooltip or "Scan configured directories for compose files"),
      onClick     = function() sendCommand("scan_stacks") end,
    }),
  })

  local scanFeedback = nil
  if snapshot.scanningStacks then
    scanFeedback = ui.row({
      fill     = "primary/0.12",
      radius   = 8,
      paddingH = 10,
      paddingV = 6,
      align    = "center",
      gap      = 8,
    }, {
      ui.glyph({ name = "loader", size = 15, color = "primary" }),
      ui.label({ text = tr("stacks.scanning_dirs"), color = "primary", fontSize = 11, flexGrow = 1 }),
    })
  elseif snapshot.scanError ~= nil and snapshot.scanError ~= "" then
    scanFeedback = ui.row({
      fill     = "error/0.15",
      radius   = 8,
      paddingH = 10,
      paddingV = 6,
      align    = "center",
      gap      = 8,
    }, {
      ui.glyph({ name = "alert-triangle", size = 15, color = "error" }),
      ui.label({ text = snapshot.scanError, color = "error", fontSize = 11, flexGrow = 1 }),
      ui.button({
        text        = "Settings",
        glyph       = "settings",
        variant     = "ghost",
        controlSize = "sm",
        tooltip     = "Open plugin settings",
        onClick     = openPluginSettings,
      }),
    })
  elseif snapshot.scanMessage ~= nil and snapshot.scanMessage ~= "" and not snapshot.scanningStacks then
    scanFeedback = ui.row({
      align    = "center",
      gap      = 6,
      paddingH = 4,
      paddingV = 2,
    }, {
      ui.glyph({ name = "info-circle", size = 13, color = "on_surface_variant" }),
      ui.label({ text = snapshot.scanMessage, color = "on_surface_variant", fontSize = 11, flexGrow = 1 }),
    })
  end

  if #stacks == 0 then
    local dirsList = snapshot.scanDirsList or {}
    local dirsStr  = (#dirsList > 0) and table.concat(dirsList, ", ") or "~/docker, ~/Projects, ~/compose"

    if snapshot.scanningStacks then
      local scanningChildren = { toolbar }
      if scanFeedback then table.insert(scanningChildren, scanFeedback) end
      table.insert(scanningChildren, ui.column({ align = "center", justify = "center", gap = 12, padding = 32 }, {
        ui.glyph({ name = "loader", size = 40, color = "primary" }),
        ui.label({ text = tr("stacks.scanning_dirs"), color = "primary", fontWeight = "bold" }),
        ui.label({ text = tr("stacks.configured_dirs", { dirs = dirsStr }), color = "on_surface_variant", fontSize = 11, textAlign = "center" }),
      }))
      return ui.column({ key = "tab-stacks-scanning", flexGrow = 1, gap = 8, justify = "start", align = "stretch" }, scanningChildren)
    end

    local emptyTitle = (snapshot.scanError ~= nil and snapshot.scanError ~= "")
      and snapshot.scanError
      or  (snapshot.scanMessage or tr("stacks.empty", { daemon = daemon }))

    local emptyChildren = { toolbar }
    if scanFeedback then table.insert(emptyChildren, scanFeedback) end
    table.insert(emptyChildren, ui.column({ align = "center", justify = "center", gap = 12, padding = 32 }, {
      ui.glyph({ name = snapshot.scanError and "alert-triangle" or "folder-code", size = 40, color = snapshot.scanError and "error" or "on_surface_variant" }),
      ui.label({ text = emptyTitle, color = snapshot.scanError and "error" or "on_surface_variant", textAlign = "center", fontWeight = "medium" }),
      ui.label({ text = tr("stacks.configured_dirs", { dirs = dirsStr }), color = "on_surface_variant", fontSize = 11, textAlign = "center" }),
      ui.row({ align = "center", gap = 8 }, {
        ui.button({
          text        = tr("stacks.scan_again"),
          glyph       = "refresh",
          variant     = "primary",
          controlSize = "sm",
          enabled     = not snapshot.scanningStacks and not snapshot.busy,
          onClick     = function() sendCommand("scan_stacks") end,
        }),
        ui.button({
          text        = "Configure Scan Directories",
          glyph       = "settings",
          variant     = "secondary",
          controlSize = "sm",
          tooltip     = "Open plugin settings to configure directories",
          onClick     = openPluginSettings,
        }),
      }),
    }))
    return ui.column({ key = "tab-stacks-empty", flexGrow = 1, gap = 8, justify = "start", align = "stretch" }, emptyChildren)
  end

  local rows = {}
  for _, s in ipairs(stacks) do
    local isThisStackActive = snapshot.activeTask ~= nil
      and (snapshot.activeTask.id == s.path or snapshot.activeTask.name == s.name)

    table.insert(rows, ui.row({
      key     = "stk-" .. s.name,
      fill    = "surface_container",
      radius  = 12,
      padding = 12,
      align   = "center",
      justify = "space_between",
      gap     = 12,
    }, {
      ui.column({ gap = 4, flexGrow = 1 }, {
        ui.row({ align = "center", gap = 8 }, {
          ui.label({ text = s.name, fontWeight = "bold", color = "on_surface", fontSize = 14 }),
          isThisStackActive
            and pill(snapshot.activeTask.stage or "Deploying…", "primary/0.2", "primary", "Stack is currently running an operation")
            or  pill(
                  s.running and tr("stacks.active") or tr("stacks.inactive"),
                  s.running and "primary/0.2" or "surface_container_highest",
                  s.running and "primary"     or "on_surface_variant",
                  s.running and "Stack containers are running" or "Stack containers are stopped"
                ),
        }),
        ui.label({ text = s.path, color = "on_surface_variant", fontSize = 11, maxLines = 1 }),
      }),
      ui.row({ align = "center", gap = 6 }, {
        isThisStackActive
          and ui.button({
                text        = "Deploying…",
                glyph       = "loader",
                variant     = "primary",
                controlSize = "sm",
                tooltip     = "Stack deployment in progress",
                enabled     = false,
              })
          or  ui.button({
                text        = tr("stacks.up"),
                variant     = "primary",
                controlSize = "sm",
                enabled     = not snapshot.busy,
                tooltip     = busyTooltip or "Deploy stack services in background (compose up -d)",
                onClick     = function() sendCommand("compose_up", { path = s.path, name = s.name }) end,
              }),
        ui.button({
          text        = tr("stacks.down"),
          variant     = "outline",
          controlSize = "sm",
          enabled     = not snapshot.busy and not isThisStackActive,
          tooltip     = busyTooltip or "Stop and remove stack services (compose down)",
          onClick     = function() requestDestructiveAction("compose_down", { path = s.path, name = s.name }) end,
        }),
        ui.button({
          text        = tr("stacks.deploy_eject"),
          variant     = "outline",
          controlSize = "sm",
          tooltip     = busyTooltip or tr("stacks.deploy_eject_tooltip"),
          enabled     = not snapshot.busy and not isThisStackActive,
          onClick     = function()
            sendCommand("compose_deploy_eject", { path = s.path, name = s.name })
            currentTab = "containers"
            render()
          end,
        }),
      }),
    }))
  end

  local stackChildren = { toolbar }
  if scanFeedback then table.insert(stackChildren, scanFeedback) end
  table.insert(stackChildren, ui.scroll({ key = "stacks-scroll", flexGrow = 1, gap = 8, align = "stretch" }, rows))

  return ui.column({ key = "tab-stacks", flexGrow = 1, gap = 8, justify = "start", align = "stretch" }, stackChildren)
end

-- ---------------------------------------------------------------------------
-- Sub-view: Containers Tab
-- ---------------------------------------------------------------------------

local function renderContainersTab(snapshot)
  local all      = snapshot.containers or {}
  local daemon   = snapshot.daemon or "docker"
  local isPodman = (daemon == "podman")

  local visible = {}
  local q = containerSearch:lower()
  for _, c in ipairs(all) do
    local match = q == ""
      or c.name:lower():find(q, 1, true)
      or c.image:lower():find(q, 1, true)
      or c.ports:lower():find(q, 1, true)
    if match then table.insert(visible, c) end
  end

  local toolbar = ui.row({ key = "containers-toolbar", align = "center", gap = 8, paddingV = 4, flexGrow = 0 }, {
    ui.input({
      key         = "container_search",
      placeholder = tr("containers.search_placeholder"),
      value       = containerSearch,
      glyph       = "search",
      flexGrow    = 1,
      onChange    = "onContainerSearch",
    }),
    ui.label({ text = `{#all} containers`, color = "on_surface_variant", fontSize = 11 }),
    ui.button({
      text        = "Run Image",
      glyph       = "plus",
      variant     = "primary",
      controlSize = "sm",
      tooltip     = "Find and run an image from registry",
      onClick     = function()
        currentTab   = "images"
        imageSubView = "online"
        render()
      end,
    }),
    ui.button({
      text        = snapshot.isScanning and "Scanning…" or "Scan",
      glyph       = snapshot.isScanning and "loader" or "refresh",
      variant     = "outline",
      controlSize = "sm",
      enabled     = not snapshot.isScanning and not snapshot.busy,
      tooltip     = snapshot.isScanning and "Rescanning containers in background…" or "Rescan running containers",
      onClick     = function() sendCommand("refresh_containers") end,
    }),
  })

  if #visible == 0 then
    return ui.column({ key = "tab-containers-empty", flexGrow = 1, gap = 8, justify = "start", align = "stretch" }, {
      toolbar,
      ui.column({ align = "center", justify = "center", gap = 12, padding = 32 }, {
        ui.glyph({ name = "box", size = 40, color = "on_surface_variant" }),
        ui.label({ text = tr("containers.empty", { daemon = daemon }), color = "on_surface_variant", textAlign = "center" }),
        ui.button({
          text        = tr("containers.browse_online_cta"),
          glyph       = "world",
          variant     = "primary",
          controlSize = "sm",
          tooltip     = "Browse online registry and launch a container",
          onClick     = function()
            currentTab   = "images"
            imageSubView = "online"
            render()
          end,
        }),
      }),
    })
  end

  local rows = {}
  for _, c in ipairs(visible) do
    local isRunning = c.state == "running"
    local busyTooltip = snapshot.busy and (snapshot.activeTask and snapshot.activeTask.title or tr("tasks.in_progress")) or nil

    local podmanExtras = {}
    if isPodman and c.rootless ~= nil then
      table.insert(podmanExtras, pill(
        c.rootless and tr("containers.rootless") or tr("containers.rootful"),
        c.rootless and "primary/0.15" or "tertiary/0.15",
        c.rootless and "primary"      or "tertiary",
        c.rootless and "Running in rootless mode" or "Running in rootful mode"
      ))
    end

    local portsList = c.portsList or {}

    local portButtons = {}
    if isRunning and portsList and #portsList > 0 then
      for _, p in ipairs(portsList) do
        table.insert(portButtons, ui.button({
          text        = p.text,
          glyph       = "external-link",
          variant     = "secondary",
          controlSize = "sm",
          tooltip     = tr("containers.open_port_tooltip", { url = p.url }),
          onClick     = function()
            if type(p.url) == "string" and (p.url:match("^https?://localhost:") or p.url:match("^https?://127%.0%.0%.1:")) then
              sendCommand("open_url", { url = p.url })
            end
          end,
        }))
      end
    end

    local portSummary = (c.ports and c.ports ~= "") and `  ·  {c.ports}` or ""

    local nameChildren = {
      ui.label({ text = c.name, fontWeight = "bold", color = "on_surface", fontSize = 13 }),
    }
    if c.stack then
      table.insert(nameChildren, pill(c.stack, "surface_container_highest", "on_surface_variant", `Compose stack: {c.stack}`))
    end
    for _, extra in ipairs(podmanExtras) do
      table.insert(nameChildren, extra)
    end

    local actionButtons = {
      isRunning
        and ui.button({ glyph = "player-stop", variant = "outline",     controlSize = "sm", tooltip = busyTooltip or tr("containers.stop"),    enabled = not snapshot.busy, onClick = function() sendCommand("container_stop",    { id = c.id, name = c.name }) end })
        or  ui.button({ glyph = "player-play", variant = "primary",     controlSize = "sm", tooltip = busyTooltip or tr("containers.start"),   enabled = not snapshot.busy, onClick = function() sendCommand("container_start",   { id = c.id, name = c.name }) end }),
      ui.button({ glyph = "refresh",   variant = "outline",             controlSize = "sm", tooltip = busyTooltip or tr("containers.restart"), enabled = isRunning and not snapshot.busy, onClick = function() sendCommand("container_restart", { id = c.id, name = c.name }) end }),
      ui.button({ glyph = "file-text", variant = "outline",             controlSize = "sm", tooltip = tr("containers.logs"),                  enabled = true,                             onClick = function() sendCommand("container_logs", { id = c.id, name = c.name }) end }),
    }
    if isPodman then
      table.insert(actionButtons, ui.button({ text = tr("pods.generate_systemd"), variant = "ghost", controlSize = "sm", tooltip = busyTooltip or tr("pods.generate_systemd_tooltip"), enabled = not snapshot.busy, onClick = function() sendCommand("podman_generate_systemd", { id = c.id, name = c.name }) end }))
      table.insert(actionButtons, ui.button({ text = tr("pods.generate_kube"),    variant = "ghost", controlSize = "sm", tooltip = busyTooltip or tr("pods.generate_kube_tooltip"),    enabled = not snapshot.busy, onClick = function() sendCommand("podman_generate_kube",    { id = c.id, name = c.name }) end }))
    end
    for _, pb in ipairs(portButtons) do
      table.insert(actionButtons, pb)
    end
    table.insert(actionButtons, ui.spacer({}))
    table.insert(actionButtons, ui.button({ glyph = "trash", variant = "destructive", controlSize = "sm", tooltip = busyTooltip or tr("containers.remove"), enabled = not snapshot.busy, onClick = function()
      requestDestructiveAction("container_remove", { id = c.id, name = c.name })
    end }))

    table.insert(rows, ui.column({
      key     = "cnt-" .. c.id,
      fill    = "surface_container",
      radius  = 12,
      padding = 10,
      gap     = 8,
    }, {
      ui.row({ align = "center", justify = "space_between", gap = 10 }, {
        ui.row({ align = "center", gap = 10, flexGrow = 1 }, {
          statusDot(isRunning and "primary" or "error", isRunning and "Container is running" or "Container is stopped"),
          ui.column({ gap = 2, flexGrow = 1 }, {
            ui.row({ align = "center", gap = 6 }, nameChildren),
            ui.label({ text = `{c.image}  ·  {c.status}{portSummary}`, color = "on_surface_variant", fontSize = 11, maxLines = 1 }),
          }),
        }),
        ui.row({ align = "center", gap = 6 }, {
          pill(`CPU {c.cpu or "0%"}`, "surface_container_highest", "on_surface_variant", "Current CPU utilization"),
          pill(`RAM {c.ram or "0B"}`, "surface_container_highest", "on_surface_variant", "Current memory consumption"),
        }),
      }),

      ui.row({ align = "center", gap = 4 }, actionButtons),
    }))
  end

  return ui.column({ key = "tab-containers", flexGrow = 1, gap = 6, justify = "start", align = "stretch" }, {
    toolbar,
    ui.scroll({ key = "containers-scroll", flexGrow = 1, gap = 6, align = "stretch" }, rows),
  })
end

-- ---------------------------------------------------------------------------
-- Sub-view: Online Images (Registry Browser)
-- ---------------------------------------------------------------------------

local function renderOnlineImagesView(snapshot)
  local isSearching = snapshot.onlineSearching == true
  local searchErr   = snapshot.onlineSearchError
  local results     = snapshot.onlineSearchResults

  local searchBar = ui.row({ align = "center", gap = 8, paddingV = 4 }, {
    ui.input({
      key         = "online_search_input",
      placeholder = tr("images.online_search_placeholder"),
      value       = onlineSearchInput,
      glyph       = "search",
      flexGrow    = 1,
      onChange    = "onOnlineSearchInputChange",
      onSubmit    = "onOnlineSearchSubmit",
    }),
    ui.button({
      text        = tr("images.online_search_button"),
      glyph       = "search",
      variant     = "primary",
      controlSize = "sm",
      enabled     = not isSearching and not snapshot.busy,
      tooltip     = "Search Docker Hub for container images",
      onClick     = "onOnlineSearchSubmit",
    }),
  })

  local popularTags = { "nginx", "redis", "postgres", "mysql", "alpine", "node", "python", "ubuntu" }
  local tagButtons = {
    ui.label({ text = tr("images.popular_label"), color = "on_surface_variant", fontSize = 11 }),
  }
  for _, tag in ipairs(popularTags) do
    local tagName = tag
    table.insert(tagButtons, ui.button({
      text        = tagName,
      variant     = "ghost",
      controlSize = "sm",
      tooltip     = `Search registry for "{tagName}"`,
      onClick     = function()
        onlineSearchInput = tagName
        sendCommand("image_search_online", { query = tagName })
        render()
      end,
    }))
  end
  local popularRow = ui.row({ align = "center", gap = 4 }, tagButtons)

  local content
  if isSearching then
    content = ui.column({ align = "center", justify = "center", gap = 10, padding = 36 }, {
      ui.glyph({ name = "loader", size = 32, color = "primary" }),
      ui.label({
        text     = tr("images.searching", { query = snapshot.onlineSearchQuery or onlineSearchInput }),
        color    = "on_surface_variant",
        fontSize = 12,
      }),
    })
  elseif searchErr ~= nil and searchErr ~= "" then
    content = ui.column({ align = "center", justify = "center", gap = 10, padding = 24 }, {
      ui.row({
        fill     = "error/0.15",
        radius   = 10,
        paddingH = 14,
        paddingV = 10,
        align    = "center",
        gap      = 8,
      }, {
        ui.glyph({ name = "alert-triangle", size = 18, color = "error" }),
        ui.label({ text = searchErr, color = "error", fontSize = 12 }),
        ui.button({
          text        = "Retry",
          glyph       = "refresh",
          variant     = "outline",
          controlSize = "sm",
          onClick     = function()
            sendCommand("image_search_online", { query = snapshot.onlineSearchQuery or onlineSearchInput })
          end,
        }),
      }),
    })
  elseif results == nil then
    content = ui.column({ align = "center", justify = "center", gap = 8, padding = 36 }, {
      ui.glyph({ name = "world", size = 42, color = "on_surface_variant" }),
      ui.label({ text = tr("images.online_intro_title"), fontWeight = "bold", fontSize = 14, color = "on_surface" }),
      ui.label({ text = tr("images.online_intro_subtitle"), color = "on_surface_variant", fontSize = 11, textAlign = "center" }),
    })
  elseif #results == 0 then
    content = ui.column({ align = "center", justify = "center", gap = 8, padding = 36 }, {
      ui.glyph({ name = "search", size = 36, color = "on_surface_variant" }),
      ui.label({
        text  = tr("images.no_online_results", { query = snapshot.onlineSearchQuery or onlineSearchInput }),
        color = "on_surface_variant",
      }),
    })
  else
    local rows = {}
    for _, item in ipairs(results) do
      local it = item
      local colChildren = {
        ui.row({ align = "center", gap = 6 }, {
          ui.label({ text = it.displayName or it.name, fontWeight = "bold", color = "on_surface", fontSize = 13 }),
          it.official and pill(tr("images.official_badge"), "primary/0.2", "primary", "Official build on Docker Hub") or ui.box({ width = 0, height = 0 }),
          pill(`★ {it.stars}`, "surface_container_highest", "on_surface_variant", tr("images.stars_count", { count = it.stars })),
        }),
      }
      if it.name ~= (it.displayName or it.name) then
        table.insert(colChildren, ui.label({
          text     = it.name,
          color    = "on_surface_variant",
          fontSize = 10,
        }))
      end
      table.insert(colChildren, ui.label({
        text     = (it.description and it.description ~= "") and it.description or "No description available",
        color    = "on_surface_variant",
        fontSize = 11,
        maxLines = 2,
      }))

      table.insert(rows, ui.row({
        key     = "onl-" .. it.name,
        fill    = "surface_container",
        radius  = 12,
        padding = 10,
        align   = "center",
        justify = "space_between",
        gap     = 10,
      }, {
        ui.column({ gap = 3, flexGrow = 1 }, colChildren),
        ui.row({ align = "center", gap = 6 }, {
          ui.button({
            text        = tr("images.run"),
            glyph       = "player-play",
            variant     = "primary",
            controlSize = "sm",
            enabled     = not snapshot.busy,
            tooltip     = tr("images.run_tooltip"),
            onClick     = function()
              openLaunchModal(it.name)
            end,
          }),
          ui.button({
            text        = tr("images.pull"),
            glyph       = "download",
            variant     = "outline",
            controlSize = "sm",
            enabled     = not snapshot.busy,
            tooltip     = tr("images.pull_tooltip"),
            onClick     = function()
              sendCommand("image_pull", { image = it.name })
            end,
          }),
        }),
      }))
    end
    content = ui.scroll({ key = "online-scroll", flexGrow = 1, gap = 6 }, rows)
  end

  return ui.column({ key = "online-images-view", flexGrow = 1, gap = 8, justify = "start", align = "stretch" }, {
    searchBar,
    popularRow,
    content,
  })
end

-- ---------------------------------------------------------------------------
-- Sub-view: Launch Container Modal
-- ---------------------------------------------------------------------------

local function renderLaunchModal(imageName, snapshot)
  return ui.column({
    key      = "modal-launch",
    fill     = "surface_container_high",
    radius   = 14,
    padding  = 16,
    gap      = 12,
  }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.row({ align = "center", gap = 8 }, {
        ui.glyph({ name = "player-play", size = 20, color = "primary" }),
        ui.label({
          text       = tr("images.launch_modal_title", { image = imageName }),
          fontWeight = "bold",
          fontSize   = 14,
          color      = "on_surface",
        }),
      }),
      ui.button({
        glyph       = "close",
        variant     = "ghost",
        controlSize = "sm",
        tooltip     = "Cancel and close",
        onClick     = function()
          launchModalImage = nil
          render()
        end,
      }),
    }),
    ui.label({
      text     = `Configure and run a container from "{imageName}". If not downloaded locally, image layers will stream automatically with live download progress.`,
      color    = "on_surface_variant",
      fontSize = 11,
    }),
    ui.column({ gap = 4 }, {
      ui.label({ text = tr("images.launch_name_label"), fontSize = 12, fontWeight = "medium", color = "on_surface" }),
      ui.input({
        key         = "launch_name",
        placeholder = tr("images.launch_name_placeholder"),
        value       = launchNameInput,
        onChange    = "onLaunchNameChange",
      }),
    }),
    ui.column({ gap = 4 }, {
      ui.label({ text = tr("images.launch_port_label"), fontSize = 12, fontWeight = "medium", color = "on_surface" }),
      ui.input({
        key         = "launch_port",
        placeholder = tr("images.launch_port_placeholder"),
        value       = launchPortInput,
        onChange    = "onLaunchPortChange",
      }),
      ui.label({
        text     = "Leave empty to publish exposed ports with -P.",
        color    = "on_surface_variant",
        fontSize = 10,
      }),
    }),
    ui.column({ gap = 4 }, {
      ui.label({ text = tr("images.launch_env_label"), fontSize = 12, fontWeight = "medium", color = "on_surface" }),
      ui.input({
        key         = "launch_env",
        placeholder = tr("images.launch_env_placeholder"),
        value       = launchEnvInput,
        onChange    = "onLaunchEnvChange",
      }),
    }),
    ui.row({ align = "center", justify = "flex_end", gap = 8, paddingV = 4 }, {
      ui.button({
        text        = tr("images.cancel_button"),
        variant     = "outline",
        controlSize = "sm",
        onClick     = function()
          launchModalImage = nil
          render()
        end,
      }),
      ui.button({
        text        = tr("images.launch_button"),
        glyph       = "player-play",
        variant     = "primary",
        controlSize = "sm",
        enabled     = not snapshot.busy,
        onClick     = function()
          local img = launchModalImage
          local name = noctalia.string.trim(launchNameInput)
          local ports = noctalia.string.trim(launchPortInput)
          local env = noctalia.string.trim(launchEnvInput)
          launchModalImage = nil
          local payload = {
            image      = img,
            publishAll = (ports == ""),
          }
          if name ~= "" then payload.name = name end
          if ports ~= "" then payload.ports = ports end
          if env ~= "" then payload.env = env end
          sendCommand("container_run_image", payload)
          currentTab = "containers"
          render()
        end,
      }),
    }),
  })
end

-- ---------------------------------------------------------------------------
-- Sub-view: Images Tab
-- ---------------------------------------------------------------------------

local function renderImagesTab(snapshot)
  local all = snapshot.images or {}
  local busyTooltip = snapshot.busy and (snapshot.activeTask and snapshot.activeTask.title or tr("tasks.in_progress")) or nil

  local modeSelector = ui.row({ key = "images-mode-selector", align = "center", justify = "center", paddingV = 4, flexGrow = 0 }, {
    ui.row({
      fill     = "surface_container",
      radius   = 10,
      padding  = 4,
      align    = "center",
      gap      = 4,
    }, {
      ui.button({
        text        = tr("images.subview_local", { count = tostring(#all) }),
        glyph       = "box",
        variant     = imageSubView == "local" and "primary" or "ghost",
        controlSize = "sm",
        tooltip     = "View locally downloaded images",
        onClick     = function()
          imageSubView = "local"
          render()
        end,
      }),
      ui.button({
        text        = tr("images.subview_online"),
        glyph       = "world",
        variant     = imageSubView == "online" and "primary" or "ghost",
        controlSize = "sm",
        tooltip     = "Search and run images from Docker Hub / registry",
        onClick     = function()
          imageSubView = "online"
          render()
        end,
      }),
    }),
  })

  if imageSubView == "online" then
    return ui.column({ key = "tab-images-online", flexGrow = 1, gap = 8, justify = "start", align = "stretch" }, {
      modeSelector,
      renderOnlineImagesView(snapshot),
    })
  end

  local visible = {}
  local q = imageSearch:lower()
  for _, img in ipairs(all) do
    local match = q == ""
      or (`{img.repository}:{img.tag}`):lower():find(q, 1, true)
    if match then table.insert(visible, img) end
  end

  local headerRow = ui.row({ key = "images-header-row", align = "center", justify = "space_between", gap = 8, paddingV = 4, flexGrow = 0 }, {
    ui.row({ align = "center", gap = 8, flexGrow = 1 }, {
      ui.input({
        key         = "image_search",
        placeholder = tr("images.search_placeholder"),
        value       = imageSearch,
        glyph       = "search",
        flexGrow    = 1,
        onChange    = "onImageSearch",
      }),
      ui.label({ text = `{#all} images`, color = "on_surface_variant", fontSize = 11 }),
    }),
    ui.row({ align = "center", gap = 6 }, {
      ui.button({
        text        = snapshot.isScanning and "Scanning…" or "Scan Images",
        glyph       = snapshot.isScanning and "loader" or "refresh",
        variant     = "outline",
        controlSize = "sm",
        enabled     = not snapshot.isScanning and not snapshot.busy,
        tooltip     = snapshot.isScanning and "Rescanning downloaded images…" or (busyTooltip or "Rescan downloaded images"),
        onClick     = function() sendCommand("refresh_images") end,
      }),
      ui.button({
        text        = tr("images.prune_unused"),
        glyph       = "trash",
        variant     = "destructive",
        controlSize = "sm",
        enabled     = not snapshot.busy,
        tooltip     = busyTooltip or "Remove all unused and dangling images",
        onClick     = function() requestDestructiveAction("images_prune", { name = "all unused images" }) end,
      }),
    }),
  })

  if #visible == 0 then
    return ui.column({ key = "tab-images-empty", flexGrow = 1, gap = 8, justify = "start", align = "stretch" }, {
      modeSelector,
      headerRow,
      ui.column({ align = "center", justify = "center", gap = 12, padding = 32 }, {
        ui.glyph({ name = "photo", size = 40, color = "on_surface_variant" }),
        ui.label({ text = tr("images.empty"), color = "on_surface_variant" }),
        ui.button({
          text        = tr("images.browse_online_cta"),
          glyph       = "world",
          variant     = "primary",
          controlSize = "sm",
          tooltip     = "Browse and run images online",
          onClick     = function()
            imageSubView = "online"
            render()
          end,
        }),
      }),
    })
  end

  local rows = {}
  for _, img in ipairs(visible) do
    local isUnused = (img.inUseCount or 0) == 0
    local imgKey = "img-" .. ((img.id and img.id ~= "") and img.id or (`{img.repository}:{img.tag}`))
    table.insert(rows, ui.row({
      key     = imgKey,
      fill    = "surface_container",
      radius  = 12,
      padding = 10,
      align   = "center",
      justify = "space_between",
      gap     = 12,
    }, {
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.row({ align = "center", gap = 8 }, {
          ui.label({ text = `{img.repository}:{img.tag}`, fontWeight = "bold", color = "on_surface", fontSize = 13 }),
          pill(
            isUnused and "Unused" or tr("images.in_use", { count = tostring(img.inUseCount) }),
            isUnused and "error/0.15" or "primary/0.15",
            isUnused and "error"      or "primary",
            isUnused and "No running containers using this image" or `Referenced by {img.inUseCount} container(s)`
          ),
        }),
        ui.label({ text = `Size: {img.size}  ·  Created: {img.created}`, color = "on_surface_variant", fontSize = 11 }),
      }),
      ui.row({ align = "center", gap = 6 }, {
        ui.button({
          text        = tr("images.run"),
          glyph       = "player-play",
          variant     = "secondary",
          controlSize = "sm",
          tooltip     = `Configure and run container from {img.repository}:{img.tag}`,
          enabled     = not snapshot.busy,
          onClick     = function()
            openLaunchModal(`{img.repository}:{img.tag}`)
          end,
        }),
        ui.button({
          glyph       = "trash",
          variant     = "destructive",
          controlSize = "sm",
          enabled     = isUnused and not snapshot.busy,
          tooltip     = isUnused and (busyTooltip or tr("images.remove")) or "Cannot remove image while in use by containers",
          onClick     = function()
            requestDestructiveAction("image_remove", { id = img.id, name = `{img.repository}:{img.tag}` })
          end,
        }),
      }),
    }))
  end

  return ui.column({ key = "tab-images", flexGrow = 1, gap = 6, justify = "start", align = "stretch" }, {
    modeSelector,
    headerRow,
    ui.scroll({ key = "images-scroll", flexGrow = 1, gap = 6, align = "stretch" }, rows),
  })
end

-- ---------------------------------------------------------------------------
-- Sub-view: Infrastructure Tab
-- ---------------------------------------------------------------------------

local function renderInfraTab(snapshot)
  local volumes  = snapshot.volumes  or {}
  local networks = snapshot.networks or {}
  local busyTooltip = snapshot.busy and (snapshot.activeTask and snapshot.activeTask.title or tr("tasks.in_progress")) or nil

  local toolbar = ui.row({ key = "infra-toolbar", align = "center", justify = "space_between", paddingV = 4, flexGrow = 0 }, {
    ui.label({ text = `{#volumes} Volumes, {#networks} Networks`, color = "on_surface_variant", fontSize = 12 }),
    ui.button({
      text        = snapshot.isScanning and "Scanning…" or "Scan Infrastructure",
      glyph       = snapshot.isScanning and "loader" or "refresh",
      variant     = "outline",
      controlSize = "sm",
      enabled     = not snapshot.isScanning and not snapshot.busy,
      tooltip     = snapshot.isScanning and "Rescanning storage volumes and networks…" or (busyTooltip or "Rescan storage volumes and networks"),
      onClick     = function() sendCommand("refresh_infra") end,
    }),
  })

  local items = {}

  -- Volumes section header
  table.insert(items, ui.row({ key = "infra-vols-hdr", align = "center", justify = "space_between", paddingV = 4 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "database", size = 15, color = "primary" }),
      ui.label({ text = tr("infrastructure.volumes_title"), fontWeight = "bold", color = "on_surface", fontSize = 13 }),
    }),
    pill(`{#volumes}`, "surface_container_highest", "on_surface_variant"),
  }))

  if #volumes == 0 then
    table.insert(items, ui.row({
      key      = "infra-vols-empty",
      fill     = "surface_container_lowest",
      radius   = 8,
      padding  = 12,
      justify  = "center",
      align    = "center",
    }, {
      ui.label({ text = tr("infrastructure.empty_volumes"), color = "on_surface_variant", fontSize = 12 }),
    }))
  else
    for _, v in ipairs(volumes) do
      table.insert(items, ui.row({
        key     = "vol-" .. v.name,
        fill    = "surface_container",
        radius  = 8,
        padding = 8,
        align   = "center",
        justify = "space_between",
        gap     = 8,
      }, {
        ui.column({ gap = 2, flexGrow = 1 }, {
          ui.row({ align = "center", gap = 6 }, {
            ui.label({ text = v.name, fontWeight = "bold", color = "on_surface", fontSize = 12, maxLines = 1 }),
            pill(
              v.inUse and tr("infrastructure.in_use") or tr("infrastructure.orphan"),
              v.inUse and "primary/0.15" or "error/0.15",
              v.inUse and "primary"      or "error",
              v.inUse and "Volume is currently mounted" or "Volume is unattached"
            ),
          }),
          ui.label({ text = `{v.driver} · {v.mountpoint}`, color = "on_surface_variant", fontSize = 10, maxLines = 1 }),
        }),
        (not v.inUse) and ui.button({
          glyph       = "trash",
          variant     = "destructive",
          controlSize = "sm",
          enabled     = not snapshot.busy,
          tooltip     = busyTooltip or "Delete unattached volume",
          onClick     = function() requestDestructiveAction("volume_remove", { name = v.name }) end,
        }) or ui.button({
          glyph       = "trash",
          variant     = "ghost",
          controlSize = "sm",
          enabled     = false,
          tooltip     = tr("infrastructure.volume_in_use_tooltip"),
        }),
      }))
    end
  end

  -- Spacing separator between volumes and networks
  table.insert(items, ui.row({ key = "infra-sep", paddingV = 4 }, {}))

  -- Networks section header
  table.insert(items, ui.row({ key = "infra-nets-hdr", align = "center", justify = "space_between", paddingV = 4 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "network", size = 15, color = "primary" }),
      ui.label({ text = tr("infrastructure.networks_title"), fontWeight = "bold", color = "on_surface", fontSize = 13 }),
    }),
    pill(`{#networks}`, "surface_container_highest", "on_surface_variant"),
  }))

  if #networks == 0 then
    table.insert(items, ui.row({
      key      = "infra-nets-empty",
      fill     = "surface_container_lowest",
      radius   = 8,
      padding  = 12,
      justify  = "center",
      align    = "center",
    }, {
      ui.label({ text = tr("infrastructure.empty_networks"), color = "on_surface_variant", fontSize = 12 }),
    }))
  else
    for _, n in ipairs(networks) do
      local deleteBtn = nil
      if not n.isSystem then
        if n.isOrphan then
          deleteBtn = ui.button({
            glyph       = "trash",
            variant     = "destructive",
            controlSize = "sm",
            enabled     = not snapshot.busy,
            tooltip     = busyTooltip or "Delete unattached network",
            onClick     = function() requestDestructiveAction("network_remove", { id = n.id, name = n.name }) end,
          })
        else
          deleteBtn = ui.button({
            glyph       = "trash",
            variant     = "ghost",
            controlSize = "sm",
            enabled     = false,
            tooltip     = tr("infrastructure.network_in_use_tooltip"),
          })
        end
      else
        deleteBtn = ui.button({
          glyph       = "trash",
          variant     = "ghost",
          controlSize = "sm",
          enabled     = false,
          tooltip     = "System network cannot be removed",
        })
      end

      table.insert(items, ui.row({
        key      = "net-" .. (n.id ~= "" and n.id or n.name),
        fill     = "surface_container",
        radius   = 8,
        paddingH = 8,
        paddingV = 8,
        align    = "center",
        justify  = "space_between",
        gap      = 8,
      }, {
        ui.column({ gap = 2, flexGrow = 1 }, {
          ui.row({ align = "center", gap = 6 }, {
            ui.label({ text = n.name, fontWeight = "bold", color = "on_surface", fontSize = 12, maxLines = 1 }),
            pill(
              n.isOrphan and tr("infrastructure.orphan") or tr("infrastructure.in_use"),
              n.isOrphan and "error/0.15" or "primary/0.15",
              n.isOrphan and "error"      or "primary",
              n.isOrphan and "Network has no attached containers" or "Containers are attached to this network"
            ),
          }),
          ui.label({ text = `{n.driver} · {n.scope}`, color = "on_surface_variant", fontSize = 10 }),
        }),
        deleteBtn,
      }))
    end
  end

  return ui.column({ key = "tab-infra", flexGrow = 1, gap = 8, justify = "start", align = "stretch" }, {
    toolbar,
    ui.scroll({ key = "infra-scroll", flexGrow = 1, gap = 6, align = "stretch" }, items),
  })
end

-- ---------------------------------------------------------------------------
-- Sub-view: Pods Tab (Podman only)
-- ---------------------------------------------------------------------------

local function renderPodsTab(snapshot)
  local pods = snapshot.pods or {}
  local busyTooltip = snapshot.busy and (snapshot.activeTask and snapshot.activeTask.title or tr("tasks.in_progress")) or nil

  local toolbar = ui.row({ key = "pods-toolbar", align = "center", justify = "space_between", paddingV = 4, flexGrow = 0 }, {
    ui.label({ text = `{#pods} Pods`, color = "on_surface_variant", fontSize = 12 }),
    ui.button({
      text        = snapshot.isScanning and "Scanning…" or "Scan Pods",
      glyph       = snapshot.isScanning and "loader" or "refresh",
      variant     = "outline",
      controlSize = "sm",
      enabled     = not snapshot.isScanning and not snapshot.busy,
      tooltip     = snapshot.isScanning and "Rescanning Podman pods…" or (busyTooltip or "Rescan Podman pods"),
      onClick     = function() sendCommand("refresh_pods") end,
    }),
  })

  if #pods == 0 then
    return ui.column({ key = "tab-pods-empty", flexGrow = 1, gap = 8, justify = "start", align = "stretch" }, {
      toolbar,
      ui.column({ align = "center", justify = "center", gap = 12, padding = 32 }, {
        ui.glyph({ name = "box-multiple", size = 40, color = "on_surface_variant" }),
        ui.label({ text = tr("pods.empty"), color = "on_surface_variant", textAlign = "center" }),
      }),
    })
  end

  local rows = {}
  for _, p in ipairs(pods) do
    local isRunning = p.status == "running"
    table.insert(rows, ui.row({
      key     = "pod-" .. p.id,
      fill    = "surface_container",
      radius  = 12,
      padding = 10,
      align   = "center",
      justify = "space_between",
      gap     = 12,
    }, {
      ui.row({ align = "center", gap = 10, flexGrow = 1 }, {
        statusDot(isRunning and "primary" or "error", isRunning and "Pod is running" or "Pod is stopped"),
        ui.column({ gap = 2, flexGrow = 1 }, {
          ui.row({ align = "center", gap = 6 }, {
            ui.label({ text = p.name, fontWeight = "bold", color = "on_surface", fontSize = 13 }),
            pill(
              isRunning and tr("pods.running") or tr("pods.exited"),
              isRunning and "primary/0.2" or "surface_container_highest",
              isRunning and "primary" or "on_surface_variant",
              isRunning and "Pod is active and running" or "Pod is exited"
            ),
          }),
          ui.label({ text = tr("pods.containers", { count = tostring(p.containerCount) }), color = "on_surface_variant", fontSize = 11 }),
        }),
      }),
      ui.row({ align = "center", gap = 4 }, {
        isRunning
          and ui.button({ text = tr("pods.stop"),              variant = "outline",     controlSize = "sm", enabled = not snapshot.busy, tooltip = busyTooltip or tr("pods.stop"),    onClick = function() sendCommand("pod_stop",  { id = p.id, name = p.name }) end })
          or  ui.button({ text = tr("pods.start"),             variant = "primary",     controlSize = "sm", enabled = not snapshot.busy, tooltip = busyTooltip or tr("pods.start"),   onClick = function() sendCommand("pod_start", { id = p.id, name = p.name }) end }),
        ui.button({ text = tr("pods.generate_systemd"), glyph = "file-code", variant = "ghost", controlSize = "sm", tooltip = busyTooltip or tr("pods.generate_systemd_tooltip"), enabled = not snapshot.busy, onClick = function() sendCommand("podman_generate_systemd", { id = p.id, name = p.name }) end }),
        ui.button({ text = tr("pods.generate_kube"),    glyph = "cloud",     variant = "ghost", controlSize = "sm", tooltip = busyTooltip or tr("pods.generate_kube_tooltip"),    enabled = not snapshot.busy, onClick = function() sendCommand("podman_generate_kube",    { id = p.id, name = p.name }) end }),
        ui.button({ glyph = "trash",                             variant = "destructive", controlSize = "sm", tooltip = busyTooltip or tr("pods.remove"), enabled = not snapshot.busy, onClick = function() requestDestructiveAction("pod_remove", { id = p.id, name = p.name }) end }),
      }),
    }))
  end

  return ui.column({ key = "tab-pods", flexGrow = 1, gap = 8, justify = "start", align = "stretch" }, {
    toolbar,
    ui.scroll({ key = "pods-scroll", flexGrow = 1, gap = 8, align = "stretch" }, rows),
  })
end

-- ---------------------------------------------------------------------------
-- Master Render Routine
-- ---------------------------------------------------------------------------

function render()
  local snapshot   = getSnapshot()
  local daemonName = snapshot.daemon or "docker"
  local isPodman   = (daemonName == "podman")
  local stats      = snapshot.globalStats or { cpu = "0%", ram = "0B" }

  -- Header
  local headerControls = {
    ui.row({ align = "center", gap = 8, flexGrow = 1 }, {
      ui.row({
        fill     = "surface_container",
        radius   = 8,
        padding  = 3,
        align    = "center",
        gap      = 3,
      }, {
        ui.button({
          text        = "Docker",
          variant     = (not isPodman) and "primary" or "ghost",
          controlSize = "sm",
          tooltip     = (not isPodman) and "Docker engine is active" or (snapshot.busy and "Operation in progress" or "Switch engine to Docker"),
          enabled     = not snapshot.busy,
          onClick     = function()
            if isPodman then
              sendCommand("toggle_daemon", { target = "docker" })
            end
          end,
        }),
        ui.button({
          text        = "Podman",
          variant     = isPodman and "primary" or "ghost",
          controlSize = "sm",
          tooltip     = isPodman and "Podman engine is active" or (snapshot.busy and "Operation in progress" or "Switch engine to Podman"),
          enabled     = not snapshot.busy,
          onClick     = function()
            if not isPodman then
              sendCommand("toggle_daemon", { target = "podman" })
            end
          end,
        }),
      }),
      ui.label({ text = "Shipyard", fontSize = 15, fontWeight = "bold", color = "on_surface" }),
    }),
    -- Stats Pill
    ui.row({
      fill     = "surface_container",
      radius   = 8,
      paddingH = 10,
      paddingV = 4,
      align    = "center",
      tooltip  = "Combined host daemon CPU and RAM utilization",
    }, {
      ui.label({
        text       = tr("header.stats", { cpu = stats.cpu or "0%", ram = stats.ram or "0B" }),
        color      = "on_surface_variant",
        fontSize   = 11,
        fontWeight = "medium",
      }),
    }),
    -- Manual Scan & Refresh Button
    ui.button({
      text        = snapshot.isScanning and "Scanning…" or "Scan",
      glyph       = snapshot.isScanning and "loader" or "refresh",
      variant     = "outline",
      controlSize = "sm",
      tooltip     = snapshot.isScanning and "Scanning daemon and stacks in background…" or (snapshot.busy and (snapshot.activeTask and snapshot.activeTask.title or tr("tasks.in_progress")) or "Scan & Refresh All"),
      enabled     = not snapshot.isScanning and not snapshot.busy,
      onClick     = function() sendCommand("refresh") end,
    }),
    -- Settings Gear Button
    ui.button({
      glyph       = "settings",
      variant     = "ghost",
      controlSize = "sm",
      tooltip     = "Open plugin settings",
      onClick     = openPluginSettings,
    }),
  }

  if showCloseButton then
    table.insert(headerControls, ui.button({
      glyph       = "close",
      variant     = "ghost",
      controlSize = "sm",
      tooltip     = "Close panel",
      onClick     = function() panel.close() end,
    }))
  end

  -- Tabs
  local tabs = {
    { id = "stacks",         label = tr("tabs.stacks"),         glyph = "folder-code" },
    { id = "containers",     label = tr("tabs.containers"),     glyph = "box" },
    { id = "images",         label = tr("tabs.images"),         glyph = "photo" },
    { id = "infrastructure", label = tr("tabs.infrastructure"), glyph = "network" },
  }
  if isPodman then
    table.insert(tabs, { id = "pods", label = tr("tabs.pods"), glyph = "box-multiple" })
  else
    if currentTab == "pods" then currentTab = "containers" end
  end

  local tabButtons = {}
  for _, t in ipairs(tabs) do
    local isSelected = currentTab == t.id
    table.insert(tabButtons, ui.button({
      text        = t.label,
      glyph       = t.glyph,
      variant     = isSelected and "primary" or "ghost",
      controlSize = "sm",
      tooltip     = `View {t.label}`,
      onClick     = function()
        currentTab       = t.id
        launchModalImage = nil
        render()
      end,
    }))
  end

  -- Body
  local body
  if snapshot.generateOutput ~= nil then
    body = renderGenerateModal(snapshot)
  elseif snapshot.logsOutput ~= nil then
    body = renderLogsModal(snapshot)
  elseif confirmPending ~= nil then
    body = renderConfirmModal(confirmPending, snapshot)
  elseif launchModalImage ~= nil then
    body = renderLaunchModal(launchModalImage, snapshot)
  elseif currentTab == "stacks" then
    body = renderStacksTab(snapshot)
  elseif currentTab == "containers" then
    body = renderContainersTab(snapshot)
  elseif currentTab == "images" then
    body = renderImagesTab(snapshot)
  elseif currentTab == "pods" then
    body = renderPodsTab(snapshot)
  else
    body = renderInfraTab(snapshot)
  end

  local mainChildren = {
    ui.row({ key = "panel-header", align = "center", justify = "space_between", gap = 8, flexGrow = 0 }, headerControls),
  }
  local banner = renderDaemonBanner(snapshot)
  if banner then
    table.insert(mainChildren, banner)
  end
  table.insert(mainChildren, ui.row({ key = "panel-tabs", align = "center", gap = 4, flexGrow = 0 }, tabButtons))
  local taskCard = renderActiveTaskCard(snapshot.activeTask)
  if taskCard then
    table.insert(mainChildren, taskCard)
  end
  table.insert(mainChildren, body)

  panel.render(ui.column({ key = "panel-root", flexGrow = 1, gap = 10, justify = "start", align = "stretch" }, mainChildren))
end

-- ---------------------------------------------------------------------------
-- Callbacks
-- ---------------------------------------------------------------------------

function onContainerSearch(value)
  containerSearch = tostring(value or "")
  render()
end

function onImageSearch(value)
  imageSearch = tostring(value or "")
  render()
end

function onOnlineSearchInputChange(value)
  onlineSearchInput = tostring(value or "")
  render()
end

function onOnlineSearchSubmit()
  local q = noctalia.string.trim(onlineSearchInput)
  if q ~= "" then
    sendCommand("image_search_online", { query = q })
    render()
  end
end

function onLaunchNameChange(value)
  launchNameInput = tostring(value or "")
  render()
end

function onLaunchPortChange(value)
  launchPortInput = tostring(value or "")
  render()
end

function onLaunchEnvChange(value)
  launchEnvInput = tostring(value or "")
  render()
end



-- ---------------------------------------------------------------------------
-- Lifecycle Hooks
-- ---------------------------------------------------------------------------

function onOpen(context)
  showCloseButton = noctalia.getSetting("shell.show_close_buttons") ~= false
  noctalia.state.set(KEY_PANEL_OPEN, true)
  noctalia.setUpdateInterval(1000)
  confirmPending   = nil
  launchModalImage = nil

  local ctx = tostring(context or "")
  if ctx == "images" then
    currentTab   = "images"
    imageSubView = "local"
  elseif ctx == "containers" or ctx == "stacks" or ctx == "infrastructure" or ctx == "pods" then
    currentTab = ctx
  elseif ctx == "online" then
    currentTab   = "images"
    imageSubView = "online"
  elseif ctx:sub(1, 7) == "launch:" then
    local imgName = ctx:sub(8)
    currentTab   = "images"
    imageSubView = "online"
    openLaunchModal(imgName)
  end

  sendCommand("refresh")
  render()
end

function onClose()
  noctalia.state.set(KEY_PANEL_OPEN, false)
end

function update()
  local snap = noctalia.state.get(KEY_SNAPSHOT)
  if snap and snap.activeTask ~= nil then
    render()
  end
end

noctalia.state.watch(KEY_SNAPSHOT, function(val)
  render()
end)

render()
