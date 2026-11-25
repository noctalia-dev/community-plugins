--[[
  tools.luau - the optional tool layer: definitions sent to the model, the
  approval policy, and execution.

  Tools are off by default (`tool_permission = "off"`), and even when they are
  on, `run_command` only runs after an explicit per-call approval unless the
  user opted into `allow`. Nothing here trusts the model: the blocklist is
  re-checked at execution time, not only when the request was raised, and the
  command runs through `/bin/sh -c` with the command as a single argv element,
  so the plugin never builds a shell string of its own.
]]

local text = require("./text.luau")

local M = {}

local COMMAND_OUTPUT_LIMIT = 8000
local FETCH_LIMIT = 12000
local SEARCH_RESULTS = 6
local SEARCH_LIMIT = 6000

-- Destructive shapes a user almost never means to authorise. Editable from the
-- plugin settings; this is the seed value, not a policy.
M.DEFAULT_BLOCKLIST = {
  "rm -rf /",
  "rm -rf /*",
  "mkfs",
  "dd if=/dev/zero",
  "dd if=/dev/random",
  "> /dev/sda",
  "chmod -R 777 /",
  "chown -R /",
  "shutdown",
  "reboot",
  "poweroff",
  "init 0",
  "systemctl poweroff",
  ":(){:|:&};:",
  "curl | sh",
  "curl | bash",
  "wget | sh",
  "wget | bash",
}

local function trim(s)
  if type(s) ~= "string" then
    return ""
  end
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

function M.definitions(opts)
  local list = {
    {
      type = "function",
      ["function"] = {
        name = "run_command",
        description = "Run a shell command on the user's machine and return its stdout, stderr and exit code. "
          .. "The user must approve every call before it runs, so use it only when the answer needs real "
          .. "state from this machine.",
        parameters = {
          type = "object",
          properties = {
            command = {
              type = "string",
              description = "The complete shell command, exactly as it should run.",
            },
          },
          required = { "command" },
        },
      },
    },
    {
      type = "function",
      ["function"] = {
        name = "web_fetch",
        description = "Download a URL and return its readable text. Use it when the user gives a link or when a "
          .. "search result needs to be read before answering.",
        parameters = {
          type = "object",
          properties = {
            url = { type = "string", description = "An absolute http or https URL." },
          },
          required = { "url" },
        },
      },
    },
  }

  if opts ~= nil and opts.web_search then
    table.insert(list, {
      type = "function",
      ["function"] = {
        name = "web_search",
        description = "Search the web and return the top results as titles, URLs and snippets. Use it when the "
          .. "answer depends on current information, then fetch a result with web_fetch if needed.",
        parameters = {
          type = "object",
          properties = {
            query = { type = "string", description = "The search query." },
          },
          required = { "query" },
        },
      },
    })
  end

  return list
end

function M.is_command_tool(name: string): boolean
  return name == "run_command"
end

-- First matching blocklist entry, or nil. Case-insensitive substring match:
-- patterns stay readable in the settings window.
function M.blocked(command: string?, patterns): string?
  local haystack = (command or ""):lower()
  if type(patterns) ~= "table" then
    return nil
  end
  for _, pattern in ipairs(patterns) do
    if type(pattern) == "string" and pattern ~= "" and haystack:find(pattern:lower(), 1, true) then
      return pattern
    end
  end
  return nil
end

--[[
  Model-produced arguments are a JSON string in the OpenAI format. Some models
  emit an empty string for a no-argument call, and a few emit an object
  directly; both are handled.
]]
function M.parse_arguments(raw)
  if type(raw) == "table" then
    return raw
  end
  local source = trim(raw)
  if source == "" then
    return {}
  end
  local decoded, error_message = noctalia.json.decode(source)
  if type(decoded) ~= "table" then
    return nil, "Argumentos no son JSON válido: " .. tostring(error_message)
  end
  return decoded
end

function M.argv(command: string?)
  return { "/bin/sh", "-c", command or "" }
end

function M.summary(name: string?, arguments)
  local args = type(arguments) == "table" and arguments or {}
  if name == "run_command" then
    return noctalia.tr("tool.run_command"), tostring(args.command or "")
  end
  if name == "web_fetch" then
    return noctalia.tr("tool.web_fetch"), tostring(args.url or "")
  end
  if name == "web_search" then
    return noctalia.tr("tool.web_search"), tostring(args.query or "")
  end
  return noctalia.tr("tool.unknown"), tostring(name or "?")
