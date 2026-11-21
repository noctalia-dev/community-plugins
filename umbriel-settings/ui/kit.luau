--!nonstrict
-- Shared building blocks: page header, cards, badges, notices and empty states.
local M = {}

M.MUTED = "on_surface_variant"
-- Design tokens: use these instead of literal sizes, so pages stay consistent and radii follow Noctalia's
-- corner roundness ([shell] corner_radius_scale): the plugin scales M.RADIUS (setRadiusScale), the app scales
-- radii in CSS (--radius-scale) and keeps the base values here.
local BASE_RADIUS = { sm = 6, md = 10, lg = 12 }
M.RADIUS = {}

-- Like Noctalia: anything but a number is 1, clamped to [0, 2].
function M.setRadiusScale(scale)
  scale = type(scale) == "number" and math.min(math.max(scale, 0), 2) or 1
  for name, value in pairs(BASE_RADIUS) do M.RADIUS[name] = value * scale end
end
M.setRadiusScale(1)

-- Rows a capped list shows at most, so one render stays inside Noctalia's 25 ms callback budget.
M.LIST_CAP = 40

M.FONT = { tiny = 10, caption = 11, small = 12, body = 13, item = 14, large = 16, title = 18 }
-- Glyph sizes: inline with small text, in notices and buttons, page and card heads, list rows, empty states.
M.GLYPH = { small = 14, body = 16, large = 18, row = 20, empty = 32 }

function M.label(text, props)
  props = props or {}
  props.text = text
  props.fontSize = props.fontSize or M.FONT.body
  return ui.label(props)
end

function M.muted(text, props)
  props = props or {}
  props.color = props.color or M.MUTED
  props.fontSize = props.fontSize or M.FONT.small
  return M.label(text, props)
end

local function titleLabel(text, size)
  return ui.label({ text = text, fontSize = size or M.FONT.title, fontWeight = "bold", color = "primary" })
end

-- A small rounded tag such as "3 changed" or "restart".
function M.badge(text, color, key)
  return ui.row({ key = key, paddingH = 8, paddingV = 2, radius = M.RADIUS.md, fill = (color or "primary") .. "/0.18",
                  align = "center" }, {
    ui.label({ text = text, fontSize = M.FONT.caption, color = color or "primary", fontWeight = "bold" }),
  })
end

-- Noctalia's settings badge for a key that differs from the default.
function M.overrideBadge(key)
  return ui.row({ key = key, paddingH = 8, paddingV = 2, radius = M.RADIUS.sm, fill = "primary_container", align = "center",
                  tooltip = "Set in your config; differs from Umbriel's default" }, {
    ui.label({ text = "Override", fontSize = M.FONT.caption, color = "on_primary_container", fontWeight = "bold" }),
  })
end

-- Cards carry a thin outline so they stand out from the page; their padding is that much smaller to keep the height.
M.CARD_BORDER, M.CARD_BORDER_WIDTH = "outline_variant", 1

local function cardStyle(props)
  props.fill = props.fill or "surface_container"
  props.border, props.borderWidth = props.border or M.CARD_BORDER, props.borderWidth or M.CARD_BORDER_WIDTH
  props.radius = props.radius or M.RADIUS.lg
  return props
end

function M.card(props, children)
  props.padding = props.padding or 12
  props.gap = props.gap or 8
  return ui.column(cardStyle(props), children)
end

-- A card laid out as one row (list rows with buttons); the caller sets padding, gap and align.
function M.rowCard(props, children) return ui.row(cardStyle(props), children) end

function M.fileSize(bytes)
  if bytes >= 1024 * 1024 then return string.format("%.1f MB", bytes / (1024 * 1024)) end
  return string.format("%.1f KB", bytes / 1024)
end

-- A small ghost icon button; `tooltip` also names it for screen readers.
function M.iconButton(glyph, tooltip, onClick, enabled, key)
  return ui.button({ key = key, glyph = glyph, variant = "ghost", controlSize = "sm", tooltip = tooltip,
                     enabled = enabled ~= false, onClick = onClick })
end

