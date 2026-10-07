--!nonstrict
-- HerdR panel tree builder.

local M = {}

local STATUS_META = {
  blocked = { glyph = "alert-circle", color = "error", key = "status.blocked" },
  done = { glyph = "circle-check", color = "tertiary", key = "status.done" },
  working = { glyph = "loader-2", color = "primary", key = "status.working" },
  idle = { glyph = "circle-dot", color = "on_surface_variant", key = "status.idle" },
  none = { glyph = "terminal", color = "on_surface_variant", key = "status.no_agent" },
  unknown = { glyph = "help-circle", color = "on_surface_variant", key = "status.unknown" },
}

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

-- The colors are declared on the bar widget, which republishes them into plugin
-- state; the panel runtime never sees widget-declared settings directly. Read them
-- once per build and fall back to the STATUS_META defaults.
local sharedColors = {}

local function isRoleToken(color)
  return type(color) == "string" and color:sub(1, 1) ~= "#" and not color:find("/")
end

local function getRadius(baseRadius)
  if noctalia.getSetting then
    local scale = noctalia.getSetting("shell.corner_radius_scale")
    if type(scale) == "number" then
      return math.floor(baseRadius * scale)
    end
  end
  return baseRadius
end

local function loadSharedColors()
  local settings = noctalia.state.get("herdr.settings")
  sharedColors = type(settings) == "table" and settings or {}
end

local function statusMeta(status)
  local base = STATUS_META[status] or STATUS_META.unknown
  local customColor = nil
  if status == "blocked" then
    customColor = sharedColors.color_blocked
  elseif status == "done" then
    customColor = sharedColors.color_done
  elseif status == "working" then
    customColor = sharedColors.color_working
  end
  if type(customColor) == "string" and customColor ~= "" then
    return { glyph = base.glyph, color = customColor, key = base.key }
  end
  return base
end

local function statusLabel(status)
  return tr(statusMeta(status).key)
end

local function messageCard(glyph, text, color)
  return ui.row({
    gap = 9,
    align = "center",
    padding = 10,
    radius = getRadius(8),
    fill = "surface_variant/0.35",
  }, {
    ui.glyph({ name = glyph, size = 19, color = color or "on_surface_variant" }),
    ui.label({
      text = text,
      color = "on_surface_variant",
      fontSize = 12,
      flexGrow = 1,
    }),
  })
end

