# Maildir

Show unread mail count in specified Maildir paths.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nickh/maildir` |
| Entries | Bar widget: `maildir` |

## Requirements

The unread counter runs `find` and `grep` (declared in `dependencies`).
Both ship with every standard Linux base system, so no extra installation
is normally needed.

## Usage

Add the `maildir` widget from Noctalia's widget picker.

The count is refreshed every `update_interval` seconds by one external
`find`/`grep` pipeline per tick; directory walking never happens inside the
plugin VM, so the widget stays well inside Noctalia's per-callback CPU
budget on any mailbox size. After a reload the widget shows the `nomail`
text for one interval until the first count arrives.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `maildir` | `string` | `~/Mail` | Path to maildir tree |
| `inboxes` | `string_list` | `[INBOX:in]` | List of inbox locations to montor, with `:label` appended |
| `count_cur` | `bool` | `true` | Also count unread messages in `<inbox>/cur/` (filenames whose flags section does not contain `S`). Turn off to count `new/` only |
| `update_interval` | `int` | `10` | Period in seconds between checks for new mail |
| `click_command` | `string` | `""` | Command to run when widget is clicked |

## Notes

- A message in `cur/` counts as unread when its filename ends with a flags
  section (`:2,S`, legacy `,2,S`) whose letters do not contain `S`, or has
  no flags section at all. Only regular files at the top level of `new/`
  and `cur/` are counted, as the maildir format specifies.
- Paths from `maildir` and `inboxes` are shell-quoted before being passed
  to the counter; they are never shell-expanded as code.
