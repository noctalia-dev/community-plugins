-- service.luau
-- Servico headless: busca cada feed configurado, extrai itens (RSS <item> ou
-- Atom <entry>), compara com o que ja foi visto, notifica o que for novo e
-- publica a contagem de nao-lidos em noctalia.state para o widget consumir.

local seen = {}          -- { [feedUrl] = { [itemId] = true, ... } }
local unread = 0
local recentItems = {}   -- lista dos itens mais recentes, mais novo primeiro
local dataPath = nil

local MAX_RECENT_ITEMS = 50

-- Limites para manter o parsing rapido o suficiente para o orcamento de CPU
-- (muito apertado) do callback assincrono.
local MAX_BODY_BYTES  = 8000   -- so olhamos os primeiros ~8KB do corpo do feed
local MAX_ITEM_BYTES  = 400    -- corta cada bloco <item>/<entry> antes de extrair tags
local MAX_ITEMS       = 8      -- para de processar itens depois desse tanto

local function truncate(s, n)
  if not s or #s <= n then
    return s
  end
  return s:sub(1, n)
end

-- ---------------------------------------------------------------------------
-- Persistencia (sobrevive a restarts do plugin/shell)
-- ---------------------------------------------------------------------------

local function loadState()
  local dir = noctalia.pluginDataDir()
  if not dir then
    return
  end
  dataPath = dir .. "/seen.json"

  local raw = noctalia.readFile(dataPath)
  if raw then
    local decoded = noctalia.json.decode(raw)
    if type(decoded) == "table" then
      seen = decoded
    end
  end
end

local function saveState()
  if dataPath then
    noctalia.writeFile(dataPath, noctalia.json.encode(seen))
  end
end

-- ---------------------------------------------------------------------------
-- Parsing minimo de RSS 2.0 / Atom 1.0 usando SO busca literal (string.find
-- com plain=true) - evita o motor de padroes do Lua (".-", "[^>]", etc.),
-- que parece caro demais para o orcamento de CPU deste ambiente.
-- ---------------------------------------------------------------------------

local function decodeEntities(s)
  if not s then
    return s
  end
  s = s:gsub("&lt;", "<")
  s = s:gsub("&gt;", ">")
  s = s:gsub("&quot;", '"')
  s = s:gsub("&#39;", "'")
  s = s:gsub("&amp;", "&")
  return noctalia.string.trim(s)
end

local function stripCdata(s)
  if s:sub(1, 9) == "<![CDATA[" then
    local endPos = s:find("]]>", 10, true)
    if endPos then
      return s:sub(10, endPos - 1)
    end
  end
  return s
end

-- Extrai o conteudo de <tag>...</tag> usando so find() literal.
local function findTagContent(s, tag)
  local openStart = s:find("<" .. tag, 1, true)
  if not openStart then
    return nil
  end
  local openEnd = s:find(">", openStart, true)
  if not openEnd then
    return nil
  end
  local closeStart = s:find("</" .. tag .. ">", openEnd, true)
  if not closeStart then
    return nil
  end
  return decodeEntities(stripCdata(s:sub(openEnd + 1, closeStart - 1)))
end

-- Extrai um valor de atributo de dentro da PRIMEIRA ocorrencia de <tag ...>.
local function findAttr(s, tag, attr)
  local openStart = s:find("<" .. tag, 1, true)
  if not openStart then
    return nil
  end
  local openEnd = s:find(">", openStart, true)
  if not openEnd then
    return nil
  end
  local tagSrc = s:sub(openStart, openEnd)
  local attrStart = tagSrc:find(attr .. '="', 1, true)
  if not attrStart then
    return nil
  end
  local valueStart = attrStart + #attr + 2
  local valueEnd = tagSrc:find('"', valueStart, true)
  if not valueEnd then
    return nil
  end
  return tagSrc:sub(valueStart, valueEnd - 1)
end

local function extractLink(block)
  local rssLink = findTagContent(block, "link") -- RSS: <link>URL</link>
  if rssLink and rssLink ~= "" then
    return rssLink
  end
  return findAttr(block, "link", "href") -- Atom: <link href="URL"/>
end

local function extractId(block)
  return findTagContent(block, "guid") or findTagContent(block, "id") or extractLink(block)
end

-- Encontra o PROXIMO bloco <tag ...>...</tag> a partir de fromPos, usando so
-- find() literal. Retorna o conteudo do bloco (ja cortado) e a posicao onde
-- parar na proxima chamada - permite processar um item por vez, em ticks
-- separados, em vez de tudo de uma vez dentro do callback http.
local function findNextBlock(xml, tag, fromPos, maxItemBytes)
  local openStart = xml:find("<" .. tag, fromPos, true)
  if not openStart then
    return nil, fromPos
  end
  local openEnd = xml:find(">", openStart, true)
  if not openEnd then
    return nil, fromPos
  end
  local closeTag = "</" .. tag .. ">"
  local closeStart = xml:find(closeTag, openEnd, true)
  if not closeStart then
    return nil, fromPos
  end
  local contentEnd = math.min(closeStart - 1, openEnd + maxItemBytes)
  local block = xml:sub(openEnd + 1, contentEnd)
  return block, closeStart + #closeTag
end

-- ---------------------------------------------------------------------------
-- Fila de processamento incremental: o callback http so guarda o corpo (ja
-- cortado) na fila; o parsing de verdade acontece aos poucos, um item por
-- tick de update(), porque o orcamento de CPU do callback assincrono e
-- pequeno demais para processar um feed inteiro de uma vez.
-- ---------------------------------------------------------------------------

