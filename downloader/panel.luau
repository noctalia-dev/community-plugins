--!nonstrict
-- Downloader panel: a link field, video or audio, and the queue.
-- Renders "downloader.model" from service.luau and sends actions on "downloader.command".

local model = noctalia.state.get("downloader.model")
local url = ""
local mode = nil
-- A new key gives the link field a new value (ui.input is seeded only when created).
local inputKey = 0

-- The queue scrolls inside a column of the rows' height, up to what fits in the panel
-- (DESIGN.md, section 6.3). A row is this tall, more for a second status line and progress.
local LIST_MAX = 280
local LIST_GAP = 6
local ROW_HEIGHT = 56
local LINE_HEIGHT = 17
local PROGRESS_HEIGHT = 8

local STATUS_GLYPHS = {
  queued = "clock",
  running = "download",
  done = "circle-check",
  failed = "alert-circle",
  cancelled = "circle-x",
}

local function send(command)
  command.n = noctalia.nowMs()
  noctalia.state.set("downloader.command", command)
end

-- Takes the first word of the text that is a web link. With allowBare, a word that is only a
-- host name, with or without a path, also counts, and gets https:// in front.
local function cleanLink(text, allowBare)
  for word in (text or ""):gmatch("%S+") do
    word = word:gsub("^[%(%[<\"']+", ""):gsub("[%)%]>,;\"']+$", "")
    if word:match("^https?://[%w%-%.]+%.%a") then
      return word
    end
    local host = word:match("^([%w%-%.]+)") or ""
    local rest = word:sub(#host + 1)
    if allowBare and host:match("^[%w%-]+%.[%w%-%.]*%a%a$") and (rest == "" or rest:sub(1, 1) == "/") then
      return "https://" .. word
    end
  end
  return nil
end

local function isQueued(link)
  for _, job in ipairs(model and model.jobs or {}) do
    if job.url == link then
      return true
    end
  end
  return false
end

local render

local function setLink(text)
  url = text
  inputKey += 1
  render()
end

local function submit()
  local link = cleanLink(url, true)
  if link == nil then
    return
  end
  send({ action = "add", url = link, mode = mode })
  setLink("")
end

local function openPath(path)
  if model.canOpen and path then
    noctalia.runAsync({ "xdg-open", path })
  end
end

local function setupCard()
  local list = table.concat(model.missing, ", ")
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "alert-triangle", size = 20, color = "error" }),
      ui.label({ text = noctalia.tr("setup.title"), fontWeight = "semibold" }),
    }),
    ui.label({ text = noctalia.tr("setup.body", { list = list }), color = "on_surface_variant" }),
  }
  if model.installCommand then
    table.insert(children, ui.label({ text = model.installCommand, color = "on_surface_variant" }))
    table.insert(children, ui.row({ gap = 8, justify = "end" }, {
      ui.button({
        text = noctalia.tr("setup.check"),
        variant = "ghost",
        onClick = function() send({ action = "recheck" }) end,
      }),
      ui.button({
        text = noctalia.tr("setup.install"),
        glyph = "terminal-2",
        variant = "primary",
        onClick = function() noctalia.runInTerminal(model.installCommand) end,
      }),
    }))
  else
    table.insert(children, ui.label({ text = noctalia.tr("setup.manual", { list = list }) }))
  end
  return ui.column({ gap = 12, padding = 16 }, children)
end

local function statusText(job)
  if job.status == "running" then
    if job.progress >= 1 then
      return noctalia.tr("job.processing")
    end
    local parts = { `{math.floor(job.progress * 100)}%` }
    if job.speed then
      table.insert(parts, job.speed)
    end
    if job.eta then
      table.insert(parts, job.eta)
    end
    return table.concat(parts, " · ")
  elseif job.status == "failed" then
    return job.error or noctalia.tr("job.failed")
  end
  return noctalia.tr("job." .. job.status)
end

local function jobRow(job)
  local actions = {}
  if job.status == "running" or job.status == "queued" then
    table.insert(actions, ui.button({
      glyph = "x",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("job.cancel"),
      onClick = function() send({ action = "cancel", id = job.id }) end,
    }))
  else
    if job.status == "done" and model.canOpen and job.file then
      table.insert(actions, ui.button({
        glyph = "player-play",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("job.open"),
        onClick = function() openPath(job.file) end,
      }))
    end
    if job.status ~= "done" then
      table.insert(actions, ui.button({
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("job.retry"),
        onClick = function() send({ action = "retry", id = job.id }) end,
      }))
    end
    table.insert(actions, ui.button({
      glyph = "trash",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("job.remove"),
      onClick = function() send({ action = "remove", id = job.id }) end,
    }))
  end

  local color = job.status == "failed" and "error" or (job.status == "running" and "primary" or "on_surface_variant")
  local failed = job.status == "failed"
  local height = ROW_HEIGHT + (failed and LINE_HEIGHT or 0)
  local text = {
    ui.label({ text = job.title or job.url, maxLines = 1 }),
    ui.label({ text = statusText(job), color = failed and "error" or "on_surface_variant", maxLines = failed and 2 or 1 }),
  }
  if job.status == "running" then
    table.insert(text, ui.progress({ progress = job.progress, height = 4 }))
    height += PROGRESS_HEIGHT
  end

  return ui.row({ key = job.id, gap = 10, align = "center", padding = 8, radius = 8, fill = "surface_container/0.6",
    height = height }, {
    ui.glyph({ name = STATUS_GLYPHS[job.status] or "download", size = 18, color = color }),
    ui.column({ gap = 4, flexGrow = 1 }, text),
    ui.row({ gap = 2 }, actions),
  }), height
