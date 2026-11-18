--!nonstrict
local function fmt(n)
  if n >= 1000 then
    local s = string.format("%.2f", n)
    local int, frac = s:match("^(%d+)(%..*)$")
    return int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "") .. frac
  end
  if n >= 1 then return string.format("%.2f", n) end
  return string.format("%.4f", n)
end

local function help(text)
  launcher.setResults(text, {
    { id = "h1", title = "/fx 100 USD EUR", subtitle = "Convert 100 USD to EUR" },
    { id = "h2", title = "/fx 50 BRL", subtitle = "Convert 50 BRL to the target currency" },
    { id = "h3", title = "/fx EUR GBP", subtitle = "Show the rate for 1 EUR in GBP" },
  })
end

function onQuery(text)
  local rates = noctalia.state.get("rates")
  if rates == nil then
    launcher.setResults(text, { { id = "wait", title = "Loading rates…", glyph = "loader" } })
    return
  end

  local source = string.upper(noctalia.getConfig("source_currency") or "USD")
  local target = string.upper(noctalia.getConfig("target_currency") or "EUR")

  local q = string.upper(noctalia.string.trim(text)):gsub("(%d)(%a)", "%1 %2")
  local parts = {}
  for p in q:gmatch("%S+") do
    if p ~= "TO" then table.insert(parts, p) end
  end
  if #parts == 0 then
    help(text)
    return
  end

  local amount = 1
  local first = tonumber((parts[1]:gsub(",", ".")))
  if first ~= nil and first > 0 then
    amount = first
    table.remove(parts, 1)
  end

  local from, to
  if #parts == 0 then
    from, to = source, target
  elseif #parts == 1 then
    from = parts[1]
    to = (from == target) and source or target
  else
    from, to = parts[1], parts[2]
  end

  if #from < 3 or #to < 3 then
    help(text)
    return
  end
  for _, code in ipairs({ from, to }) do
    if rates[code] == nil then
      launcher.setResults(text, { { id = "bad", title = "Unknown currency: " .. code, glyph = "alert-circle" } })
      return
    end
  end

  local rate = rates[to] / rates[from]
  local result = fmt(amount * rate)
  launcher.setResults(text, {
    {
      id = result,
      title = fmt(amount) .. " " .. from .. " = " .. result .. " " .. to,
      subtitle = "1 " .. from .. " = " .. fmt(rate) .. " " .. to .. " — Enter copies the result",
      glyph = "currency-dollar",
    },
  })
end

function onActivate(id)
  noctalia.copyToClipboard(id, "text/plain")
end
