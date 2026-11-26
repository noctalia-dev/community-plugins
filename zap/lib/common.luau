--!nonstrict
-- Helpers shared by the service, the bar widget and the panel.

local M = {}

local PLUGIN_ID = "claudio-asj/zap"
local PANELS = {
  compact = "panel_compact",
  normal = "panel",
  large = "panel_large",
  full = "panel_full",
}

-- Id of the panel matching the "panel_size" setting.
function M.panelId(): string
  local size = noctalia.getConfig("panel_size")
  return `{PLUGIN_ID}:{PANELS[size] or "panel"}`
end

-- Shared state keys written by service.luau.
M.KEY_STATUS = "status" -- { state = string, detail = string }
M.KEY_QR = "qr" -- absolute path of the current QR image, or nil
M.KEY_CHATS = "chats" -- list of chats, most recent first
M.KEY_UNREAD = "unread" -- total unread messages
M.KEY_DAEMON = "daemon" -- path of the noctalia-zapd binary, or nil when missing
M.KEY_MESSAGES = "messages" -- { seq = number, items = { message } }: last live messages
M.KEY_PLAYBACK = "playback" -- { chat, id, playing, started_ms, seconds }: the audio player state
M.KEY_PICKED = "picked" -- { path, cancelled, at }: answer of the file chooser
M.KEY_RECORDING = "recording" -- { recording, started_ms, path, at }: the voice recorder
M.KEY_SEND_FAILED = "sendFailed" -- { chat, error, at }: a send failed after ctl gave up
M.KEY_BACKFILL = "backfill" -- { chat, at }: the phone resent a chat's history
M.KEY_TYPING = "typing" -- { chat, from, name, state, at }: someone is typing
-- Written by the panel:
M.KEY_ACTIVE_CHAT = "activeChat" -- jid shown in the open panel, or nil
M.KEY_PANEL_OPEN = "panelOpen" -- true while a panel is open
-- Written by the service when a notification is clicked:
M.KEY_OPEN_CHAT = "openChat" -- { jid = string, at = number }

function M.isGroup(jid: string?): boolean
  return jid ~= nil and string.sub(jid, -5) == "@g.us"
end

-- Status states that mean "not usable right now".
function M.isProblem(state: string?): boolean
  return state == nil or state == "error" or state == "logged_out" or state == "missing"
end

-- Preview of the last message of a chat: text, or a label for media.
function M.preview(text: string?, kind: string?): string
  text = text or ""
  if kind == nil or kind == "" or kind == "text" then
    return text
  end
  local label = noctalia.tr("kind." .. kind)
  if text ~= "" then
    return `{label}: {text}`
  end
  return label
end

local KIND_GLYPHS = {
  image = "photo",
  video = "video",
  audio = "microphone",
  document = "file",
  sticker = "sticker",
  location = "map-pin",
  contact = "user",
  poll = "chart-bar",
}

function M.kindGlyph(kind: string?): string
  return KIND_GLYPHS[kind or ""] or "message"
end

-- Keeps only the known media fields, with the right types.
function M.copyMedia(media): any
  if type(media) ~= "table" then
    return nil
  end
  return {
    thumb = if type(media.thumb) == "string" then media.thumb else nil,
    file = if type(media.file) == "string" then media.file else nil,
    w = tonumber(media.w) or 0,
    h = tonumber(media.h) or 0,
    seconds = tonumber(media.seconds) or 0,
    size = tonumber(media.size) or 0,
    mime = if type(media.mime) == "string" then media.mime else "",
    ptt = media.ptt == true,
    sound = media.sound == true,
  }
end

-- Turns a message from the daemon (event or history) into the panel's shape,
-- keeping only known fields with the right types.
function M.normalizeMessage(m): any
  if type(m) ~= "table" then
    return nil
  end
  local quote = nil
  if type(m.quote) == "table" and type(m.quote.id) == "string" then
    quote = {
      id = m.quote.id,
      from = if type(m.quote.from) == "string" then m.quote.from else "",
      name = if type(m.quote.name) == "string" then m.quote.name else "",
      text = if type(m.quote.text) == "string" then m.quote.text else "",
      kind = if type(m.quote.kind) == "string" then m.quote.kind else "text",
      me = m.quote.me == true,
    }
  end
  local reactions = {}
  if type(m.reactions) == "table" then
    for _, r in m.reactions do
      if type(r) == "table" and type(r.emoji) == "string" and r.emoji ~= "" then
        table.insert(reactions, { emoji = r.emoji, count = tonumber(r.count) or 1, me = r.me == true })
      end
    end
  end
  return {
    id = if type(m.id) == "string" then m.id else "",
    chat = if type(m.chat) == "string" then m.chat else "",
    from = if type(m.from) == "string" then m.from else "",
    name = if type(m.name) == "string" then m.name else "",
    text = if type(m.text) == "string" then m.text else "",
    kind = if type(m.kind) == "string" then m.kind else "text",
    ts = tonumber(m.ts) or 0,
    me = m.me == true,
    truncated = m.truncated == true,
    media = M.copyMedia(m.media),
    quote = quote,
    reactions = reactions,
    edited = m.edited == true,
    deleted = m.deleted == true,
    ack = if type(m.ack) == "string" then m.ack else "",
  }
end

-- "1:05" from seconds.
function M.duration(seconds: number): string
  seconds = math.max(0, math.floor(seconds))
  return string.format("%d:%02d", seconds // 60, seconds % 60)
end

-- File size for documents, translated unit.
function M.fileSize(bytes: number): string
  if bytes >= 1024 * 1024 then
    return noctalia.tr("size.mb", { n = string.format("%.1f", bytes / (1024 * 1024)) })
  end
  return noctalia.tr("size.kb", { n = tostring(math.max(1, math.floor(bytes / 1024))) })
end

-- Theme roles used to tell group senders apart. Same sender, same color.
local SENDER_COLORS = { "primary", "secondary", "tertiary" }

function M.senderColor(jid: string?): string
  local h = 0
  for i = 1, #(jid or "") do
    h = (h * 31 + string.byte(jid, i)) % 1000003
  end
  return SENDER_COLORS[(h % #SENDER_COLORS) + 1]
end

-- "+5511..." from a phone JID; "" for anything else.
function M.phoneOf(jid: string?): string
  local user = string.match(jid or "", "^(%d+)@s%.whatsapp%.net$")
  return if user then "+" .. user else ""
end

-- Badge text, capped so it stays small.
function M.badgeText(count: number): string
  if count > 99 then
    return noctalia.tr("badge.many", { count = 99 })
  end
  return tostring(count)
end

-- First visible character of a name, for the avatar placeholder.
function M.initial(name: string?): string
  if name == nil or name == "" then
    return "?"
  end
  local ok, cp = pcall(utf8.codepoint, name, 1)
  if not ok or cp == nil then
    return "?"
  end
  if cp == 43 then -- "+": phone numbers get a generic mark
    return "#"
  end
  return string.upper(utf8.char(cp))
end

-- Short time for the chat list: hour today, date otherwise.
function M.shortTime(ts: number?): string
  if ts == nil or ts <= 0 then
    return ""
  end
  if noctalia.formatTime("%Y-%m-%d", ts) == noctalia.formatTime("%Y-%m-%d") then
    return noctalia.formatTime("%H:%M", ts)
  end
  return noctalia.formatTime("%d/%m", ts)
end

-- Case-insensitive plain-text match for the chat search.
function M.matches(haystack: string?, needle: string): boolean
  if needle == "" then
    return true
  end
  return string.find(string.lower(haystack or ""), string.lower(needle), 1, true) ~= nil
end

return M
