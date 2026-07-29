# RSS Notifier

Plugin para Noctalia que monitora feeds RSS e exibe notificações quando novos itens são encontrados.

## Installation

Clone o repositório e reinicie o Noctalia.

## Usage

Para abrir ou fechar o painel com a lista de itens do RSS Notifier, utilize o seguinte comando na barra de comandos do Noctalia:

noctalia msg panel-toggle nilsonlinux/rss-notifier:list

Após adicionar as URLs dos feeds nas configurações, o plugin verificará automaticamente por novidades e notificará o usuário.

## Settings

| Opção | Tipo | Padrão | Descrição |
| :--- | :--- | :--- | :--- |
| feeds | array | [] | Lista de URLs de feeds RSS/Atom para monitorar. |
| refresh_interval | integer | 30 | Intervalo em minutos para verificar novos itens. |
| notify_new_items | boolean | true | Exibe notificação no sistema quando novos itens são encontrados. |
| max_items_per_feed | integer | 10 | Número máximo de itens mantidos em cache por feed. |

## Dependencies

- Noctalia
- Acesso à internet

## License

MIT
