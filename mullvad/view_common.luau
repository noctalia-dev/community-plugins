--!nonstrict
-- Small ui pieces more than one view uses. Pure, like the view_* builders.
--
--   view_common.confirmRow(tr, ui_state, actionId, onYes, onNo, busy) -> UiNode | nil
--     The "Are you sure?" row with Yes / No buttons (node keys confirm.yes and
--     confirm.no) when ui_state.confirm == actionId; nil otherwise, so the caller
--     shows its normal button instead:
--       local row = view_common.confirmRow(tr, ui_state, "logout", yes, no) or logoutButton
--     The caller's button asks by setting ui_state.confirm = actionId (setUi), and
--     onYes / onNo clear it again (setUi({ confirm = false })). Only one question is
--     open at a time, and the panel drops it whenever it opens.
--     tr(key) is the caller's translation function. busy (optional): true while the
--     service runs an action; Yes is then disabled (Cancel never is).

local view_common = {}

function view_common.confirmRow(tr, ui_state, actionId, onYes, onNo, busy)
  if type(ui_state) ~= "table" or ui_state.confirm == nil or ui_state.confirm ~= actionId then
    return nil
  end
  return ui.row({ key = "confirm." .. tostring(actionId), gap = 6, align = "center" }, {
    ui.label({ text = tr("confirm.prompt"), fontSize = 12, color = "error", flexGrow = 1 }),
    ui.button({
      key = "confirm.yes",
      text = tr("confirm.yes"),
      variant = "destructive",
      controlSize = "sm",
      enabled = busy ~= true,
      onClick = onYes,
    }),
    ui.button({
      key = "confirm.no",
      text = tr("confirm.no"),
      variant = "ghost",
      controlSize = "sm",
      onClick = onNo,
    }),
  })
end

return view_common
