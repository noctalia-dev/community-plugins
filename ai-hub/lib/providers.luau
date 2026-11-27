--[[
  providers.luau - provider presets and URL/model normalisation.

  Pure module: it never touches `noctalia.*`, so the standalone `luau` CLI can
  unit-test it (`tests/unit.luau` in the development repo).

  Four rules shape this file, each one a bug this plugin was written to avoid:

    * an `Authorization` header is only ever sent when a key is present;
    * no provider-specific default model is hardcoded anywhere;
    * every base URL is normalised before a path is appended, so a trailing
      slash, a pasted `.../chat/completions`, or a pasted `.../models` all work;
    * provider quirks live in the preset table, never in the request code.
]]

local M = {}

-- local helper, duplicated on purpose: keeping every pure module free of
-- intra-library requires lets each one be tested on its own with the CLI.
local function trim(s: string): string
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

M.trim = trim

--[[
  A preset describes one provider. Fields:

    id                  stable key, also the settings `provider` value
    label               human name
    base                default OpenAI-compatible base URL (`.../v1`-style)
    auth                send `Authorization: Bearer <key>` when a key exists
    key_required        a key is needed for the provider to answer at all
    strip_model_prefix  prefix to drop from listed ids before display/sending
    send_session        send `x-opencode-session`
    user_agent          custom User-Agent (some gateways ask the client to
                        identify itself instead of sending an SDK default)
    local_only          endpoint normally points at the local machine
    notes               shown in the panel/preset hints
]]
M.presets = {
  {
    id = "omniroute",
    label = "OmniRoute (local gateway)",
    base = "http://localhost:20128/v1",
    auth = false,
    key_required = false,
    local_only = true,
    notes = "Agregador local sin clave. Expone cientos de modelos, "
      .. "incluidos los gratuitos `auto/*:free` y `cline/*:free`.",
  },
  {
    id = "cheaperinference",
    label = "CheaperInference",
    base = "https://api.cheaperinference.com/v1",
    auth = true,
    key_required = true,
    notes = "Requiere clave. Lista y chat van firmados con Bearer.",
  },
  {
    id = "gemini",
    label = "Google Gemini (compatibilidad OpenAI)",
    base = "https://generativelanguage.googleapis.com/v1beta/openai",
    auth = true,
    key_required = true,
    strip_model_prefix = "models/",
    notes = "Los ids de /models llegan con el prefijo `models/`; se quita para "
      .. "mostrarlo y se envia sin prefijo (acepta ambas formas).",
  },
  {
    id = "groq",
    label = "Groq",
    base = "https://api.groq.com/openai/v1",
    auth = true,
    key_required = true,
    notes = "Inferencia rápida en modelos abiertos (Llama, Mixtral, Gemma). Requiere clave.",
  },
  {
    id = "openrouter",
    label = "OpenRouter",
    base = "https://openrouter.ai/api/v1",
    auth = true,
    key_required = true,
    key_info_path = "/key",
    credits_path = "/credits",
    notes = "Requiere una clave de inferencia. Una clave de gestion/provisioning "
      .. "autentica en /key pero el chat responde 401.",
  },
  {
    id = "ollama",
    label = "Ollama / LM Studio (local)",
    base = "http://localhost:11434/v1",
    auth = false,
    key_required = false,
    local_only = true,
    notes = "Servidor local sin clave. LM Studio usa el puerto 1234 por defecto.",
  },
  {
    id = "zen",
    label = "OpenCode Zen / Go",
    base = "https://opencode.ai/inference/go/openai/v1",
    auth = true,
    key_required = true,
    send_session = true,
    user_agent = "ai-hub/0.1 (noctalia-plugin)",
    notes = "El plan Go es de pago: los modelos `*free` son gratuitos dentro "
      .. "del plan, no sin credencial.",
  },
  {
    id = "custom",
    label = "Personalizado (compatible con OpenAI)",
    base = "",
    auth = true,
    key_required = false,
    notes = "Cualquier endpoint que hable /chat/completions. Indica la URL base "
      .. "en 'Endpoint'.",
  },
}

M.order = { "omniroute", "cheaperinference", "gemini", "groq", "openrouter", "ollama", "zen", "custom" }

local by_id = {}
for _, preset in ipairs(M.presets) do
  by_id[preset.id] = preset
end

M.by_id = by_id

function M.get(id: string?)
  return by_id[id or ""] or by_id.custom
end

--[[
  Normalise a base URL typed by a human:

    "https://api.example.com/v1/"                  -> "https://api.example.com/v1"
    "https://api.example.com/v1/chat/completions"  -> "https://api.example.com/v1"
    "https://generativelanguage.googleapis.com/v1beta/openai/models"
                                                   -> ".../v1beta/openai"
]]
function M.normalize_endpoint(base: string?): string
  local s = trim(base or "")
  if s == "" then
    return ""
  end
  s = s:gsub("/+$", "")
  s = s:gsub("/chat/completions$", "")
  s = s:gsub("/completions$", "")
  s = s:gsub("/models$", "")
  s = s:gsub("/+$", "")
  return s
end

function M.chat_url(base: string): string
  return M.normalize_endpoint(base) .. "/chat/completions"
end

function M.models_url(base: string): string
  return M.normalize_endpoint(base) .. "/models"
end

--[[
  Resolve a provider id plus an optional endpoint override into the plain table
  the request code consumes. The override always wins, so any preset can be
  repointed (a proxy, another port, a mirrored gateway) without editing code.
]]
function M.resolve(id: string?, endpoint_override: string?)
  local preset = M.get(id)
  local override = trim(endpoint_override or "")
  local base = M.normalize_endpoint(override)
  if base == "" then
    base = M.normalize_endpoint(preset.base)
  end
  return {
    id = preset.id,
    label = preset.label,
    base = base,
    auth = preset.auth == true,
    key_required = preset.key_required == true,
    strip_model_prefix = preset.strip_model_prefix or "",
    send_session = preset.send_session == true,
    user_agent = preset.user_agent,
    key_info_path = preset.key_info_path,
    credits_path = preset.credits_path,
    local_only = preset.local_only == true,
    notes = preset.notes,
    overridden = override ~= "",
  }
end

--[[
  Some providers list ids with a prefix that the chat endpoint accepts but that
  only adds noise in a picker (Gemini's `models/`). `display_model` is what the
  user sees and stores; `request_model` is what goes on the wire.
]]
function M.strip_model_prefix(model: string?, prefix: string?): string
  local id = trim(model or "")
  local p = prefix or ""
  if p ~= "" and id:sub(1, #p) == p then
    return id:sub(#p + 1)
  end
  return id
end

function M.display_model(model: string?, prefix: string?): string
  return M.strip_model_prefix(model, prefix)
end

function M.request_model(model: string?, prefix: string?): string
  return M.strip_model_prefix(model, prefix)
end

-- Group free-of-charge ids so a picker can surface them first. `:free` is the
-- OpenRouter/OmniRoute convention; `-free` and `/free` show up too.
function M.looks_free(model: string?): boolean
  local id = model or ""
  if id:find(":free", 1, true) ~= nil or id:find("-free", 1, true) ~= nil
    or id:find("/free", 1, true) ~= nil then
    return true
  end
  local lowered = id:lower()
  if lowered == id then
    return false
  end
  return lowered:find(":free", 1, true) ~= nil
    or lowered:find("-free", 1, true) ~= nil
    or lowered:find("/free", 1, true) ~= nil
end

return M