local queue = {} -- lista de { url=, body=, pos=, tag=, feedTitle=, items=, notifyBudget= }

local function enqueueFeed(url, body, notifyBudget)
  table.insert(queue, {
    url          = url,
    body         = truncate(body, MAX_BODY_BYTES),
    pos          = 1,
    tag          = "item",
    triedEntry   = false,
    feedTitle    = nil,
    items        = {},
    notifyBudget = notifyBudget,
  })
end

-- Finaliza um feed da fila: compara com o que ja foi visto, notifica o que
-- for novo e publica o estado. E um passo isolado (nao mistura com a
-- extracao de itens) para manter cada callback pequeno.
local function finalizeFeed(f)
  local url = f.url
  seen[url] = seen[url] or {}
  local firstRun = next(seen[url]) == nil
  local notifyEnabled = noctalia.getConfig("notify_new")
  local newCount = 0

  for _, item in ipairs(f.items) do
    local id = item.id or item.link or item.title
    if id and not seen[url][id] then
      seen[url][id] = true
      newCount = newCount + 1

      if not firstRun then
        table.insert(recentItems, 1, {
          id        = id,
          title     = item.title,
          link      = item.link,
          feedTitle = f.feedTitle,
        })
        if notifyEnabled and f.notifyBudget.count < f.notifyBudget.max then
          f.notifyBudget.count = f.notifyBudget.count + 1
          noctalia.notify(item.title, f.feedTitle)
        end
      end
    end
  end

  while #recentItems > MAX_RECENT_ITEMS do
    table.remove(recentItems)
  end

  if not firstRun and newCount > 0 then
    unread = unread + newCount
    noctalia.state.set("unread", unread)
    noctalia.state.set("items", noctalia.json.encode(recentItems))
  end

  saveState()
end

-- Processa UM pequeno passo da fila: extrai no maximo um item do feed que
-- esta na frente da fila. Chamado uma vez por tick de update().
local function processQueueStep()
  local f = queue[1]
  if not f then
    return
  end

  if not f.feedTitle then
    f.feedTitle = findTagContent(truncate(f.body, 300), "title") or f.url
    return -- um passo por tick: so o titulo desta vez
  end

  if #f.items >= MAX_ITEMS then
    table.remove(queue, 1)
    finalizeFeed(f)
    return
  end

  local block, nextPos = findNextBlock(f.body, f.tag, f.pos, MAX_ITEM_BYTES)

  if not block then
    if f.tag == "item" and not f.triedEntry then
      -- RSS nao encontrado: tenta Atom (<entry>) a partir do comeco
      f.tag = "entry"
      f.pos = 1
      f.triedEntry = true
      return
    end
    -- acabaram os itens (ou nao achou nenhum) - finaliza
    table.remove(queue, 1)
    finalizeFeed(f)
    return
  end

  f.pos = nextPos
  table.insert(f.items, {
    title = findTagContent(block, "title") or "(sem titulo)",
    link  = extractLink(block),
    id    = extractId(block),
  })
end

-- ---------------------------------------------------------------------------
-- Ciclo de busca
-- ---------------------------------------------------------------------------

local function checkFeed(url, notifyBudget)
  -- o callback http faz o MINIMO possivel: so guarda o corpo na fila.
  -- Todo o parsing de verdade acontece depois, aos poucos, em processQueueStep().
  noctalia.http({ url = url, headers = { "Accept: application/rss+xml, application/atom+xml, application/xml, text/xml" } }, function(res)
    if not res.ok or not res.body or res.body == "" then
      return
    end
    enqueueFeed(url, res.body, notifyBudget)
  end)
end

local function fetchAll()
  local urls = noctalia.getConfig("feed_urls") or {}
  local notifyBudget = { count = 0, max = noctalia.getConfig("max_notifications_per_cycle") or 5 }

  for _, url in ipairs(urls) do
    if url and noctalia.string.trim(url) ~= "" then
      checkFeed(url, notifyBudget)
    end
  end
end

local REFRESH_TICK_MS = 1000 -- update() roda a cada segundo: drena a fila aos poucos
local ticksUntilFetch = 1

local function applyInterval()
  local minutes = noctalia.getConfig("refresh_minutes") or 30
  if minutes < 1 then
    minutes = 1
  end
  noctalia.setUpdateInterval(REFRESH_TICK_MS)
  ticksUntilFetch = math.floor((minutes * 60000) / REFRESH_TICK_MS)
end

-- ---------------------------------------------------------------------------
-- Ciclo de vida
-- ---------------------------------------------------------------------------

loadState()
applyInterval()
noctalia.state.set("unread", unread)
noctalia.state.set("items", noctalia.json.encode(recentItems))
fetchAll() -- primeira leitura: so marca como "vistos", sem notificar (firstRun)

function update()
  processQueueStep() -- sempre drena um pedacinho da fila, se houver algo

  ticksUntilFetch = ticksUntilFetch - 1
  if ticksUntilFetch <= 0 then
    fetchAll()
    local minutes = noctalia.getConfig("refresh_minutes") or 30
    if minutes < 1 then
      minutes = 1
    end
    ticksUntilFetch = math.floor((minutes * 60000) / REFRESH_TICK_MS)
  end
end

function onConfigChanged()
  applyInterval()
  fetchAll()
end

function onIpc(_event, payload)
  if _event == "refresh" then
    fetchAll()
  elseif _event == "mark-read" then
    unread = 0
    noctalia.state.set("unread", 0)
  end
end