end

local function looks_like_http_url(url: string): boolean
  local lowered = url:lower()
  return lowered:sub(1, 7) == "http://" or lowered:sub(1, 8) == "https://"
end

local function command_result(result)
  local chunks = {}
  if type(result.stdout) == "string" and result.stdout ~= "" then
    table.insert(chunks, result.stdout)
  end
  if type(result.stderr) == "string" and result.stderr ~= "" then
    table.insert(chunks, "[stderr]\n" .. result.stderr)
  end
  local body = table.concat(chunks, "\n")
  if trim(body) == "" then
    body = "(sin salida)"
  end
  local clipped = text.truncate(body, COMMAND_OUTPUT_LIMIT)
  local header = string.format("exit=%s%s",
    tostring(result.exitCode or -1),
    result.timedOut and " (timeout)" or "")
  return true, header .. "\n" .. clipped
end

function M.run_command(command: string?, blocklist, done)
  local target = trim(command)
  if target == "" then
    done({ ok = false, text = "El modelo envió un comando vacío." })
    return
  end
  -- checked again here, because by now the command has been through the
  -- approval round trip and could have been edited in between
  local pattern = M.blocked(target, blocklist)
  if pattern ~= nil then
    done({ ok = false, text = string.format("Bloqueado por la lista de patrones: %q", pattern) })
    return
  end
  local accepted = noctalia.runAsync(M.argv(target), function(result)
    local ok, body = command_result(result or {})
    done({ ok = ok, text = body })
  end)
  if accepted ~= true then
    done({ ok = false, text = "No se pudo iniciar el proceso." })
  end
end

function M.web_fetch(url: string?, done)
  local target = trim(url)
  if not looks_like_http_url(target) then
    done({ ok = false, text = "Solo se admiten URLs http:// o https://." })
    return
  end
  local accepted = noctalia.http({
    url = target,
    method = "GET",
    headers = {
      "Accept: text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5",
      "User-Agent: ai-hub/0.1 (noctalia-plugin)",
    },
    follow_redirects = true,
  }, function(response)
    if response == nil or response.ok ~= true then
      local status = response ~= nil and response.status or 0
      done({ ok = false, text = "La descarga falló (HTTP " .. tostring(status) .. ")." })
      return
    end
    local body = response.body or ""
    local readable = text.looks_like_html(body) and text.html_to_text(body) or body
    local clipped = text.truncate(readable, FETCH_LIMIT)
    if trim(clipped) == "" then
      done({ ok = false, text = "La página no tiene texto legible." })
      return
    end
    done({ ok = true, text = "Contenido de " .. target .. ":\n\n" .. clipped })
  end)
  if accepted ~= true then
    done({ ok = false, text = "No se pudo iniciar la petición." })
  end
end

function M.web_search(query: string?, done)
  local target = trim(query)
  if target == "" then
    done({ ok = false, text = "Consulta vacía." })
    return
  end
  local accepted = noctalia.http({
    url = text.search_url(target),
    method = "GET",
    headers = {
      "Accept: text/html",
      "User-Agent: ai-hub/0.1 (noctalia-plugin)",
    },
    follow_redirects = true,
  }, function(response)
    if response == nil or response.ok ~= true then
      local status = response ~= nil and response.status or 0
      done({ ok = false, text = "La búsqueda falló (HTTP " .. tostring(status) .. ")." })
      return
    end
    local results = text.parse_search_results(response.body, SEARCH_RESULTS)
    if #results == 0 then
      done({ ok = false, text = "Sin resultados legibles para \"" .. target .. "\"." })
      return
    end
    done({ ok = true, text = text.format_search_results(results, target, SEARCH_LIMIT) })
  end)
  if accepted ~= true then
    done({ ok = false, text = "No se pudo iniciar la búsqueda." })
  end
end

--[[
  Run one tool call. `done` receives `{ ok = boolean, text = string }`, and is
  called exactly once.
]]
function M.execute(name: string?, arguments, options, done)
  local opts = options or {}
  if name == "run_command" then
    M.run_command(arguments ~= nil and arguments.command or nil, opts.blocklist, done)
  elseif name == "web_fetch" then
    M.web_fetch(arguments ~= nil and arguments.url or nil, done)
  elseif name == "web_search" then
    M.web_search(arguments ~= nil and arguments.query or nil, done)
  else
    done({ ok = false, text = "Herramienta desconocida: " .. tostring(name) })
  end
end

return M
