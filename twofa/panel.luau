--!nonstrict
-- Codes panel.
--   List: search, one shared countdown, every account as a compact row (letter badge, name,
--   live code); click a row to copy. With a search, the row Enter would copy is outlined.
--   Edit mode (pencil) swaps the codes for rename / delete buttons.
--   Add: scan a QR code on screen, paste an otpauth link or a Google Authenticator export,
--   or type the key; the form validates as you type.
--   Rename: service + account, Enter saves.

local store = require("./store.luau")
local totp = require("./totp.luau")
local copy = require("./copy.luau")
local match = require("./match.luau")

local tr = noctalia.tr

local WIDTH = 372 -- content width inside the panel padding
local DEFAULT_PERIOD = 30
local URGENT_SECONDS = 5
local BADGE_TONES = { "primary", "secondary", "tertiary" }

local view = "list" -- "list" | "add" | "rename"
local filter = ""
local editing = false
local hovered = nil -- account id under the pointer
local confirmDelete = nil -- account id waiting for the second click
local renameTarget = nil
local form = { issuer = "", account = "", secret = "" }
local message = nil -- { text, color }

local render

local function say(text, color)
  message = { text = text, color = color or "on_surface_variant" }
  render()
end

local function name(a)
  return a.issuer ~= "" and a.issuer or a.account
end

local function subtitle(a)
  return (a.issuer ~= "" and a.account ~= "") and a.account or nil
end

local function caption(text, color, lines)
  return ui.label({ text = text, fontSize = 12, color = color or "on_surface_variant", maxWidth = WIDTH, maxLines = lines or 3 })
end

local function iconButton(glyph, tooltip, onClick, selected)
  return ui.button({
    glyph = glyph,
    tooltip = tooltip,
    variant = selected and "primary" or "ghost",
    selected = selected,
    controlSize = "sm",
    onClick = onClick,
  })
end

-- Header: optional back button on the left, title, extra buttons, close on the right.
local function header(title, opts)
  local items = {}
  if opts.back then
    table.insert(items, iconButton("arrow-left", tr("panel.back"), function()
      view, message = "list", nil
      render()
    end))
  else
    table.insert(items, ui.glyph({ name = opts.glyph, color = "primary" }))
  end
  table.insert(items, ui.label({ text = title, fontWeight = "bold", flexGrow = 1, maxWidth = 260, maxLines = 1 }))
  for _, b in opts.buttons or {} do
    table.insert(items, b)
  end
  table.insert(items, iconButton("x", tr("panel.close"), function()
    panel.close()
  end))
  return ui.row({ gap = 6, align = "center" }, items)
end

