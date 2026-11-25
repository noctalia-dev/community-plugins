--[[
  text.luau - pure text helpers: HTML to text, code-block extraction,
  truncation, entity/percent decoding, and search-result parsing.

  Pure module (no `noctalia.*`), used by the tool layer and the panel, and
  unit-testable on its own.
]]

local M = {}

local function trim(s: string): string
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

M.trim = trim

local ENTITIES = {
  amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
  ["#39"] = "'", ["#x27"] = "'", ["#x2f"] = "/", ["#47"] = "/",
  hellip = "...", mdash = "-", ndash = "-", middot = "*",
  ldquo = '"', rdquo = '"', lsquo = "'", rsquo = "'",
  laquo = "<", raquo = ">", copy = "(c)", reg = "(R)", trade = "(TM)",
  times = "x", deg = "deg", euro = "EUR", pound = "GBP", yen = "JPY",
  aacute = "a", eacute = "e", iacute = "i", oacute = "o", uacute = "u",
  ntilde = "n", uuml = "u", ouml = "o", auml = "a", szlig = "ss",
}

--[[
  Decode named and numeric HTML entities. Unknown entities are left as written
  so a page that mentions `&foo;` literally still reads correctly.
]]
function M.decode_entities(s: string?): string
  if type(s) ~= "string" then
    return ""
  end
  return (s:gsub("&([#%w]+);", function(name)
    local known = ENTITIES[name] or ENTITIES[name:lower()]
    if known ~= nil then
      return known
    end
    local decimal = name:match("^#(%d+)$")
    if decimal ~= nil then
      local code = tonumber(decimal)
      if code ~= nil and code > 0 and code < 1114112 then
        local ok, char = pcall(utf8.char, code)
        if ok then
          return char
        end
      end
      return ""
    end
    local hexadecimal = name:match("^#[xX](%x+)$")
    if hexadecimal ~= nil then
      local code = tonumber(hexadecimal, 16)
      if code ~= nil and code > 0 and code < 1114112 then
        local ok, char = pcall(utf8.char, code)
        if ok then
          return char
        end
      end
      return ""
    end
    return "&" .. name .. ";"
  end))
end

--[[
  Remove a whole element including its content, scanning with plain finds so a
  `<script>` block spanning many lines disappears in one go.
]]
function M.drop_element(s: string, tag: string): string
  local out = {}
  local position = 1
  while true do
    local start_index, start_end = s:find("<" .. tag, position, true)
    if start_index == nil then
      table.insert(out, s:sub(position))
      break
    end
    local close_start, close_end = s:find("</" .. tag .. ">", start_end, true)
    table.insert(out, s:sub(position, start_index - 1))
    if close_start == nil then
      break
    end
    position = close_end + 1
  end
  return table.concat(out)
end

-- A tag-aware scanner beats a pattern here: attribute values may contain `>`,
-- and a stray `<` in prose (a `<` in maths, say) must not swallow the rest.
function M.strip_tags(s: string): string
  local out = {}
  local inside_tag = false
  for index = 1, #s do
    local char = s:sub(index, index)
    if inside_tag then
      if char == ">" then
        inside_tag = false
        table.insert(out, " ")
      end
    elseif char == "<" then
      inside_tag = true
    else
      table.insert(out, char)
    end
  end
  return table.concat(out)
end

function M.collapse_whitespace(s: string): string
  local collapsed = s:gsub("[ \t\r\f\v]+", " ")
  collapsed = collapsed:gsub(" *\n *", "\n")
  collapsed = collapsed:gsub("\n\n\n+", "\n\n")
  local lines = {}
  for line in (collapsed .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, trim(line))
  end
  return trim(table.concat(lines, "\n"))
end

--[[
  HTML to readable text. Scripts, styles, inline SVG and comments carry no
  prose and cost the model context, so they go first.
]]
function M.html_to_text(html: string?): string
  if type(html) ~= "string" or html == "" then
    return ""
  end
  local s = html
  s = M.drop_element(s, "script")
  s = M.drop_element(s, "style")
  s = M.drop_element(s, "noscript")
  s = M.drop_element(s, "svg")
  s = M.drop_element(s, "head")
  s = s:gsub("<!%-%-.-%-%->", " ")
  s = s:gsub("<br%s*/?>", "\n")
  s = s:gsub("<br>", "\n")
  s = s:gsub("</p>", "\n\n")
  s = s:gsub("</div>", "\n")
  s = s:gsub("</li>", "\n")
  s = s:gsub("</tr>", "\n")
  s = M.strip_tags(s)
  s = M.decode_entities(s)
  return M.collapse_whitespace(s)
