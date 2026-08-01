function onQuery(text)
    if text == "" then
        launcher.setResults(text, {
            {
                id = "hint",
                title = "Ask Ollama anything",
                subtitle = "Finish with // to send",
                glyph = "brain",
            }
        })
        return
    end

    if not text:match("%s//%s*$") then
        launcher.setResults(text, {
            {
                id = "waiting",
                title = text,
                subtitle = "Append // to send",
                glyph = "keyboard",
            }
        })
        return
    end

    local prompt = text:gsub("%s//%s*$", "")

    launcher.setResults(text, {
        {
            id = "loading",
            title = "Thinking...",
            subtitle = prompt,
            glyph = "loader",
        }
    })

    local request = {
        url = "http://localhost:11434/api/generate",
        method = "POST",
        headers = {
            "Content-Type: application/json",
        },
        body = noctalia.json.encode({
            model = noctalia.getConfig("launcher"),
            prompt = prompt,
            stream = false,
            think = false,
        }),
    }

    noctalia.http(request, function(response)
        if not (response.ok and response.status == 200) then
            launcher.setResults(text, {
                {
                    id = "error",
                    title = "Ollama request failed",
                    subtitle = response.body or ("HTTP " .. tostring(response.status)),
                    glyph = "alert-circle",
                }
            })
            return
        end

        local data = noctalia.json.decode(response.body)
        noctalia.notify("LLamanager", data.response)
        launcher.setResults(text, {
            {
                id = data.response,
                title = data.response,
                subtitle = "Press Enter to copy",
                glyph = "brain",
            }
        })
    end)
end

function onActivate(id)
    noctalia.copyToClipboard(id, "text/plain")
end