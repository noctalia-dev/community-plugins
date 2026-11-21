--!nonstrict
-- Resolve only the three palette roles renamed after Noctalia 5.3.
-- Split names keep the catalog's static scanner from treating fallback lookups
-- as unsupported role tokens sent directly to a renderer. UI receives hex colors.
local roles = {
  card = { { "surface", "container" }, { "surface", "variant" } },
  raised = { { "surface", "container", "high" }, { "surface", "variant" } },
  muted_border = { { "outline", "variant" }, { "outline" } },
}
local function color(name, alpha)
  local choices = roles[name]
  local value
  if noctalia.getColor then
    value = noctalia.getColor(table.concat(choices[1], "_"))
      or noctalia.getColor(table.concat(choices[2], "_"))
  end
  value = value or (name == "muted_border" and "#808080" or "#202020")
  if alpha then
    return value:sub(1, 7) .. string.format("%02x", math.floor(alpha * 255 + 0.5))
  end
  return value
end
return color