-- A list filter: the text in view[key], with a clear button like searchBox's (row `<key>-box`, input
-- `<key>:<gen>`). props: placeholder, focus, flexGrow (of the row, e.g. next to a button).
function M.filterBox(ctx, key, props)
  local view = ctx.view
  return ui.row({ key = key .. "-box", gap = 4, align = "center", flexGrow = props.flexGrow }, {
    ui.input({ key = key .. ":" .. ctx.gen(key), value = view[key] or "", controlSize = "sm", flexGrow = 1,
               placeholder = props.placeholder, focus = props.focus,
               onChange = function(text) view[key] = text; ctx.render() end }),
    ui.button({ key = key .. "-clear", glyph = "eraser", variant = "ghost", controlSize = "sm", tooltip = "Clear filter",
                enabled = (view[key] or "") ~= "", onClick = function()
                  view[key] = nil
                  ctx.bump(key)
                  ctx.render()
                end }),
  })
end

-- The filter text of filterBox `key`, trimmed and lower-cased ("" when empty).
function M.filterText(ctx, key) return string.lower(noctalia.string.trim(ctx.view[key] or "")) end

-- Whether `text` contains the lower-cased filter text `query` (plain, case-insensitive).
function M.contains(text, query) return string.find(string.lower(text), query, 1, true) ~= nil end

-- A name box and a button that both hand the trimmed text to `onAccept` (row `key`, input `<key>:<gen>`; the
-- typed text is in view[key]; bump `key` to clear it).
function M.nameForm(ctx, key, placeholder, buttonText, onAccept)
  local view = ctx.view
  return ui.row({ key = key, gap = 6, align = "center" }, {
    ui.input({ key = key .. ":" .. ctx.gen(key), value = "", flexGrow = 1, controlSize = "sm",
               placeholder = placeholder, onChange = function(text) view[key] = text end,
               onSubmit = function(text) view[key] = text; onAccept(noctalia.string.trim(text)) end }),
    ui.button({ text = buttonText, glyph = "plus", controlSize = "sm", variant = "outline",
                onClick = function() onAccept(noctalia.string.trim(view[key] or "")) end }),
  })
end

-- A settings row: label on the left, its control on the right.
function M.optionRow(key, label, control, tooltip)
  return ui.row({ key = key, gap = 8, align = "center", tooltip = tooltip }, {
    ui.label({ text = label, fontSize = M.FONT.body, flexGrow = 1 }),
    control,
  })
end

-- A button that asks once: the first click arms it (destructive "Click again to …"), the second runs `action`.
-- props: key (also what view.confirm holds while armed), text, armedText, glyph, controlSize, enabled, and
-- `check`, which can refuse before arming. Navigation disarms it (the shell clears view.confirm).
function M.confirmButton(ctx, props, action)
  local view = ctx.view
  local armed = view.confirm == props.key
  return ui.button({ key = props.key, text = armed and props.armedText or props.text, glyph = props.glyph,
                     variant = armed and "destructive" or "outline", controlSize = props.controlSize,
                     enabled = props.enabled, tooltip = props.tooltip, onClick = function()
                       if props.check and not props.check() then return end
                       if view.confirm ~= props.key then view.confirm = props.key; ctx.render(); return end
                       view.confirm = nil
                       action()
                     end })
end

-- Header: back button, breadcrumb title, then right-side actions.
function M.header(ctx, title, subtitle, actions)
  local left = {}
  if ctx.canGoBack() then
    table.insert(left, ui.button({ key = "back", glyph = "arrow-left", variant = "ghost", tooltip = "Back (Alt+Left)",
                                   onClick = function() ctx.back() end }))
  end
  local titles = { titleLabel(title) }
  if subtitle and subtitle ~= "" then table.insert(titles, M.muted(subtitle, { maxLines = 2 })) end
  table.insert(left, ui.column({ gap = 0, flexGrow = 1 }, titles))
  for _, action in ipairs(actions or {}) do table.insert(left, action) end
  if not ctx.isApp then
    table.insert(left, ui.button({ key = "close", glyph = "x", variant = "ghost", tooltip = "Close (Esc)",
                                   onClick = function() panel.close() end }))
  end
  return ui.row({ key = "header", gap = 8, align = "center" }, left)
end

-- Notice strip for errors, warnings and info; `onDismiss` adds a close button.
function M.notice(text, kind, onDismiss, key)
  local color = kind == "error" and "error" or kind == "warning" and "tertiary" or "primary"
  local glyph = kind == "error" and "alert-circle" or kind == "warning" and "alert-triangle" or "info-circle"
  local children = {
    ui.glyph({ name = glyph, size = M.GLYPH.body, color = color }),
    ui.label({ text = text, fontSize = M.FONT.small, flexGrow = 1, maxLines = 6 }),
  }
  if onDismiss then
    table.insert(children, ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", tooltip = "Dismiss",
                                       onClick = onDismiss }))
  end
  return ui.row({ key = key or ("notice-" .. text), gap = 8, align = "center", padding = 10, radius = M.RADIUS.md,
                  fill = color .. "/0.12" }, children)
