include "pricing";
def lastof(f): map(select(f)) | last;
def blocks: .message.content | if type == "array" then . else [] end;
def oneline: gsub("\\s+"; " ") | .[0:160];
(lastof(.type == "assistant" and .message.usage != null)) as $a
| ($a.message.model // null) as $model
| (lastof(.type == "assistant" and any(blocks[]; .type == "tool_use")) | blocks | map(select(.type == "tool_use")) | last) as $tool
| (lastof(.type == "assistant" and any(blocks[]; .name == "TodoWrite")) | blocks | map(select(.name == "TodoWrite")) | last | .input.todos) as $todos
| (lastof(.type == "system" and .subtype == "turn_duration")) as $turn
| (lastof(.type == "assistant" and any(blocks[]; .type == "text" and (.text // "") != ""))
   | blocks | map(select(.type == "text") | .text) | join("\n\n")) as $reply
| {
    title: (lastof(.type == "ai-title") | .aiTitle),
    mode: (lastof(.type == "permission-mode") | .permissionMode),
    branch: (lastof((.gitBranch // "") != "") | .gitBranch | if . == "HEAD" then null else . end),
    model: ($model | if . then sub("^claude-"; "") else . end),
    # What fills the window: everything sent in, not what came back.
    context: ($a.message.usage | if . then (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0) else null end),
    contextMax: (if $model then price($model).max else null end // 200000),
    tool: (if $tool then $tool.name + ": " + (($tool.input | .command // .file_path // .pattern // .description // .url // .query // .prompt // "") | tostring | oneline) else null end),
    todos: (if ($todos | type) == "array" and ($todos | length) > 0 then {
      done: ($todos | map(select(.status == "completed")) | length),
      total: ($todos | length),
      current: ($todos | map(select(.status == "in_progress")) | first | if . then (.activeForm // .content) else null end)
    } else null end),
    prompt: (lastof(.type == "last-prompt") | .lastPrompt // null | if . then oneline else . end),
    cost: $cost,
    turnMs: $turn.durationMs,
    agents: ($turn.pendingBackgroundAgentCount // 0),
    # Claude's last words, for the card's preview; capped, the panel says when it was cut.
    reply: ($reply | if . then .[0:2500] else null end),
    replyCut: (($reply // "") | length > 2500),
    # The questions of a pending AskUserQuestion, if that was the last tool call.
    question: (if $tool and $tool.name == "AskUserQuestion" then
      [$tool.input.questions[]? | { question, options: [.options[]?.label] }] else null end)
  }
