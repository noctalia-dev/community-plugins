# RSS/Atom Notifier

Acompanha uma lista de feeds RSS/Atom e avisa quando surgem itens novos.
Mostra uma pílula com a contagem de não lidos encostada no ícone da barra e,
ao clicar, abre uma janelinha com a lista dos itens mais recentes.

## Plugin

| Campo   | Valor                                                          |
| ------- | --------------------------------------------------------------- |
| Entries | Service: `fetcher`; Bar widget: `badge`; Panel: `list`          |

## Uso

Adicione o widget **"RSS/Atom Notifier"** a qualquer barra em
**Settings → Bar → Add Widget**. Antes disso, cadastre pelo menos uma URL de
feed em **Settings → Plugins → RSS/Atom Notifier** (veja Settings abaixo) —
sem isso o widget fica sempre com o badge zerado.

- **Clique esquerdo**: abre/fecha a janelinha com a lista dos itens mais
  recentes. Abrir a janelinha já marca tudo como lido (zera o badge). Clicar
  num item da lista abre o link no navegador padrão (`xdg-open`).
- **Clique direito**: força uma checagem imediata de todos os feeds, sem
  esperar o próximo ciclo de `refresh_minutes`.
- **Clique do meio**: comportamento padrão do Noctalia (abre as opções de
  aparência/posição daquela instância do widget na barra).

A janelinha também pode ser aberta/fechada por IPC:

```sh
noctalia msg panel-toggle voce/rss-notifier:list
```

E o service (que é um singleton, por isso o alvo `all`) aceita:

```sh
# força um refresh manual de todos os feeds
noctalia msg plugin voce/rss-notifier:fetcher all refresh

# marca tudo como lido (zera o badge) sem abrir a janelinha
noctalia msg plugin voce/rss-notifier:fetcher all mark-read
```

## Settings

Editadas em **Settings → Plugins → RSS/Atom Notifier** (compartilhadas pelo
service e pelo widget).

| Setting                       | Tipo          | Padrão | Descrição                                                                 |
| ------------------------------ | ------------- | ------ | -------------------------------------------------------------------------- |
| `feed_urls`                    | `string_list` | `[]`   | Uma URL de feed RSS ou Atom por entrada.                                   |
| `refresh_minutes`              | `int`         | `30`   | De quanto em quanto tempo os feeds são checados (1–1440 minutos).          |
| `notify_new`                   | `bool`        | `true` | Mostra uma notificação de desktop para cada item novo encontrado.          |
| `max_notifications_per_cycle`  | `int`         | `5`    | *(Avançado)* Limite de notificações disparadas por ciclo de checagem, para evitar enxurrada quando muitos itens aparecem de uma vez (1–50). |

## Notas

- **Parsing sem dependências externas.** O runtime Luau do Noctalia não traz
  um parser XML, então a extração de `<title>`/`<link>`/`<guid>` (RSS) ou
  `<title>`/`<link>`/`<id>` (Atom) é feita só com `string.find` literal
  (`plain = true`) — sem `gmatch`/padrões, que se mostraram caros demais para
  o orçamento de CPU dos callbacks assíncronos deste ambiente.
- **Processamento incremental.** O callback HTTP não faz parsing nenhum: ele
  só guarda o corpo da resposta (cortado a ~8KB) numa fila. Um item por vez é
  extraído a cada tick de `update()` (a cada 1 segundo), até no máximo 8 itens
  por feed por ciclo. Isso significa que, logo após adicionar ou atualizar um
  feed, a lista pode demorar alguns segundos para aparecer completa na
  janelinha — é intencional, para não estourar o orçamento de CPU do
  callback.
- **Primeira leitura é silenciosa.** Ao adicionar uma URL nova, a primeira
  checagem só marca os itens existentes como "já vistos", sem notificar nem
  contar como não lido — assim você não é bombardeado com o histórico inteiro
  do feed de uma vez. Notificações e contagem só valem a partir da segunda
  checagem em diante.
- **Persistência.** Os itens já vistos ficam salvos em
  `noctalia.pluginDataDir()/seen.json`, por feed, e sobrevivem a reinícios do
  Noctalia. Essa lista cresce ao longo do tempo e não é podada automaticamente
  — em uso muito prolongado, considere limpar esse arquivo manualmente se ele
  ficar grande.
- **Sem overlay real de badge.** A API de widgets de barra do Noctalia não tem
  posicionamento absoluto/z-index, então não é possível desenhar um número
  sobre o cantinho do ícone (como em ícones de app de celular). O que o
  widget faz é renderizar uma pílula colorida com a contagem encostada à
  esquerda do ícone, via `barWidget.render()` e a API declarativa `ui.*`.
- **Rede.** Cada feed é buscado via `noctalia.http()` (GET simples, com
  header `Accept` pedindo XML/RSS/Atom). Nenhum outro arquivo é baixado e
  nenhum processo externo é aberto, exceto `xdg-open` ao clicar num item da
  lista para abrir o link no navegador.
