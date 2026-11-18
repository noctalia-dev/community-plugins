def lastof(f): map(select(f)) | last;
def blocks: .message.content | if type == "array" then . else [] end;
def oneline: gsub("\\s+"; " ") | .[0:120];
(lastof(.type == "assistant" and .message.usage != null)) as $a
| (lastof(.type == "assistant" and any(blocks[]; .type == "tool_use")) | blocks | map(select(.type == "tool_use")) | last) as $tool
| (lastof(.type == "assistant" and any(blocks[]; .name == "TodoWrite")) | blocks | map(select(.name == "TodoWrite")) | last | .input.todos) as $todos
| (lastof(.type == "system" and .subtype == "turn_duration")) as $turn
| {
    title: (lastof(.type == "ai-title") | .aiTitle),
    mode: (lastof(.type == "permission-mode") | .permissionMode),
    branch: (lastof(.gitBranch != null) | .gitBranch),
    model: ($a.message.model // null | if . then sub("^claude-"; "") else . end),
    context: ($a.message.usage | if . then .input_tokens + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0) + .output_tokens else null end),
    tool: (if $tool then $tool.name + ": " + (($tool.input | .command // .file_path // .pattern // .description // .url // .query // .prompt // "") | tostring | oneline) else null end),
    todos: (if ($todos | type) == "array" and ($todos | length) > 0 then {
      done: ($todos | map(select(.status == "completed")) | length),
      total: ($todos | length),
      current: ($todos | map(select(.status == "in_progress")) | first | if . then (.activeForm // .content) else null end)
    } else null end),
    prompt: ($prompt | oneline),
    cost: $cost,
    turnMs: $turn.durationMs,
    agents: ($turn.pendingBackgroundAgentCount // 0)
  }
