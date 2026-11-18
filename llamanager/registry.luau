local modelfilePath = noctalia.expandPath(noctalia.getConfig("modelfile_path"))
if modelfilePath:sub(-1) ~= "/" then
    modelfilePath = modelfilePath .. "/"
end

local function joinModelNameToPath(modelName)
    return modelfilePath .. modelName .. ".modelfile"
end

local function isNotEmpty(value)
    if not value or value:match("^%s*$") then
        noctalia.notify("LLamanager", "Field cannot be empty.")
        return false
    end
        
    return true
end

local function shellEscape(str)
    return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
end

-- return ollama table
local function loadOllama()
    local isInstalled = function() return noctalia.commandExists("ollama") end

    local ollama = {
        server = {
            executable = "ollama",
            installed = isInstalled(),
            endpoint = "localhost:11434",
            api_connected = false,
            version = nil,
        },
        models = {}, -- models installed
        runtime = {}, -- runtime models and other info 
    }

    return ollama
end

-- models dashboard
local function getModels(onDone)
    local models = {}

    noctalia.runAsync("ollama list | awk 'NR>1 {print $1}'", function(result)
        if result.exitCode ~= 0 then
            onDone({})
            return
        end

        for line in string.gmatch(result.stdout, "[^\r\n]+") do
            local model_name = line:gsub("%s+$", "")

            if model_name ~= "" then
                table.insert(models, 
                {
                    name = model_name,
                    executable = "ollama run " .. model_name .. " --think=false",
                })
            end
        end
        onDone(models)
    end)
end

-- runtime dashboard
local function getOllamaVersion(onVersion)
    noctalia.runAsync("ollama --version | awk '{print $4}'", function(result)
        if result.exitCode ~= 0 then
            noctalia.notify("Failed to get Ollama version")
            return
        end
        local version = result.stdout
        onVersion(version)
    end)
end

local function launch(ollama)
    local selectedModel = tonumber(noctalia.state.get("llamanager.selectedModel"))
    local models = ollama.models
    
    if selectedModel ~= 0 then    
        local model = models[selectedModel]

        if not model then
            noctalia.notify("Selected model not found")
            return
        end

        noctalia.notify(model.name)
        noctalia.runInTerminal(model.executable)
    else
        noctalia.notify("Ollama")
        noctalia.runInTerminal(ollama.server.executable)
    end
end

local function getRuntimeInfo(onLoad)
    local request = {
        url = "http://localhost:11434/api/ps",
        method = "GET",
        headers = { "Accept: application/json" },
        follow_redirects = false,
    }
    
    noctalia.http(request, function(response)
        if not (response.ok and response.status == 200) then
            noctalia.notify("Request failed")
            return
        end
        local api_status = true

        -- parse
        local data = noctalia.json.decode(response.body)

        if not data.models or #data.models == 0 then
            onLoad({}, api_status)
            return
        end

        -- update models
        local info = {}
        for _, model in ipairs(data.models) do
            table.insert(info, {
                name = model.name,
                parameterSize = model.details.parameter_size,
                quantization = model.details.quantization_level,
                context = model.context_length,
                expires = model.expires_at,
            })
        end

        onLoad(info, api_status)
    end)
end

local function downloadModel(modelName, onProgress, onFinish)
    local request = {
        url = "http://localhost:11434/api/pull",
        method = "POST",
        headers = {
            "Content-Type: application/json",
            "Accept: application/json",
        },
        body = noctalia.json.encode({
            model = modelName,
            stream = true,
        }),
    }

    noctalia.httpStream( request,
        -- progress
        function(line)
            local ok, data = pcall(noctalia.json.decode, line)
            if not ok then
                return
            end

            if onProgress then
                onProgress(data)
            end
        end,

        -- finished
        function(result)
            if onFinish then
                onFinish(result)
            end
        end
    )
end

local function edit()
    local listDir, err = noctalia.listDir(modelfilePath)

    if not listDir then
        noctalia.notify("Llamanager", err)
        return
    end

    modelfileDirs = {}
    for _, dir in ipairs(listDir) do
        table.insert(modelfileDirs, dir)
    end
    noctalia.state.set("llamanager.modelfilePaths", modelfileDirs)
end

local function loadToOllama(modelName, modelfilePath)
    local cmd = string.format(
    'ollama create %s -f %s',
        shellEscape(modelName),
        shellEscape(modelfilePath)
    )

    noctalia.runAsync(cmd, function(result)
        if result.exitCode == 0 then
            noctalia.notify("Model created!")
        else
            local err = result.stderr ~= "" and result.stderr or result.stdout
            local message = err:match("Error:.-[\r\n]") or err:match("Error:.*") or err
            message = message:gsub("[\r\n]", "")
            noctalia.notify("Llamanager", message)
        end
    end)