-- Round letter badge, tinted by a stable hash of the name so a service keeps its colour.
local function badge(a)
  local n = name(a)
  local h = 0
  for i = 1, #n do
    h = (h * 31 + string.byte(n, i)) % 997
  end
  local tone = BADGE_TONES[h % #BADGE_TONES + 1]
  local letter = n:match("^[%z\1-\127\194-\244][\128-\191]*") or "?"
  return ui.column({ width = 32, height = 32, radius = 16, fill = tone .. "/0.18", align = "center", justify = "center" }, {
    ui.label({ text = letter:upper(), fontWeight = "bold", fontSize = 14, color = tone }),
  })
end

local function importText(text, fromClipboard)
  local list, skipped, err = totp.parseAny(text or "")
  if #list == 0 then
    say(tr("import." .. (err or "nothing_found")), "error")
    return
  end
  -- The clipboard holds the secret itself: drop it as soon as it has been read.
  if fromClipboard then
    copy.clear()
  end
  say(tr("import.saving"))
  store.add(list, function(added, duplicates, failed, storeErr)
    if failed > 0 then
      say(tr("import.store_failed", { error = storeErr or "?" }), "error")
      return
    end
    local text = tr("import.result", { added = added, duplicates = duplicates, skipped = skipped })
    if fromClipboard then
      text ..= "\n" .. tr("import.clipboard_cleared")
    end
    if added > 0 then
      view, filter, form = "list", "", { issuer = "", account = "", secret = "" }
    end
    say(text, added > 0 and "primary" or nil)
  end)
end

-- ── list view ────────────────────────────────────────────────────────────────

local function accountRow(a, now, isTarget)
  local code, left = totp.code(a, now)
  local period = a.period or DEFAULT_PERIOD
  local urgent = left <= URGENT_SECONDS
  local text = { ui.label({ text = name(a), fontWeight = "semibold", maxWidth = 180, maxLines = 1 }) }
  local sub = subtitle(a)
  if sub then
    table.insert(text, ui.label({ text = sub, fontSize = 11, color = "on_surface_variant", maxWidth = 180, maxLines = 1 }))
  end

  local trailing
  if editing then
    local deleting = confirmDelete == a.id
    trailing = ui.row({ gap = 2, align = "center" }, {
      iconButton("pencil", tr("panel.rename"), function()
        renameTarget = a
        form = { issuer = a.issuer, account = a.account, secret = "" }
        view, message, confirmDelete = "rename", nil, nil
        render()
      end),
      ui.button({
        glyph = "trash",
        text = deleting and tr("panel.confirm_delete") or nil,
        tooltip = tr("panel.delete"),
        variant = deleting and "destructive" or "ghost",
        controlSize = "sm",
        onClick = function()
          if not deleting then
            confirmDelete = a.id
            render()
            return
          end
          confirmDelete = nil
          store.remove(a.id, function(ok)
            say(tr(ok and "panel.deleted" or "panel.delete_failed", { name = name(a) }), if ok then nil else "error")
          end)
        end,
      }),
    })
  else
    local codeCol = {
      ui.label({
        text = code and totp.group(code) or "—",
        fontSize = 20,
        fontWeight = "semibold",
        fontFamily = "monospace",
        color = urgent and "error" or "primary",
      }),
    }
    -- Accounts on a non-standard period carry their own countdown.
    if period ~= DEFAULT_PERIOD then
      table.insert(codeCol, ui.label({ text = tr("common.seconds", { n = left }), fontSize = 11, color = "on_surface_variant" }))
    end
    trailing = ui.column({ align = "end", gap = 0 }, codeCol)
  end

  local highlight = (hovered == a.id and not editing) or isTarget
  return ui.row({
    key = "acc-" .. a.id,
    gap = 10,
    paddingH = 10,
    paddingV = 8,
    radius = 10,
    align = "center",
    fill = highlight and "surface_container/0.8" or "surface_container/0.35",
    border = isTarget and "primary/0.7" or nil,
    borderWidth = isTarget and 1 or nil,
    onHover = function(state)
      local id = (state == "enter" or state == "true" or state == "1") and a.id or nil
      if id ~= hovered and (id or hovered == a.id) then
        hovered = id
        render()
      end
    end,
    onClick = (not editing) and function()
      copy.code(a)
      panel.close()
    end or nil,
  }, {
    badge(a),
    ui.column({ gap = 1, flexGrow = 1 }, text),
    trailing,
  })
end

local function emptyState(s)
  return ui.column({ gap = 10, padding = 24, align = "center" }, {
    ui.glyph({ name = "shield-lock", size = 40, color = "on_surface_variant" }),
    ui.label({ text = tr("panel.empty"), color = "on_surface_variant", maxWidth = 300, maxLines = 2, textAlign = "center" }),
    ui.button({ glyph = "plus", text = tr("panel.add"), variant = "primary", controlSize = "sm", onClick = function()
      view, message, editing = "add", nil, false
      render()
    end }),
  })
end

local function listView()
  local s = store.current()
  local now = os.time()
  local left = DEFAULT_PERIOD - now % DEFAULT_PERIOD
  local urgent = left <= URGENT_SECONDS
  local shown = match.filter(s.accounts, filter, function(a)
    return name(a) .. " " .. a.account
  end)

  local children = {
    header(tr("panel.title"), {
      glyph = "shield-lock",
      buttons = {
        iconButton("plus", tr("panel.add"), function()
          view, message, editing, confirmDelete = "add", nil, false, nil
          render()
        end),
        iconButton("pencil", tr(editing and "panel.edit_done" or "panel.edit"), function()
          editing, confirmDelete = not editing, nil
          render()
        end, editing),
      },
    }),
    ui.row({ gap = 10, align = "center" }, {
      ui.input({
        key = "search",
        value = filter,
        placeholder = tr("panel.search"),
        controlSize = "sm",
        flexGrow = 1,
        focus = true,
        submitOnEnter = true,
        onChange = function(v)
          filter = v
          render()
        end,
        onSubmit = function()
          if shown[1] and not editing then
            copy.code(shown[1])
            panel.close()
          end
        end,
      }),
      ui.label({
        text = tr("common.seconds", { n = left }),
        fontSize = 13,
        color = urgent and "error" or "on_surface_variant",
        width = 40,
        textAlign = "end",
      }),
    }),
    -- One countdown for every 30 s account instead of a bar per row.
    ui.row({ align = "center" }, {
      ui.progress({
        progress = left / DEFAULT_PERIOD,
        height = 3,
        radius = 2,
        flexGrow = 1,
        fill = urgent and "error" or "primary",
        track = "surface_container/0.6",
      }),
    }),
  }
  if message then
    table.insert(children, caption(message.text, message.color))
  end

  if s.status == "loading" and #s.accounts == 0 then
    table.insert(children, caption(tr("panel.loading")))
    return children
  elseif s.status == "error" then
    table.insert(children, caption(tr("panel.error", { error = s.error or "?" }), "error"))
    table.insert(children, ui.button({ glyph = "refresh", text = tr("panel.retry"), variant = "outline", controlSize = "sm", onClick = function()
      store.reload()
    end }))
  end

  if #s.accounts == 0 and s.status == "ok" then
    table.insert(children, emptyState(s))
    return children
  end

  local rows = {}
  for i, a in shown do
    table.insert(rows, accountRow(a, now, filter ~= "" and i == 1 and not editing))
  end
  if #rows == 0 then
    table.insert(rows, ui.column({ padding = 16, align = "center" }, {
      caption(tr("panel.no_match", { query = filter })),
    }))
  end
  table.insert(children, ui.scroll({ gap = 6, align = "stretch", flexGrow = 1 }, rows))

  local hint
  if editing then
    hint = tr("panel.hint_edit")
  elseif filter ~= "" and shown[1] then
    hint = tr("panel.hint_enter", { name = name(shown[1]) })
  else
    hint = tr("panel.hint_count", { count = #s.accounts })
  end
  table.insert(children, caption(hint, nil, 1))
  return children
end

-- ── add / rename views ───────────────────────────────────────────────────────

local function field(key, label, value, placeholder, opts)
  opts = opts or {}
  local rows = {
    ui.label({ text = label, fontSize = 13 }),
    ui.input({
      key = key,
      value = value,
      placeholder = placeholder,
      password = opts.password,
      controlSize = "sm",
      focus = opts.focus,
      submitOnEnter = true,
      onChange = opts.onChange,
      onSubmit = opts.onSubmit,
    }),
  }
  if opts.error then
    table.insert(rows, caption(opts.error, "error", 1))
  end
  return ui.column({ gap = 4, align = "stretch" }, rows)
end

local function section(glyph, title, children)
  local rows = { ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = glyph, size = 16, color = "primary" }),
    ui.label({ text = title, fontWeight = "semibold", flexGrow = 1 }),
  }) }
  for _, c in children do
    table.insert(rows, c)
  end
  return ui.column({ gap = 10, padding = 12, fill = "surface_container/0.35", radius = 12, align = "stretch" }, rows)