end

local function queue()
  if #model.jobs == 0 then
    return ui.column({ gap = 4 }, {
      ui.label({ text = noctalia.tr("panel.empty"), color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("panel.sites"), color = "on_surface_variant" }),
    })
  end
  local rows, height = {}, -LIST_GAP
  local finished = 0
  -- Newest first.
  for index = #model.jobs, 1, -1 do
    local job = model.jobs[index]
    local row, rowHeight = jobRow(job)
    table.insert(rows, row)
    height += rowHeight + LIST_GAP
    if job.status ~= "running" and job.status ~= "queued" then
      finished += 1
    end
  end
  local children = {
    ui.column({ height = math.min(height, LIST_MAX) }, {
      ui.scroll({ key = "queue", gap = LIST_GAP, flexGrow = 1 }, rows),
    }),
  }
  if finished > 0 then
    table.insert(children, ui.row({ justify = "end" }, {
      ui.button({
        text = noctalia.tr("panel.clear"),
        variant = "ghost",
        controlSize = "sm",
        onClick = function() send({ action = "clear" }) end,
      }),
    }))
  end
  return ui.column({ gap = 6 }, children)
end

local function modeButton(value, glyph)
  return ui.button({
    text = noctalia.tr("mode." .. value),
    glyph = glyph,
    variant = mode == value and "secondary" or "ghost",
    selected = mode == value,
    controlSize = "sm",
    onClick = function()
      mode = value
      render()
    end,
  })
end

local function form()
  local link = cleanLink(url, true)
  local hint
  if url ~= "" and link == nil then
    hint = noctalia.tr("panel.not_a_link")
  else
    hint = noctalia.tr("panel.saves_to", { folder = model.folderLabel })
  end

  return ui.column({ gap = 8 }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = "link-" .. inputKey,
        value = url,
        placeholder = noctalia.tr("panel.placeholder"),
        focus = true,
        flexGrow = 1,
        onChange = function(text)
          url = text
          render()
        end,
        onSubmit = function() submit() end,
      }),
      ui.button({
        glyph = "clipboard",
        variant = "ghost",
        tooltip = noctalia.tr("panel.paste"),
        onClick = function() setLink(noctalia.clipboardText() or "") end,
      }),
    }),
    ui.row({ gap = 6, align = "center" }, {
      modeButton("video", "movie"),
      modeButton("audio", "music"),
      ui.spacer({ flexGrow = 1 }),
      ui.button({
        text = noctalia.tr("panel.download"),
        glyph = "download",
        variant = "primary",
        enabled = link ~= nil,
        onClick = function() submit() end,
      }),
    }),
    ui.label({ text = hint, color = url ~= "" and link == nil and "error" or "on_surface_variant", maxLines = 1 }),
  })
end

render = function()
  if model == nil then
    panel.render(ui.column({ padding = 16 }, {
      ui.label({ text = noctalia.tr("panel.loading"), color = "on_surface_variant" }),
    }))
    return
  end
  if not model.ready then
    panel.render(setupCard())
    return
  end

  local header = { ui.glyph({ name = "download", size = 20, color = "primary" }),
    ui.label({ text = noctalia.tr("panel.title"), fontWeight = "semibold" }),
    ui.spacer({ flexGrow = 1 }),
  }
  if model.canOpen then
    table.insert(header, ui.button({
      glyph = "folder",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.open_folder"),
      onClick = function() openPath(model.folder) end,
    }))
  end

  panel.render(ui.column({ gap = 12, padding = 16 }, {
    ui.row({ gap = 8, align = "center" }, header),
    form(),
    ui.separator({}),
    queue(),
  }))
end

noctalia.state.watch("downloader.model", function(value)
  model = value
  if mode == nil and model then
    mode = model.lastMode
  end
  render()
end)

function onOpen(_context)
  send({ action = "recheck" })
  model = noctalia.state.get("downloader.model") or model
  mode = mode or (model and model.lastMode) or "video"
  -- Offer the link on the clipboard, unless it is already in the queue.
  if url == "" then
    local link = cleanLink(noctalia.clipboardText())
    if link and not isQueued(link) then
      setLink(link)
      return
    end
  end
  render()
end