end

-- An error notice and a primary **Try again** button under it (keys `<key>-error`, `<key>-retry`): two rows.
function M.retryNotice(key, text, onRetry)
  return M.notice(text, "error", nil, key .. "-error"), ui.row({ key = key .. "-retry" }, {
    ui.button({ text = "Try again", glyph = "refresh", variant = "primary", onClick = onRetry }),
  })
end

function M.empty(text, glyph)
  return ui.column({ key = "empty", align = "center", gap = 8, paddingV = 32 }, {
    ui.glyph({ name = glyph or "mood-empty", size = M.GLYPH.empty, color = M.MUTED }),
    M.muted(text, { fontSize = M.FONT.body, textAlign = "center" }),
  })
end

-- The placeholder while something loads ("Loading…" unless `text` says what).
function M.loading(text) return M.empty(text or "Loading…", "loader") end

-- A whole page for a route whose entry was removed meanwhile (undo, reload, another window).
function M.gone(ctx, title, text)
  return { header = { M.header(ctx, title) }, content = { M.empty(text or "This entry no longer exists.", "trash") } }
end

-- A clickable list row: glyph, title, subtitle, trailing badges and a chevron.
function M.navRow(props)
  local text = { ui.label({ text = props.title, fontSize = M.FONT.item, fontWeight = props.bold and "bold" or nil,
                            maxLines = 1 }) }
  if props.subtitle and props.subtitle ~= "" then
    table.insert(text, M.muted(props.subtitle, { maxLines = props.subtitleLines or 1 }))
  end
  local children = { props.leading }
  if props.image then
    table.insert(children, ui.image({ path = props.image, width = 24, height = 24, fit = "contain" }))
  elseif props.glyph then
    table.insert(children, ui.glyph({ name = props.glyph, size = M.GLYPH.row, color = "primary" }))
  end
  table.insert(children, ui.column({ gap = 2, flexGrow = 1 }, text))
  for _, badge in ipairs(props.badges or {}) do table.insert(children, badge) end
  table.insert(children, ui.glyph({ name = props.trailing or "chevron-right", size = M.GLYPH.body, color = M.MUTED }))
  return ui.row({ key = props.key, gap = 12, align = "center", paddingH = 12, paddingV = 6, radius = M.RADIUS.md,
                  border = M.CARD_BORDER, borderWidth = M.CARD_BORDER_WIDTH, fill = props.fill or "surface_container",
                  tooltip = props.tooltip, onClick = props.onClick },
                children)
end

-- The global search box with a clear button. The button stays laid out (disabled while the box is empty) so
-- the box keeps its width; clearing replaces the input (inputs are uncontrolled) and keeps the focus there.
function M.searchBox(ctx, props)
  local view = ctx.view
  props.key = "search:" .. ctx.gen("search")
  props.value = view.query
  props.focus = true
  props.flexGrow = 1
  return ui.row({ key = "search-box", gap = 4, align = "center" }, {
    ui.input(props),
    ui.button({ key = "search-clear", glyph = "eraser", variant = "ghost", controlSize = props.controlSize,
                tooltip = "Clear search", enabled = (view.query or "") ~= "", onClick = function()
                  ctx.clearSearch()
                  ctx.render()
                end }),
  })
end

-- Section heading in its own case: string.upper is byte-wise and would leave "Bézier" as "BéZIER".
function M.section(text, key)
  return ui.label({ key = key or ("section-" .. text), text = text, fontSize = M.FONT.small,
                    fontWeight = "bold", color = M.MUTED })
end

-- Stronger heading for a group of cards (plugin home): primary text over a rule, spaced from the group above.
function M.groupHeading(text, key, first)
  key = key or ("section-" .. text)
  local nodes = {}
  if not first then table.insert(nodes, ui.box({ key = key .. "-gap", height = 6 })) end
  table.insert(nodes, ui.label({ key = key, text = text, fontSize = M.FONT.large, fontWeight = "bold",
                                 color = "primary" }))
  table.insert(nodes, ui.separator({ key = key .. "-rule", thickness = 1, opacity = 0.5 }))
  return nodes
end

-- plural(3, "entry", "entries"); the plural form defaults to word .. "s".
function M.plural(count, word, many)
  return tostring(count) .. " " .. (count == 1 and word or (many or (word .. "s")))
end

return M