end

function M.looks_like_html(body: string?): boolean
  if type(body) ~= "string" then
    return false
  end
  local head = body:sub(1, 2048):lower()
  if head:find("<!doctype html", 1, true) or head:find("<html", 1, true) then
    return true
  end
  local tags = 0
  for _ in head:gmatch("<%a+[^>]*>") do
    tags = tags + 1
    if tags >= 3 then
      return true
    end
  end
  return false
end

--[[
  Percent decoding, used for the `uddg=` target inside DuckDuckGo's redirect
  links. `+` means a space in a query string, which is where these come from.
]]
function M.url_decode(s: string?): string
  if type(s) ~= "string" then
    return ""
  end
  local plus_decoded = s:gsub("+", " ")
  return (plus_decoded:gsub("%%(%x%x)", function(hex)
    local code = tonumber(hex, 16)
    if code == nil then
      return ""
    end
    if code < 128 then
      return string.char(code)
    end
    -- rebuild the original bytes so multi-byte UTF-8 survives
    return string.char(tonumber(hex, 16))
  end))
end

function M.url_encode(s: string?): string
  if type(s) ~= "string" then
    return ""
  end
  return (s:gsub("[^%w%-%._~]", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

--[[
  Turn a redirect wrapper into the real target:

    //duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com&rut=...
      -> https://example.com
]]
function M.unwrap_redirect(href: string?): string
  local link = trim(href or "")
  if link == "" then
    return ""
  end
  local encoded = link:match("[?&]uddg=([^&]+)")
  if encoded ~= nil then
    link = M.url_decode(encoded)
  end
  if link:sub(1, 2) == "//" then
    link = "https:" .. link
  end
  return link
end

function M.truncate(s: string?, limit: number?): (string, boolean)
  local text = s or ""
  local max = tonumber(limit) or 0
  if max <= 0 or #text <= max then
    return text, false
  end
  return text:sub(1, max) .. "\n\n[... recortado, " .. tostring(#text - max) .. " caracteres omitidos ...]", true
end

function M.one_line(s: string?, limit: number?): string
  local text = (s or ""):gsub("%s+", " ")
  return M.truncate(trim(text), limit)
end

--[[
  Fenced code blocks, as a list of `{ lang, code }`.

  Streaming aware: an unterminated fence still yields the block so far, so the
  "copy last code block" button works while the answer is still arriving.
  Indented (four-space) blocks are deliberately ignored: telling them apart
  from ordinary indented prose needs the surrounding markdown context.
]]
function M.code_blocks(markdown: string?)
  local blocks = {}
  if type(markdown) ~= "string" or markdown == "" then
    return blocks
  end
  -- Plain prose is the common case. A plain find is much cheaper than running
  -- the line-by-line pattern scan inside a script callback with a CPU budget.
  if markdown:find("```", 1, true) == nil and markdown:find("~~~", 1, true) == nil then
    return blocks
  end
  local open = false
  local lang = ""
  local buffer = {}
  for line in (markdown .. "\n"):gmatch("([^\n]*)\n") do
    local stripped = trim(line)
    if not open then
      local fence = stripped:match("^```(.*)$")
      if fence == nil then
        fence = stripped:match("^~~~(.*)$")
      end
      if fence ~= nil then
        open = true
        lang = trim(fence)
        buffer = {}
      end
    elseif stripped:match("^```%s*$") or stripped:match("^~~~%s*$") then
      table.insert(blocks, { lang = lang, code = table.concat(buffer, "\n") })
      open = false
      lang = ""
      buffer = {}
    else
      table.insert(buffer, line)
    end
  end
  if open and #buffer > 0 then
    table.insert(blocks, { lang = lang, code = table.concat(buffer, "\n") })
  end
  return blocks
end

function M.last_code_block(markdown: string?)
  local blocks = M.code_blocks(markdown)
  return blocks[#blocks]
end


--[[
  Split markdown into a sequence of segments alternating between plain text
  and fenced code blocks. Each segment is a table:
    { is_code = false, text = "..." }
    { is_code = true,  lang = "lua", code = "print('hi')" }
  This lets the panel render markdown interspersed with copyable code-block rows.
]]
function M.split_markdown_code_blocks(markdown: string?)
  local segments = {}
  if type(markdown) ~= "string" or markdown == "" then
    table.insert(segments, { is_code = false, text = "" })
    return segments
  end
  if markdown:find("```", 1, true) == nil and markdown:find("~~~", 1, true) == nil then
    return { { is_code = false, text = markdown } }
  end
  local open = false
  local lang = ""
  local buffer = {}
  local plain_buffer = {}
  local function flush_plain()
    if #plain_buffer > 0 then
      table.insert(segments, { is_code = false, text = table.concat(plain_buffer, "\n") })
      plain_buffer = {}
    end
  end
  for line in (markdown .. "\n"):gmatch("([^\n]*)\n") do
    local stripped = trim(line)
    if not open then
      local fence = stripped:match("^```(.*)$")
      if fence == nil then
        fence = stripped:match("^~~~(.*)$")
      end
      if fence ~= nil then
        flush_plain()
        open = true
        lang = trim(fence)
        buffer = {}
      else
        table.insert(plain_buffer, line)
      end
    elseif stripped:match("^```%s*$") or stripped:match("^~~~%s*$") then
      flush_plain()
      table.insert(segments, { is_code = true, lang = lang, code = table.concat(buffer, "\n") })
      open = false
      lang = ""
      buffer = {}
    else
      table.insert(buffer, line)
    end
  end
  if open and #buffer > 0 then
    flush_plain()
    table.insert(segments, { is_code = true, lang = lang, code = table.concat(buffer, "\n") })
  else
    flush_plain()
  end
  return segments
end


function M.count_lines(s: string?): number
  local n = 0
  for _ in tostring(s or ""):gmatch("\n") do
    n = n + 1
  end
  return n + 1
end

-- ---------------------------------------------------------------------------
-- Search result parsing (DuckDuckGo HTML endpoint)
-- ---------------------------------------------------------------------------

--[[
  DuckDuckGo's HTML endpoint answers `?q=` with a plain server-rendered page:

    <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=...">Title</a>
    ...
    <a class="result__snippet" href="...">Snippet</a>

  The href is a redirect wrapper carrying the real target percent-encoded in
  `uddg`, so every link is unwrapped before the model sees it.
]]
function M.search_url(query: string?, endpoint: string?): string
  local base = endpoint or "https://html.duckduckgo.com/html/"
  return base .. "?q=" .. M.url_encode(trim(query or ""))
end

function M.parse_search_results(html: string?, limit: number?)
  local results = {}
  if type(html) ~= "string" or html == "" then
    return results
  end
  local max = tonumber(limit) or 6
  local anchors = {}
  local cursor = 1
  while true do
    local position = html:find('class="result__a"', cursor, true)
    if position == nil then
      break
    end
    table.insert(anchors, position)
    cursor = position + 1
  end
  for index, start_position in ipairs(anchors) do
    if #results >= max then
      break
    end
    -- one block per result, so the snippet that follows the title belongs to it
    local end_position = anchors[index + 1] or #html
    local block = html:sub(start_position, end_position)
    local href, title = block:match('href="([^"]*)"[^>]*>(.-)</a>')
    if href ~= nil then
      local snippet = block:match('class="result__snippet"[^>]*>(.-)</a>') or ""
      table.insert(results, {
        title = M.collapse_whitespace(M.decode_entities(M.strip_tags(title))),
        url = M.unwrap_redirect(M.decode_entities(href)),
        snippet = M.one_line(M.decode_entities(M.strip_tags(snippet)), 300),
      })
    end
  end
  return results
end

function M.format_search_results(results, query: string?, limit: number?): string
  local clean_query = trim(query or "")
  if type(results) ~= "table" or #results == 0 then
    return "Sin resultados para \"" .. clean_query .. "\". Prueba con otra consulta."
  end
  local lines = { "Resultados para: " .. clean_query, "" }
  for index, result in ipairs(results) do
    table.insert(lines, tostring(index) .. ". " .. result.title)
    table.insert(lines, "   " .. result.url)
    if result.snippet ~= "" then
      table.insert(lines, "   " .. result.snippet)
    end
  end
  return M.truncate(table.concat(lines, "\n"), limit or 6000)
end

return M
