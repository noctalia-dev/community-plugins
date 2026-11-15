--!nonstrict
-- Advanced tab, version 1 (spec §6.6): the deep settings live in the Mullvad app,
-- so this says so and offers to open it. Pure, like view_connect.
--
--   view_advanced.build(snapshot, ui_state, send, hasApp) -> UiNode
--     hasApp  true when `mullvad-vpn` is installed; the button is hidden otherwise

local view_advanced = {}

local function tr(key, subst)
  if noctalia and noctalia.tr then
    return noctalia.tr(key, subst)
  end
  return key
end

function view_advanced.build(snapshot, ui_state, send, hasApp)
  local children = {
    ui.label({ text = tr("advanced.in_app"), fontSize = 12, maxLines = 4 }),
  }
  if hasApp == true then
    children[#children + 1] = ui.row({ gap = 8 }, {
      ui.button({
        key = "advanced.open_app",
        text = tr("advanced.open_app"),
        glyph = "external-link",
        variant = "outline",
        onClick = function()
          send({ action = "open_app" })
        end,
      }),
    })
  end
  return ui.column({ key = "advanced.tab", gap = 10 }, children)
end

return view_advanced
