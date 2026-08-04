-- widget.luau
-- Widget de barra: icone RSS com uma pilula colorida (badge) de itens nao
-- lidos encostada no lado esquerdo, publicada pelo service via noctalia.state.

local unread = 0

local function render()
  local children = {}

  if unread > 0 then
    -- pilula: um container com fundo colorido e cantos arredondados, com o
    -- numero dentro - o mais perto que a API declarativa chega de um "badge"
    table.insert(children, ui.row({
      fill     = "primary",
      radius   = 8,
      paddingH = 5,
      paddingV = 1,
      align    = "center",
      justify  = "center",
    }, {
      ui.label({ text = tostring(unread), fontSize = 10, fontWeight = "bold", color = "on_primary" }),
    }))
  end

  table.insert(children, ui.glyph({ name = noctalia.getConfig("glyph") or "rss", size = 14 }))

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 4, align = "center" }, children))

  barWidget.setTooltip(unread > 0 and (tostring(unread) .. " novo(s) item(ns) nos feeds") or "Nenhum item novo")
end

noctalia.state.watch("unread", function(value)
  unread = value or 0
  render()
end)

render()

function update()
  noctalia.setUpdateInterval(5000) -- so mantem o widget "vivo"; os dados reais vem do state
end

function onConfigChanged()
  render() -- pega o novo glyph quando o usuario troca o icone nas settings do widget
end

function onClick()
  -- abre/fecha a janelinha com a lista de itens; o proprio painel marca
  -- como lido (zera o badge) quando e aberto, via IPC pro service
  noctalia.togglePanel("nilsonlinux/rss-notifier:list")
end

function onRightClick()
  -- clique direito: forca uma nova checagem imediata dos feeds,
  -- enviando um evento IPC para a entry [[service]] (que e um singleton, alvo "all")
  noctalia.runAsync("noctalia msg plugin nilsonlinux/rss-notifier:fetcher all refresh")
  noctalia.notify("RSS/Atom Notifier", "Atualizando feeds...")
end

function onIpc(event, payload)
  if event == "set" then
    unread = tonumber(payload) or 0
    render()
  end
end
