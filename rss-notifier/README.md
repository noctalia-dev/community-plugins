# RSS Utils

Plugin para Noctalia que monitora feeds RSS e exibe notificações quando novos itens são encontrados.

---

## Installation

1. Clone este repositório para o diretório de plugins do Noctalia:

git clone https://github.com/nilsonlinux/rss-notifier.git ~/.config/noctalia/plugins/rss-notifier
text

2. Reinicie o Noctalia ou recarregue os plugins.

---

## Plugin

**Manifest ID:** `nilsonlinux/rss-notifier`

Este plugin fornece os seguintes componentes:

### Widget: `badge`
Um widget que exibe um emblema (badge) na barra lateral ou painel com a contagem de itens não lidos dos feeds monitorados.

### Panel: `list`
Um painel que exibe uma lista detalhada de todos os itens de RSS coletados. Pode ser aberto através do comando IPC.

### Service: `fetcher`
Serviço em background responsável por buscar e atualizar os feeds RSS no intervalo de tempo configurado.

---

## Settings

As seguintes opções de configuração estão disponíveis para o plugin:

| Opção | Tipo | Padrão | Descrição |
| :--- | :--- | :--- | :--- |
| **feeds** | `array` | `[]` | Lista de URLs de feeds RSS/Atom para monitorar. |
| **refresh_interval** | `integer` | `30` | Intervalo em minutos para verificar novos itens. |
| **notify_new_items** | `boolean` | `true` | Exibe uma notificação no sistema quando novos itens são encontrados. |
| **max_items_per_feed** | `integer` | `10` | Número máximo de itens recentes mantidos em cache por feed. |

---

## Usage

### Abrindo o Painel
Para abrir ou fechar o painel com a lista de itens do RSS Utils, utilize o seguinte comando na barra de comandos do Noctalia:

noctalia msg panel-toggle nilsonlinux/rss-notifier:list
text


### Funcionamento Básico
1. Após adicionar as URLs dos feeds nas **Configurações**, o serviço `fetcher` verificará automaticamente por novidades no intervalo definido.
2. Quando novos itens são detectados, uma notificação será exibida (se habilitado) e o widget `badge` será atualizado.
3. Ao abrir o painel através do comando acima, você poderá visualizar a lista de itens.

---

## Dependencies

- [Noctalia](https://github.com/noctalia/noctalia) (versão mais recente)
- Acesso à internet para buscar os feeds RSS.

---

## License

MIT
