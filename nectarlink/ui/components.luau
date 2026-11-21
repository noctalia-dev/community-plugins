--!nonstrict
-- Shared UI elements; no HTTP, credentials or independent phone state.
-- panel.luau owns model; only explicit click handlers call send.
local palette = require("./palette.luau")
local M = {}
local geometry = {
  panelWidth = 860,
  hostPadding = 16,
  framePadding = 3,
  navigationSpace = 52,
  sidebarSpace = 270,
  pageHeight = 398,
}
M.layout = geometry

function M.new(model, send)
  -- Display fixed error codes, never HTTP bodies, credentials or OS errors.
  local failures = {
    auth_changed = {
      noctalia.tr("errors.auth_changed.title"),
      noctalia.tr("errors.auth_changed.body"),
    },
    credentials_missing = {
      noctalia.tr("errors.credentials_missing.title"),
      noctalia.tr("errors.credentials_missing.body"),
    },
    credentials_invalid = {
      noctalia.tr("errors.credentials_invalid.title"),
      noctalia.tr("errors.credentials_invalid.body"),
    },
    api_unavailable = {
      noctalia.tr("errors.api_unavailable.title"),
      noctalia.tr("errors.api_unavailable.body"),
    },
    unauthorized = {
      noctalia.tr("errors.unauthorized.title"),
      noctalia.tr("errors.unauthorized.body"),
    },
    unsupported = {
      noctalia.tr("errors.unsupported.title"),
      noctalia.tr("errors.unsupported.body"),
    },
    invalid_response = {
      noctalia.tr("errors.invalid_response.title"),
      noctalia.tr("errors.invalid_response.body"),
    },
    permission = {
      noctalia.tr("errors.permission.title"),
      noctalia.tr("errors.permission.body"),
    },
    phone_offline = {
      noctalia.tr("common.disconnected"),
      noctalia.tr("errors.phone_offline.body"),
    },
    timeout = {
      noctalia.tr("errors.timeout.title"),
      noctalia.tr("errors.timeout.body"),
    },
    request_failed = {
      noctalia.tr("errors.request_failed.title"),
      noctalia.tr("errors.request_failed.body"),
    },
  }
  local function failure(code)
    local info = failures[code] or failures.request_failed
    return info[1], info[2]
  end
  local titles = {
    home = noctalia.tr("pages.home"),
    messages = noctalia.tr("pages.messages"),
    calls = noctalia.tr("pages.calls"),
    photos = noctalia.tr("pages.photos"),
    apps = noctalia.tr("pages.apps"),
    deck = noctalia.tr("pages.deck"),
    guide = noctalia.tr("pages.guide"),
  }

  local directions = {
    incoming = noctalia.tr("calls.incoming"),
    outgoing = noctalia.tr("calls.outgoing"),
    missed = noctalia.tr("calls.missed"),
    rejected = noctalia.tr("calls.rejected"),
    ringing = noctalia.tr("calls.ringing"),
    active = noctalia.tr("calls.active"),
  }

  local deckLabels = {
    ["Play / pause"] = noctalia.tr("deck.play_pause"),
    Previous = noctalia.tr("deck.previous"),
    Next = noctalia.tr("deck.next"),
    ["Volume up"] = noctalia.tr("deck.volume_up"),
    ["Volume down"] = noctalia.tr("deck.volume_down"),
  }

  local deckGlyphs = {
    media_play_pause = "player-play",
    media_next = "player-skip-forward",
    media_previous = "player-skip-back",
    volume_up = "volume",
    volume_down = "volume-2",
    lock_pc = "lock",
    run_command = "terminal",
    launch_app = "apps",
  }

  local function activeSession(session, kind)
    local state = session and session[kind]
    return type(state) == "string" and state ~= "off" and state ~= "ended"
  end

  local function setting(key)
    return noctalia.getConfig(key) ~= false
  end

  local function appsLayout()
    local names = noctalia.getConfig("apps_display") ~= "icons"
    local side = names and 64 or 48
    local width = 822 - (setting("panel_navigation") and 52 or 0) - 12
    local columns = math.floor((width + 6) / (side + 6))
    local rows = math.floor((274 + 6) / (side + 6))
    return {
      names = names,
      side = side,
      columns = columns,
      rows = rows,
      limit = math.min(96, columns * rows),
      gap = (width - columns * side) / (columns - 1),
    }
  end

  local function preview(text, limit)
    text = type(text) == "string" and text or ""
    text = text
      :gsub("\194\133", " ")
      :gsub("\226\128[\168\169]", " ")
      :gsub("[%c%s]+", " ")
      :gsub("^ +", "")
      :gsub(" +$", "")
    local valid, length = pcall(utf8.len, text)
    if not valid or not length then
      text = text:gsub("[\128-\255]", "?")
    end
    local cut = utf8.offset(text, limit + 1)
    return cut and (text:sub(1, cut - 1) .. "…") or text
  end

  local function label(text, size, color, bold, width)
    return ui.label({
      text = preview(text, 96),
      height = math.ceil((size or 12) * 1.4),
      fontFamily = "sans-serif",
      fontSize = size or 12,
      color = color or "on_surface",
      fontWeight = bold and "bold" or nil,
      maxLines = 1,
      maxWidth = width or 244,
    })
  end

  local function smallButton(text, callback, enabled)
    return ui.button({
      text = text,
      controlSize = "sm",
      height = 32,
      fontSize = 11,
      variant = "ghost",
      enabled = enabled ~= false,
      onClick = enabled ~= false and callback or nil,
    })
  end

  local function pager(width, index, back, nextPage, canBack, canNext, key)
    return ui.row(
      { key = key or "page-pagination", width = width, height = 32, align = "center" },
      {
        ui.button({
          key = "pager-prev",
          glyph = "chevron-left",
          width = 32,
          height = 32,
          variant = "ghost",
          tooltip = noctalia.tr("common.previous_page"),
          enabled = canBack,
          onClick = canBack and back or nil,
        }),
        ui.spacer({ flexGrow = 1 }),
        ui.column(
          { key = "page-number", width = 40, height = 28, align = "center", justify = "center" },
          { label(tostring(index), 12, "on_surface_variant", false, 40) }
        ),
        ui.spacer({ flexGrow = 1 }),
        ui.button({
          key = "pager-next",
          glyph = "chevron-right",
          width = 32,
          height = 32,
          variant = "ghost",
          tooltip = noctalia.tr("common.next_page"),
          enabled = canNext,
          onClick = canNext and nextPage or nil,
        }),
      }
    )
  end

  local function pageNote(title, text, glyph, height, width)
    return ui.row({
      height = height or 72,
      gap = 10,
      padding = 10,
      radius = 10,
      fill = palette("card"),
    }, {
      ui.glyph({ name = glyph or "info-circle", size = 20, color = "primary" }),
      ui.column({ gap = 4, flexGrow = 1 }, {
        label(title, 13, "on_surface", true, width - 50),
        ui.label({
          text = text,
          fontFamily = "sans-serif",
          fontSize = 12,
          height = (height or 72) - 36,
          maxLines = 3,
          maxWidth = width - 50,
          color = "on_surface_variant",
        }),
      }),
    })
  end

  local function badge(text, glyph, width)
    return ui.row({
      gap = 4,
      align = "center",
      paddingH = 6,
      paddingV = 3,
      radius = 10,
      fill = palette("raised"),
    }, {
      ui.glyph({ name = glyph, size = 14, color = "on_surface_variant" }),
      label(text, 11, "on_surface_variant", false, (width or 244) - 30),
    })
  end

  local function tile(key, text, glyph, command, enabled, reason, device, value, active, width)
    return ui.column({
      key = key,
      gap = 4,
      padding = 8,
      radius = 12,
      width = width or model.tileWidth,
      height = 68,
      opacity = enabled and 1 or 0.48,
      fill = (active or model.hovered == key) and "primary/0.18" or palette("card"),
      border = active and "primary/0.5" or palette("card"),
      borderWidth = 1,
      tooltip = reason or text,
      onHover = "onTileHover",
      onClick = enabled and function()
        send(command, device, value)
      end or nil,
    }, {
      ui.row({ justify = "start" }, {
        ui.column({
          width = 20,
          height = 20,
          radius = 10,
          fill = "primary/0.15",
          align = "center",
          justify = "center",
        }, {
          ui.glyph({ name = glyph, size = 14, color = "primary" }),
        }),
      }),
      ui.label({
        text = text,
        height = 28,
        fontFamily = "sans-serif",
        fontSize = 11,
        fontWeight = "bold",
        maxLines = 2,
        maxWidth = (width or model.tileWidth) - 16,
        color = "on_surface",
      }),
    })
  end
  return {
    activeSession = activeSession,
    setting = setting,
    appsLayout = appsLayout,
    preview = preview,
    label = label,
    smallButton = smallButton,
    pager = pager,
    pageNote = pageNote,
    failure = failure,
    badge = badge,
    tile = tile,
    titles = titles,
    directions = directions,
    deckLabels = deckLabels,
    deckGlyphs = deckGlyphs,
  }
end
return M
