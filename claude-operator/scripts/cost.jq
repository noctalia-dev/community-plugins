# Input: transcript lines carrying "usage". Assistant messages repeat once per content
# block with the same message id and usage, so each id counts once. Unknown models add 0.
include "pricing";
map(select(.type == "assistant" and .message.usage and .message.id)) | unique_by(.message.id)
| map(price(.message.model) as $r | if $r == null then 0 else .message.usage | usage_cost($r) end)
| add // 0
