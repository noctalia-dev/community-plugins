# Price row for a model id from pricing.json ($p): the exact id (snapshot date dropped),
# else the newest model of the same family, else null.
def price($m):
  ($m // "" | sub("-[0-9]{8}$"; "")) as $id
  | ($p.models // {}) as $models
  | $models[$id] // $models[($p.families // {})[($id | split("-")[1] // "")] // ""] // null;

# Estimated USD cost of one message's usage object (.) at price row $r. Cache writes that
# Claude Code records as 1-hour (usage.cache_creation) cost more than 5-minute ones; writes
# with no breakdown count as 5-minute. A pricing.json without cache_write_1h falls back.
def usage_cost($r):
  (.cache_creation.ephemeral_1h_input_tokens // 0) as $w1h
  | (.input_tokens // 0) * $r.input + (.output_tokens // 0) * $r.output
    + (.cache_read_input_tokens // 0) * $r.cache_read
    + ((.cache_creation_input_tokens // 0) - $w1h) * $r.cache_write
    + $w1h * ($r.cache_write_1h // $r.cache_write);
