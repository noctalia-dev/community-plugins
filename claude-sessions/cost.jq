# Input: transcript entries. Assistant messages repeat once per content block, so dedupe by message id.
($p[0].models) as $rates
| map(select(.type == "assistant" and .message.usage and .message.id)) | unique_by(.message.id)
| map(
    .message as $m
    | ($m.model // "" | if test("sonnet") then "sonnet" elif test("haiku") then "haiku" elif test("fable") then "fable" else "opus" end) as $fam
    | $rates[$fam] as $r | $m.usage as $u
    | ($u.input_tokens // 0) * $r.input + ($u.output_tokens // 0) * $r.output
      + ($u.cache_read_input_tokens // 0) * $r.cache_read + ($u.cache_creation_input_tokens // 0) * $r.cache_write)
| add // 0
