--!nonstrict
-- Oh My Pi (omp) Interactive Panel
-- Clean layout with direct target launching and smooth focus handoff.

local dir = noctalia.pluginDir()
local ICON_PATH       = dir .. "/omp-logo.svg"
local ICON_ALERT_PATH = dir .. "/omp-logo-alert.svg"
local LAUNCH_PATH = dir .. "/omp-launch"

local snapshot = nil

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function launchTarget(targetPath, continueSession)
  local cmd = shellQuote(LAUNCH_PATH)
  noctalia.togglePanel("emiliovenegas/omp-launcher:panel")
  local args = ""
  if type(targetPath) == "string" and targetPath ~= "" then
    args = " --target " .. shellQuote(targetPath)
  end
  if continueSession then
    args = args .. " --continue"
  end
  noctalia.runAsync("sleep 0.15 && " .. cmd .. args)
end

local function render()
  local data = snapshot or {}
  local activeSessions = data.active_sessions or {}
  local recentProjects = data.recent_projects or {}
  local needsInput = data.needs_input == true

  local header = {}

  -- 1. Header (icon only: white normally, orange while a session awaits input)
  table.insert(header, ui.row({ align = "center" }, {
    ui.image({
      path = needsInput and ICON_ALERT_PATH or ICON_PATH,
      width = 20,
      height = 20,
      fit = "contain",
    }),
  }))

  table.insert(header, ui.separator({}))

  -- 2. Active Sessions (Resume Button Directly Targets Project Directory)
  local body = {}

  if #activeSessions > 0 then
    table.insert(body, ui.label({
      text = "ACTIVE SESSIONS",
      fontSize = 9.5,
      fontWeight = "bold",
      color = "#38BDF8",
      opacity = 0.95
    }))

    local rows = {}
    for i, s in ipairs(activeSessions) do
      if i > 1 then
        table.insert(rows, ui.separator({}))
      end
      table.insert(rows, ui.row({ align = "center", justify = "space_between" }, {
        ui.row({ gap = 7, align = "center", flexGrow = 1 }, {
          ui.box({ width = 6, height = 6, radius = 3, fill = s.needs_input and "#F97316" or "#38BDF8" }),
          ui.column({ gap = 1, flexGrow = 1 }, {
            ui.label({ text = s.short or "omp", fontSize = 12, fontWeight = "bold", color = "#F9FAFB", maxLines = 1 }),
            ui.label({ text = s.display or "~", fontSize = 9.5, color = "#94a3b8", maxLines = 1 }),
          })
        }),
        ui.button({
          text = "Resume",
          controlSize = "sm",
          variant = "outline",
          onClick = function() launchTarget(s.path, true) end,
        })
      }))
    end

    for _, row in ipairs(rows) do
      table.insert(body, row)
    end

    table.insert(body, ui.separator({}))
  end

  -- 3. Recent Workspaces (Open Button Directly Targets Project Directory)
  table.insert(body, ui.label({
    text = "RECENT WORKSPACES",
    fontSize = 9.5,
    fontWeight = "bold",
    color = "#94a3b8",
    opacity = 0.8
  }))

  local count = 0
  for _, p in ipairs(recentProjects) do
    if count < 4 then
      count = count + 1
      if count > 1 then
        table.insert(body, ui.separator({}))
      end
      table.insert(body, ui.row({ align = "center", justify = "space_between" }, {
        ui.column({ gap = 1, flexGrow = 1 }, {
          ui.label({ text = p.short or "project", fontSize = 11.5, fontWeight = "bold", color = "#F1F5F9", maxLines = 1 }),
          ui.label({ text = `{p.display} · {p.ago}`, fontSize = 9.5, color = "#64748b", maxLines = 1 }),
        }),
        ui.button({
          text = "Open",
          controlSize = "sm",
          variant = "ghost",
          onClick = function() launchTarget(p.path, true) end,
        })
      }))
    end
  end

  table.insert(body, ui.separator({}))

  -- 4. Quick Actions
  table.insert(body, ui.row({ gap = 6, justify = "space_between" }, {
    ui.button({
      text = "+ ~/ Home",
      controlSize = "sm",
      variant = "ghost",
      onClick = function()
        noctalia.togglePanel("emiliovenegas/omp-launcher:panel")
        noctalia.runAsync("sleep 0.15 && '" .. LAUNCH_PATH .. "' --home")
      end,
    }),
    ui.button({
      text = "+ /tmp",
      controlSize = "sm",
      variant = "ghost",
      onClick = function() launchTarget("/tmp", false) end,
    }),
    ui.button({
      text = "Picker...",
      controlSize = "sm",
      variant = "outline",
      onClick = function()
        noctalia.togglePanel("emiliovenegas/omp-launcher:panel")
        noctalia.runAsync("sleep 0.15 && '" .. LAUNCH_PATH .. "'")
      end,
    }),
  }))

  -- The root has to claim the panel height before the body gets leftover space;
  -- without it the scroll falls back to content size and the panel clips.
  table.insert(header, ui.scroll({ key = "body", gap = 7, flexGrow = 1 }, body))
  panel.render(ui.column({ gap = 7, padding = 12, flexGrow = 1 }, header))
end

noctalia.state.watch("omp_launcher", function(val)
  snapshot = val
  render()
end)

function onOpen()
  snapshot = noctalia.state.get("omp_launcher")
  render()
end