end

local function normalizedSecret()
  return (form.secret:upper():gsub("[%s%-=]", ""))
end

local function saveManual()
  local secret = normalizedSecret()
  local issuer, account = noctalia.string.trim(form.issuer), noctalia.string.trim(form.account)
  if (issuer == "" and account == "") or not totp.base32Decode(secret) then
    return
  end
  local enc = noctalia.string.urlEncode
  importText(("otpauth://totp/%s?secret=%s&issuer=%s"):format(enc(account), secret, enc(issuer)))
end

local function addView()
  local secret = normalizedSecret()
  local secretError = (secret ~= "" and not totp.base32Decode(secret)) and tr("import.bad_secret") or nil
  local hasName = noctalia.string.trim(form.issuer) ~= "" or noctalia.string.trim(form.account) ~= ""
  local canSave = hasName and secret ~= "" and not secretError

  local function onField(key)
    return function(v)
      local before = canSave
      form[key] = v
      -- Re-render only when validation output changes, so typing is not interrupted.
      local s = normalizedSecret()
      local err = s ~= "" and not totp.base32Decode(s)
      local ok = (noctalia.string.trim(form.issuer) ~= "" or noctalia.string.trim(form.account) ~= "") and s ~= "" and not err
      if ok ~= before or (key == "secret" and (err and true or false) ~= (secretError ~= nil)) then
        render()
      end
    end
  end

  local children = {
    header(tr("add.title"), { back = true }),
    section("qrcode", tr("add.import_title"), {
      ui.row({ gap = 8 }, {
        ui.button({ glyph = "scan", text = tr("add.scan"), variant = "primary", controlSize = "sm", flexGrow = 1, onClick = function()
          noctalia.state.set("scan", noctalia.nowMs())
          panel.close()
        end }),
        ui.button({ glyph = "clipboard", text = tr("add.paste"), variant = "outline", controlSize = "sm", flexGrow = 1, onClick = function()
          importText(noctalia.clipboardText(), true)
        end }),
      }),
      caption(tr("add.import_hint")),
    }),
    section("keyboard", tr("add.manual_title"), {
      field("issuer", tr("add.issuer"), form.issuer, tr("add.issuer_placeholder"), { onChange = onField("issuer"), onSubmit = saveManual }),
      field("account", tr("add.account"), form.account, tr("add.account_placeholder"), { onChange = onField("account"), onSubmit = saveManual }),
      field("secret", tr("add.secret"), form.secret, tr("add.secret_placeholder"), {
        password = true,
        error = secretError,
        onChange = onField("secret"),
        onSubmit = saveManual,
      }),
      ui.button({ glyph = "check", text = tr("add.save"), variant = "primary", controlSize = "sm", enabled = canSave, onClick = saveManual }),
    }),
  }
  if message then
    table.insert(children, caption(message.text, message.color))
  end
  return children
