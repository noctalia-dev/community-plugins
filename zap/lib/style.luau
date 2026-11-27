--!nonstrict
-- Fixed sizes shared by every entry (see docs/design.md). Colors are theme roles,
-- never hex values.

return {
  gap = { xs = 4, sm = 6, md = 8, lg = 12 },
  padding = { sm = 8, md = 10, lg = 16 },
  radius = { control = 6, card = 8, inner = 12 },
  font = { caption = 11, body = 12, name = 13, title = 16 },

  listWidth = 300,
  avatar = 36,
  qrSize = 280,
  bubbleMax = 420,
  thumbMax = 240,
  sticker = 128,
  barGlyph = 14,
}