function M.build(snapshot, options)
  snapshot = type(snapshot) == "table" and snapshot or {}
  options = type(options) == "table" and options or {}
  loadSharedColors()

  local function request(action, sessionName, pane)
    if type(options.request) == "function" then
      options.request(action, sessionName, pane)
    end
  end

  local function setPendingDelete(value)
    if type(options.setPendingDelete) == "function" then
      options.setPendingDelete(value)
    end
  end

  local function rerender()
    if type(options.rerender) == "function" then
      options.rerender()
    end
  end

  local function actionBusyFor(sessionName)
    local action = snapshot.action
    return type(action) == "table" and action.status == "busy" and action.session == sessionName
  end

  local function header()
    local subtitle = tr("panel.summary", {
      sessions = tostring(snapshot.running or 0),
      agents = tostring(snapshot.agents or 0),
    })

    return ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "robot", size = 22, color = "primary" }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = tr("panel.title"), fontSize = 16, fontWeight = "bold" }),
        ui.label({ text = subtitle, fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        tooltip = tr("actions.refresh"),
        enabled = snapshot.refreshing ~= true,
        onClick = function()
          request("refresh")
        end,
      }),
      ui.button({
        glyph = "close",
        variant = "ghost",
        controlSize = "sm",
        tooltip = tr("actions.close"),
        onClick = options.onClose,
      }),
    })
  end

  -- A pane inside a workspace that has more than one: the workspace is already named
  -- by the header above, so a child row only carries its own tab and title.
  local function paneRow(session, pane)
    local meta = statusMeta(pane.status)
    local attention = pane.status == "blocked" or pane.status == "done"
    local remote = session.remote == true
    local tab = pane.tab ~= nil and pane.tab ~= "" and pane.tab or tostring(pane.pane or "")
    local title = pane.title ~= nil and pane.title ~= "" and pane.title or tostring(pane.pane or "")

    return ui.row({
      key = "pane-" .. session.name .. "-" .. tostring(pane.pane),
      gap = 8,
      align = "center",
      padding = 7,
      radius = getRadius(6),
      -- A child row sits on surface_variant rather than the panel's own surface, so it
      -- reads as a lighter card nested inside its workspace instead of blending into
      -- the panel background.
      -- Noctalia only supports alpha suffixes on role tokens; fall back to surface_variant if custom hex.
      fill = attention and (isRoleToken(meta.color) and (meta.color .. "/0.10") or "surface_variant/0.24")
        or "surface_variant/0.16",
      onClick = remote and nil or function()
        request("focus_agent", session.name, pane.pane)
      end,
    }, {
      ui.glyph({ name = meta.glyph, size = 13, color = meta.color }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({
          text = title,
          fontSize = 11,
          fontWeight = attention and "bold" or "medium",
          color = attention and meta.color or "on_surface",
          maxLines = 2,
        }),
        ui.label({
          text = tab,
          fontSize = 9,
          color = "on_surface_variant",
          maxLines = 1,
        }),
      }),
      ui.label({
        text = statusLabel(pane.status),
        color = meta.color,
        fontWeight = attention and "bold" or "medium",
        fontSize = 10,
        maxLines = 1,
      }),
    })
  end

  -- The workspace itself: named, with its aggregate state, and named again by the
  -- panes underneath when it holds more than one.
  local function workspaceHeader(session, group)
    local meta = statusMeta(group.status)
    local attention = group.status == "blocked" or group.status == "done"
    local panes = tonumber(group.panes) or #(group.children or {})
    local agents = tonumber(group.agents) or 0
    local meta_text = tr("panel.workspace_meta", {
      panes = noctalia.trp("panel.workspace_panes", panes),
      agents = noctalia.trp("panel.workspace_agents", agents),
    })

    return ui.row({
      key = "ws-" .. session.name .. "-" .. tostring(group.id),
      gap = 8,
      align = "center",
      padding = 8,
      radius = getRadius(7),
      fill = attention and (isRoleToken(meta.color) and (meta.color .. "/0.10") or "surface_variant/0.40")
        or "surface_variant/0.30",
    }, {
      ui.glyph({ name = meta.glyph, size = 16, color = meta.color }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = group.label, fontSize = 12, fontWeight = "bold" }),
        ui.label({ text = meta_text, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
      }),
      ui.label({
        text = statusLabel(group.status),
        color = meta.color,
        fontWeight = attention and "bold" or "medium",
        fontSize = 11,
        maxLines = 1,
      }),
    })
  end

  -- A workspace that holds exactly one pane is one row: the workspace, with the pane's
  -- own title underneath and nothing nested below it.
  local function workspaceOnlyRow(session, group, pane)
    local meta = statusMeta(group.status)
    local attention = group.status == "blocked" or group.status == "done"
    local remote = session.remote == true
    local detail = pane ~= nil and pane.title ~= nil and pane.title ~= "" and pane.title
      or (pane ~= nil and pane.tab ~= nil and pane.tab ~= "" and pane.tab or "")
    local clickable = pane ~= nil and not remote

    return ui.row({
      key = "ws-" .. session.name .. "-" .. tostring(group.id),
      gap = 8,
      align = "center",
      padding = 8,
      radius = getRadius(7),
      -- Same fill as a multi-pane workspace header: a workspace looks like a workspace
      -- whether it holds one pane or several.
      fill = attention and (isRoleToken(meta.color) and (meta.color .. "/0.10") or "surface_variant/0.40")
        or "surface_variant/0.30",
      onClick = clickable and function()
        request("focus_agent", session.name, pane.pane)
      end or nil,
    }, {
      ui.glyph({ name = meta.glyph, size = 16, color = meta.color }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = group.label, fontSize = 12, fontWeight = "bold" }),
        ui.label({ text = detail, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
      }),
      ui.label({
        text = statusLabel(group.status),
        color = meta.color,
        fontWeight = attention and "bold" or "medium",
        fontSize = 11,
        maxLines = 1,
      }),
    })
  end

  -- Multi-pane workspaces nest their panes; single-pane workspaces stay one row.
  -- The test is the workspace's real pane count, so a workspace with two panes keeps
  -- its shape even while hide_agentless_panes hides the pane that runs no agent.
  local function workspaceBlock(session, group)
    local children = group.children or {}
    local paneCount = tonumber(group.panes) or #children

    if paneCount <= 1 then
      return workspaceOnlyRow(session, group, children[1])
    end

    local rows = {}
    for _, pane in ipairs(children) do
      table.insert(rows, paneRow(session, pane))
    end

    return ui.column({ gap = 6 }, {
      workspaceHeader(session, group),
      ui.column({ gap = 4, paddingH = 10 }, rows),
    })
  end

  local function sessionActions(session)
    local busy = actionBusyFor(session.name)

    if session.running == true then
      return {
        ui.button({
          text = tr("actions.stop"),
          glyph = "player-stop",
          variant = "ghost",
          controlSize = "sm",
          enabled = not busy,
          onClick = function()
            request("stop_session", session.name)
          end,
        }),
      }
    end

    local actions = {}
    if session.is_default ~= true then
      if options.pendingDelete == session.name then
        table.insert(actions, ui.button({
          text = tr("actions.cancel"),
          variant = "ghost",
          controlSize = "sm",
          onClick = function()
            setPendingDelete(nil)
            rerender()
          end,
        }))
        table.insert(actions, ui.button({
          text = tr("actions.confirm_delete"),
          glyph = "trash",
          variant = "destructive",
          controlSize = "sm",
          enabled = not busy,
          onClick = function()
            setPendingDelete(nil)
            request("delete_session", session.name)
            rerender()
          end,
        }))
      else
        table.insert(actions, ui.button({
          glyph = "trash",
          variant = "ghost",
          controlSize = "sm",
          tooltip = tr("actions.delete"),
          enabled = not busy,
          onClick = function()
            setPendingDelete(session.name)
            rerender()
          end,
        }))
      end
    end

    return actions
  end

  local function sessionStatus(session)
    if session.running ~= true then
      return "unknown"
    end
    for _, status in ipairs({ "blocked", "done", "working", "idle", "unknown" }) do
      if (tonumber(session[status]) or 0) > 0 then
        return status
      end
    end
    return "idle"
  end

  local function sessionCard(session)
    local children = {}
    local isRemote = session.remote == true
    local loudest = statusMeta(sessionStatus(session))
    local runningColor = session.running == true and loudest.color or "on_surface_variant"
    local runningGlyph = "circle"
    if isRemote then
      runningGlyph = "server"
    elseif session.running == true then
      runningGlyph = "circle-filled"
    end

    local subtitle
    if isRemote then
      subtitle = type(session.target) == "string" and session.target ~= "" and session.target
        or tr("panel.machine")
    elseif session.running == true then
      subtitle = tr("status.running")
    else
      subtitle = tr("status.stopped")
    end

    local headerChildren = {
      ui.glyph({ name = runningGlyph, size = 12, color = runningColor }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = session.name, fontWeight = "bold", fontSize = 13 }),
        ui.label({
          text = subtitle,
          color = "on_surface_variant",
          fontSize = 10,
          maxLines = 1,
        }),
      }),
    }

    -- Another machine's session cannot be stopped or deleted from here.
    if not isRemote then
      table.insert(headerChildren, ui.row({ gap = 5, align = "center" }, sessionActions(session)))
    end

    table.insert(children, ui.row({
      gap = 8,
      align = "center",
      onClick = isRemote and nil or function()
        request("open_session", session.name)
      end,
    }, headerChildren))

    -- Saved workspace names are not listed as a text blob: each visible row
    -- already shows its own workspace and tab.
    if session.running ~= true and #(session.projects or {}) == 0 then
      table.insert(children, ui.label({
        text = tr("panel.nothing_saved"),
        color = "on_surface_variant",
        fontSize = 11,
      }))
    end

    if session.running == true then
      table.insert(children, ui.label({
        text = tr("panel.session_counts", {
          agents = tostring(session.agents or 0),
          blocked = tostring(session.blocked or 0),
          done = tostring(session.done or 0),
          working = tostring(session.working or 0),
        }),
        color = "on_surface_variant",
        fontSize = 10,
      }))

      for _, group in ipairs(session.workspace_list or {}) do
        table.insert(children, workspaceBlock(session, group))
      end
    end

    if session.stale == true then
      table.insert(children, messageCard(
        "alert-triangle",
        tr("panel.stale", { error = tostring(session.error or tr("error.command_failed")) }),
        "error"
      ))
    end

    return ui.column({
      key = "session-" .. session.name,
      gap = 7,
      padding = 10,
      radius = getRadius(9),
      fill = "surface_variant/0.22",
    }, children)
  end

  local body = {}

  if snapshot.available ~= true then
    table.insert(body, messageCard(
      "alert-triangle",
      snapshot.error or tr("error.herdr_missing"),
      "error"
    ))
  elseif type(snapshot.error) == "string" and snapshot.error ~= "" then
    table.insert(body, messageCard("alert-triangle", snapshot.error, "error"))
  end

  if snapshot.available == true and #(snapshot.sessions or {}) == 0 and snapshot.refreshing ~= true then
    table.insert(body, messageCard("inbox", tr("panel.empty"), "on_surface_variant"))
  end

  for _, session in ipairs(snapshot.sessions or {}) do
    table.insert(body, sessionCard(session))
  end

  local action = snapshot.action
  if type(action) == "table" and action.status == "error" and type(action.message) == "string" then
    table.insert(body, messageCard("alert-circle", action.message, "error"))
  end

  return ui.column({ gap = 10, flexGrow = 1, align = "stretch" }, {
    header(),
    ui.separator({}),
    ui.scroll({ flexGrow = 1, align = "stretch", gap = 9 }, body),
  })
end

return M
