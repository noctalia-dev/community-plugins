-- panel.luau
-- Janela pop-up mostrada ao clicar no widget da barra: lista os itens mais
-- recentes, ou um estado vazio com icone quando nao ha nada novo.

local items = {}

-- declaradas antes para permitir referencia cruzada entre elas
local render
local dismissItem
local itemRow
local emptyState

local function openLink(link)
  if not link or link == "" then
    return
  end
  -- escapa aspas simples pra evitar quebrar o comando do shell
  local safe = link:gsub("'", "'\\''")
  noctalia.runAsync("xdg-open '" .. safe .. "'")
end

dismissItem = function(item)
  -- remove localmente (resposta imediata) e avisa o service pra nao
  -- reaparecer nas proximas atualizacoes
  for i, it in ipairs(items) do
    if it == item then
      table.remove(items, i)
      break
    end
  end
  render()

  local id = item.id or item.link or item.title
  if id then
    local safe = tostring(id):gsub("'", "'\\''")
    noctalia.runAsync("noctalia msg plugin nilsonlinux/rss-notifier:fetcher all dismiss '" .. safe .. "'")
  end
end

itemRow = function(item)
  return ui.row({
    key     = item.id or item.link or item.title,
    gap     = 6,
    padding = 10,
    radius  = 8,
    fill    = "surface_variant/0.4",
    align   = "center",
  }, {
    ui.column({
      gap      = 2,
      flexGrow = 1,
      onClick  = function() openLink(item.link) end,
    }, {
      ui.label({ text = item.title or "(sem titulo)", fontWeight = "bold", maxLines = 2 }),
      ui.label({ text = item.feedTitle or "", fontSize = 12, color = "outline" }),
    }),
    ui.button({
      glyph       = "close",
      variant     = "ghost",
      controlSize = "sm",
      tooltip     = "Dispensar",
      onClick     = function() dismissItem(item) end,
    }),
  })
end

emptyState = function()
  return ui.column({ gap = 10, align = "center", padding = 32, flexGrow = 1, justify = "center" }, {
    ui.glyph({ name = "rss", size = 32, color = "outline" }),
    ui.label({ text = "Nenhuma atualização", color = "outline" }),
  })
end

render = function()
  local body

  if #items == 0 then
    body = emptyState()
  else
    local rows = {}
    for _, item in ipairs(items) do
      table.insert(rows, itemRow(item))
    end
    body = ui.scroll({ gap = 6, flexGrow = 1 }, rows)
  end

  local headerButtons = {}
  if #items > 0 then
    table.insert(headerButtons, ui.button({ glyph = "trash", variant = "ghost", controlSize = "sm", tooltip = "Limpar tudo", onClick = "onClearAllClicked" }))
  end
  table.insert(headerButtons, ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = "Atualizar agora", onClick = "onRefreshClicked" }))
  table.insert(headerButtons, ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", onClick = "onCloseClicked" }))

  panel.render(ui.column({ gap = 10, padding = 12, fill = true }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "RSS/Atom Notifier", fontSize = 15, fontWeight = "bold" }),
      ui.row({ gap = 4 }, headerButtons),
    }),
    ui.separator({}),
    body,
  }))
end

noctalia.state.watch("items", function(raw)
  local ok, decoded = pcall(noctalia.json.decode, raw or "[]")
  items = (ok and decoded) or {}
  render()
end)

function onOpen(_context)
  render()
  -- abrir o painel conta como "li as novidades": zera o badge no service
  noctalia.runAsync("noctalia msg plugin nilsonlinux/rss-notifier:fetcher all mark-read")
end

function onRefreshClicked()
  noctalia.runAsync("noctalia msg plugin nilsonlinux/rss-notifier:fetcher all refresh")
end

function onClearAllClicked()
  items = {}
  render()
  noctalia.runAsync("noctalia msg plugin nilsonlinux/rss-notifier:fetcher all clear-all")
end

function onCloseClicked()
  panel.close()
end