end

local function deleteModelOllama(modelName)
    local cmd = string.format('ollama rm %s', shellEscape(modelName))

    noctalia.runAsync(cmd, function(result)
        if result.exitCode == 0 then
            noctalia.notify("Ollama: Removed ".. modelName)
            -- refresh model list
            noctalia.state.set("llamanager.nextCommand", "refresh")
        else
            noctalia.notify("LLamanager", "Modelfile successfully deleted, but no matching ollama model was found.")
            noctalia.state.set("llamanager.nextCommand", "refresh")
        end
    end)
end

noctalia.state.watch("llamanager.nextCommand", function(command)
    if command == "refresh" then -- load ollama and its models
        local ollama = loadOllama()
        getModels(function(models)
            ollama.models = models
            noctalia.state.set("llamanager.ollama", ollama)
            noctalia.state.set("llamanager.view", "modelsView")
        end)
    
    -- reset field value
    noctalia.state.set("llamanager.modelfileNameField", "")

    elseif command == "launch" then
        local ollama = noctalia.state.get("llamanager.ollama")
        launch(ollama)
        
    elseif command == "runtime" then
        local ollama = loadOllama()

        getModels(function(models)
            ollama.models = models
            getRuntimeInfo(function(runtime, status) 
                ollama.runtime = runtime
                ollama.server.api_connected = status
                getOllamaVersion(function(version)
                    ollama.server.version = version
                    noctalia.state.set(
                        "llamanager.ollama",
                        ollama
                    )
                    noctalia.state.set(
                        "llamanager.view",
                        "runtimeView"
                    )
                end)
            end)
        end)

    elseif command == "download" then
        local downloadData = noctalia.state.get("llamanager.downloadModelField")
        noctalia.notify("Download Started...")
        local lastNotified = -30
        local hadError = false

        downloadModel(
            downloadData.modelName,

            function(progress)
                if progress.error then
                    hadError = true
                    noctalia.notify(progress.error)
                    return
                end

                if progress.completed and progress.total then
                    local percent = math.floor(progress.completed / progress.total * 100)
                    local milestone = math.floor(percent / 30) * 30

                    if milestone >= 30 and milestone > lastNotified then
                        lastNotified = milestone
                        noctalia.notify("Download Progress: " .. tostring(milestone) .. "%")
                    end
                end
            end,

            function(result)
                if hadError then
                    return
                end

                if result.ok then
                    noctalia.notify("Download complete!")
                    noctalia.state.set("llamanager.nextCommand", "refresh")
                else
                    noctalia.notify(
                        "Download failed (" ..
                        tostring(result.status) ..
                        ")"
                    )
                end
            end
        )

    -- editor
    elseif command == "editor" then
        edit()
        noctalia.state.set("llamanager.view", "editorView")

    elseif command == "create" then
        local modelName = noctalia.state.get("llamanager.modelfileNameField")
        if isNotEmpty(modelName) then
            local path = joinModelNameToPath(modelName)
            noctalia.writeFile(path, "")
            noctalia.state.set("llamanager.view", "modelfileEditorView")
        end

    elseif command == "edit" then
        local modelName = noctalia.state.get("llamanager.modelfileNameField")
        if isNotEmpty(modelName) then
            local path = joinModelNameToPath(modelName)
            local content = noctalia.readFile(path)
            noctalia.state.set("llamanager.modelfileContent", content)
            noctalia.state.set("llamanager.view", "modelfileEditorView")
        end

    elseif command == "delete" then
        -- note: Include the model tag (e.g. :latest, :v2) on deleting a model.
        local modelName = noctalia.state.get("llamanager.modelfileNameField")
        
        if isNotEmpty(modelName) then
            local base = modelName:gsub(":.*$", "")
            local path = modelfilePath .. base .. ".modelfile"
            local ok, err = noctalia.removeFile(path)
            if not ok then
                noctalia.notify("LLamanager", tostring(err))
            else
                -- delete in ollama
                deleteModelOllama(modelName)
            end
        end

    elseif command == "loadToOllama" then
        local modelName = noctalia.state.get("llamanager.modelfileNameField")
        if isNotEmpty(modelName) then
            local path = joinModelNameToPath(modelName)
            loadToOllama(modelName, path)
        end 
    end

end)