end

local function renameView()
  local a = renameTarget
  local function save()
    local issuer, account = noctalia.string.trim(form.issuer), noctalia.string.trim(form.account)
    if issuer == "" and account == "" then
      say(tr("add.need_name"), "error")
      return
    end
    store.rename(a, issuer, account, function(ok)
      if ok then
        view, message = "list", nil
        render()
      else
        say(tr("rename.failed"), "error")
      end
    end)
  end
  local children = {
    header(tr("rename.title"), { back = true }),
    ui.row({ gap = 10, align = "center", paddingH = 2 }, {
      badge(a),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = name(a), fontWeight = "semibold", maxWidth = 300, maxLines = 1 }),
        subtitle(a) and ui.label({ text = subtitle(a), fontSize = 11, color = "on_surface_variant", maxWidth = 300, maxLines = 1 }) or nil,
      }),
    }),
    section("tag", tr("rename.section"), {
      field("issuer", tr("add.issuer"), form.issuer, tr("add.issuer_placeholder"), {
        focus = true,
        onChange = function(v)
          form.issuer = v
        end,
        onSubmit = save,
      }),
      field("account", tr("add.account"), form.account, tr("add.account_placeholder"), {
        onChange = function(v)
          form.account = v
        end,
        onSubmit = save,
      }),
      ui.row({ gap = 8 }, {
        ui.button({ key = "cancel", text = tr("rename.cancel"), variant = "outline", controlSize = "sm", flexGrow = 1, onClick = function()
          view, message = "list", nil
          render()
        end }),
        ui.button({ glyph = "check", text = tr("rename.save"), variant = "primary", controlSize = "sm", flexGrow = 1, onClick = save }),
      }),
    }),
  }
  if message then
    table.insert(children, caption(message.text, message.color))
  end
  return children
end

render = function()
  local children
  if view == "add" then
    children = addView()
  elseif view == "rename" and renameTarget then
    children = renameView()
  else
    children = listView()
  end
  -- Keyed per view so switching views builds fresh nodes instead of reusing the previous
  -- view's (a reused button would keep a stale glyph).
  panel.render(ui.column({ key = "view-" .. view, gap = 10, padding = 14, align = "stretch", flexGrow = 1 }, children))
end

noctalia.state.watch(store.STATE_KEY, function()
  render()
end)

-- Second ticks keep codes and the countdown live; only the list shows them.
function update()
  if view == "list" then
    render()
  end
end

function onOpen()
  view, filter, editing, confirmDelete, message, hovered = "list", "", false, nil, nil, nil
  form = { issuer = "", account = "", secret = "" }
  panel.setWantsSecondTicks(true)
  render()
end
