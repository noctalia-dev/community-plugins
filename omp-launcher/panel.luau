--!nonstrict
-- Oh My Pi (omp) Interactive Panel
-- Clean layout with direct target launching and smooth focus handoff.

local dir = noctalia.pluginDir()
local LOGO_PATH   = dir .. "/omp-logo.svg"
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
  local runningCount = data.running_count or 0
  local pulse = data.pulse or "idle"
  local pulseColor = data.pulse_color or "#FFFFFF"
  local pulseLabel = data.pulse_label or "Idle"
  local activeSessions = data.active_sessions or {}
  local recentProjects = data.recent_projects or {}

  local content = {}

  -- 1. Header (Logo, Title, Multi-State Visual Pulse Badge)
  local statusBadge
  if runningCount > 0 then
    statusBadge = ui.box({
      radius = 999,
      fill = pulse == "thinking" and "#142538" or "#1f2937",
      border = pulseColor,
      padding = { top = 2, bottom = 2, left = 8, right = 8 }
    }, {
      ui.row({ gap = 5, align = "center" }, {
        ui.box({ width = 5, height = 5, radius = 3, fill = pulseColor }),
        ui.label({ text = `{runningCount} active · {pulseLabel}`, fontSize = 10.5, color = pulseColor, fontWeight = "bold" })
      })
    })
  else
    statusBadge = ui.box({
      radius = 999,
      fill = "#171c26",
      border = "#374151",
      padding = { top = 2, bottom = 2, left = 8, right = 8 }
    }, {
      ui.label({ text = "idle", fontSize = 10.5, color = "#9ca3af" })
    })
  end

  table.insert(content, ui.row({ align = "center", justify = "space-between" }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.image({ path = LOGO_PATH, width = 20, height = 20, fit = "contain" }),
      ui.label({ text = "Oh My Pi", fontSize = 15, fontWeight = "bold", color = "#FFFFFF" }),
    }),
    statusBadge
  }))

  table.insert(content, ui.separator({}))

  -- 2. Active Sessions (Resume Button Directly Targets Project Directory)
  if runningCount > 0 and #activeSessions > 0 then
    table.insert(content, ui.label({
      text = "ACTIVE SESSIONS",
      fontSize = 9.5,
      fontWeight = "bold",
      color = "#38BDF8",
      opacity = 0.95
    }))

    for i, s in ipairs(activeSessions) do
      if i > 1 then
        table.insert(content, ui.separator({}))
      end
      table.insert(content, ui.row({ align = "center", justify = "space-between" }, {
        ui.row({ gap = 7, align = "center", flexGrow = 1, maxWidth = 220 }, {
          ui.box({ width = 6, height = 6, radius = 3, fill = pulseColor }),
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

    table.insert(content, ui.separator({}))
  end

  -- 3. Recent Workspaces (Open Button Directly Targets Project Directory)
  table.insert(content, ui.label({
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
        table.insert(content, ui.separator({}))
      end
      table.insert(content, ui.row({ align = "center", justify = "space-between" }, {
        ui.column({ gap = 1, flexGrow = 1, maxWidth = 230 }, {
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

  table.insert(content, ui.separator({}))

  -- 4. Quick Actions
  table.insert(content, ui.row({ gap = 6, justify = "space-between" }, {
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

  panel.render(ui.column({ gap = 7, padding = 12 }, content))
end

noctalia.state.watch("omp_launcher", function(val)
  snapshot = val
  render()
end)

function onOpen()
  snapshot = noctalia.state.get("omp_launcher")
  render()
end
