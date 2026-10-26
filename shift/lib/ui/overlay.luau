--!nonstrict
-- Draws `content` centered over `base` (spec §7.4.3: the counter inside the hero ring).
--
-- The declarative UI has no stacking container (spec C8). A column with a negative gap
-- makes its second child start inside the first, and a fixed height keeps the layout
-- below unaffected. This relies on undocumented behavior of Noctalia's layout: it is
-- confined to this function, so if an update breaks it, only this file changes (for
-- instance to place the content next to the base).

local Overlay = {}

-- `baseSize` is the height of `base`; `contentHeight` an estimate of the content's
-- height, from its font sizes (an error of a few pixels only shifts the centering).
function Overlay.center(base: UiNode, baseSize: number, content: UiNode, contentHeight: number): UiNode
  return ui.column({ height = baseSize, gap = -(baseSize + contentHeight) / 2, align = "center" }, { base, content })
end

return Overlay
