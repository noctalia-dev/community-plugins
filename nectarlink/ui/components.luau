--!nonstrict
-- Shared UI elements; no HTTP, credentials or independent phone state.
-- panel.luau owns model; only explicit click handlers call send.
local palette = require("./palette.luau")
local M = {}
-- The manifest specifies the outer size. Noctalia adds its own panel padding.
local geometry = {
  panelWidth = 1104,
  panelHeight = 560,
  hostPadding = 16,
  framePadding = 4,
  gap = 10,
  navigationWidth = 52,
  activityWidth = 352,
}
geometry.frameWidth = geometry.panelWidth - 2 * geometry.hostPadding
geometry.frameHeight = geometry.panelHeight - 2 * geometry.hostPadding
geometry.bodyWidth = geometry.frameWidth - 2 * geometry.framePadding
geometry.bodyHeight = geometry.frameHeight - 2 * geometry.framePadding

-- Photos keep a separate pager; apps fit it in the search toolbar.
local page = {
  padding = 10,
  gap = 8,
  heading = 48,
  toolbar = 40,
  pager = 32,
  notice = 16,
  callRow = 54,
  itemGap = 6,
  limits = { messages = 7, thread = 6, calls = 6, photos = 8, deck = 192 },
}
page.body = geometry.bodyHeight - 2 * page.padding - page.heading - page.gap
page.gallery = page.body - page.toolbar - page.notice - page.pager - 4 * page.gap
page.appGrid = page.body - page.toolbar - page.notice - 2 * page.gap
geometry.page = page

function geometry.contentWidth(navigation)
  return geometry.bodyWidth - (navigation and (geometry.navigationWidth + geometry.gap) or 0)
end

function geometry.appsLayout()
  local names = noctalia.getConfig("apps_display") ~= "icons"
  local minWidth, height = names and 99 or 50, names and 88 or 56
  local width = geometry.contentWidth(noctalia.getConfig("panel_navigation") ~= false) - 2 * page.padding
  local gap = page.itemGap
  local columns = math.floor((width + gap) / (minWidth + gap))
  local rows = math.floor((page.appGrid + gap) / (height + gap))
  local cellWidth = math.floor((width - (columns - 1) * gap) / columns)
  return {
    names = names, width = cellWidth, height = height, columns = columns, rows = rows,
    limit = math.min(96, columns * rows), gap = (width - columns * cellWidth) / (columns - 1),
  }
end

M.layout = geometry

function M.new()
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
    loopback_proxy = {
      noctalia.tr("errors.loopback_proxy.title"),
      noctalia.tr("errors.loopback_proxy.body"),
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
    private_api_disabled = {
      noctalia.tr("errors.permission.title"),
      noctalia.tr("errors.private_api_disabled.body"),
    },
    sms_unavailable = {
      noctalia.tr("messages.sms_not_loaded"),
      noctalia.tr("errors.sms_unavailable.body"),
    },
    local_chats_unavailable = {
      noctalia.tr("messages.local_chats_not_loaded"),
      noctalia.tr("errors.local_chats_unavailable.body"),
    },
    photo_details_unavailable = {
      noctalia.tr("errors.photo_details_unavailable.title"),
      noctalia.tr("errors.photo_details_unavailable.body"),
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
  for _, code in ipairs({ "apps_elevated", "feature_toggle_disabled", "feature_unsupported",
    "feature_update_phone", "feature_update_desktop", "chat_unavailable", "sms_denied" }) do
    local key = "errors." .. code
    failures[code] = { noctalia.tr(key .. ".title"), noctalia.tr(key .. ".body") }
  end
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

  local function appTileFill(hovered)
    return hovered and "primary/0.16" or palette("raised", 0.72)
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

  local function iconBadge(glyph, side, color, fill, glyphSize)
    return ui.column({
      width = side, height = side, radius = 9, align = "center", justify = "center",
      fill = fill or "primary/0.12",
    }, {
      ui.glyph({ name = glyph, size = glyphSize or 19, color = color or "primary" }),
    })
  end

  local function pageSteps(index, back, nextPage, canBack, canNext, key, prefix)
    return ui.row({
      key = key or "page-pagination",
      width = 104, height = page.pager, gap = 4, align = "center",
      fill = palette("raised", 0.72), radius = 9,
    }, {
      ui.button({
        key = prefix and (prefix .. "-prev") or "pager-prev",
        glyph = "chevron-left",
        width = 32,
        height = 32,
        variant = "ghost",
        tooltip = noctalia.tr("common.previous_page"),
        enabled = canBack,
        onClick = canBack and back or nil,
      }),
      ui.column({
        key = prefix and (prefix .. "-number") or "page-number",
        width = 32, height = 28, align = "center", justify = "center",
      }, { label(tostring(index), 12, "on_surface", true, 32) }),
      ui.button({
        key = prefix and (prefix .. "-next") or "pager-next",
        glyph = "chevron-right",
        width = 32,
        height = 32,
        variant = "ghost",
        tooltip = noctalia.tr("common.next_page"),
        enabled = canNext,
        onClick = canNext and nextPage or nil,
      }),
    })
  end

  local function pageNote(title, text, glyph, width, height, tone, key)
    local textWidth = width - 82
    return ui.row({
      key = key,
      width = width,
      height = height,
      gap = 12,
      padding = 14,
      radius = 12,
      align = "center",
      fill = palette("raised", 0.72),
    }, {
      iconBadge(glyph, 42, tone, tone == "error" and "error/0.14" or nil, 22),
      ui.column({ width = textWidth, gap = 5 }, {
        label(title, 15, "on_surface", true, textWidth),
        ui.label({
          text = text,
          fontFamily = "sans-serif",
          fontSize = 12,
          maxLines = 3,
          maxWidth = textWidth,
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

  return {
    activeSession = activeSession,
    setting = setting,
    appsLayout = geometry.appsLayout,
    appTileFill = appTileFill,
    preview = preview,
    label = label,
    smallButton = smallButton,
    pageSteps = pageSteps,
    pageNote = pageNote,
    iconBadge = iconBadge,
    failure = failure,
    badge = badge,
    titles = titles,
    directions = directions,
    deckLabels = deckLabels,
    deckGlyphs = deckGlyphs,
  }
end
return M
