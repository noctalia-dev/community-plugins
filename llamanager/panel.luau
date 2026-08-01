local modelfilePath = ""
local pathSet

local stageIcon = "topology-star-3"

-- models and runtime view
function onRefreshButtonClick()
    noctalia.state.set("llamanager.nextCommand", "refresh")
end

function onLaunchButtonClick()
    noctalia.state.set("llamanager.nextCommand", "launch")
end

function onRuntimeButtonClick()
    noctalia.state.set("llamanager.nextCommand", "runtime") 
end

function onBackButtonClick()
    noctalia.state.set("llamanager.nextCommand", "refresh")
    noctalia.state.set("llamanager.view", "modelsView") 
end

function onEditorButtonClick()
    if not pathSet then
        noctalia.notify("Llamanager", "Please configure a valid Modelfile directory first.")
        return
    end

    noctalia.state.set("llamanager.nextCommand", "editor")
end

function onDownloadButtonClick()
    noctalia.state.set("llamanager.nextCommand", "download")
end

function changeSelectedIndexModel(index)
    noctalia.state.set("llamanager.selectedModel", index)
end

function changeDownloadModelField(downloadRequest)
    noctalia.state.set("llamanager.downloadModelField", {modelName=downloadRequest, data=nil, result=nil})
end

-- editor view
function onLoadOllamaButtonClick()
    noctalia.state.set("llamanager.nextCommand", "loadToOllama")
end

function onCreateButtonClick()
    noctalia.state.set("llamanager.nextCommand", "create")
end

function onEditButtonClick()
    noctalia.state.set("llamanager.nextCommand", "edit")
end

function onDeleteButtonClick()
    noctalia.state.set("llamanager.nextCommand", "delete")
end

function changeModelfileName(fileName)
    noctalia.state.set("llamanager.modelfileNameField", fileName)
end

function changeModelfileContent(content)
    noctalia.state.set("llamanager.modelfileContent", content)
    local path = modelfilePath .. noctalia.state.get("llamanager.modelfileNameField") .. ".modelfile"
    noctalia.writeFile(path, content)
end

local function renderModelsView(models)
    local modelRows = {}
    
    local function getModelOptions()
        local options = {"Default (Ollama)"}
     
        for _, model in ipairs(models) do
            table.insert(options, model.name)
        end

        return options
    end
    
    local function populateModelRows(models, modelRows)
        if #models ~= 0 then
            for _, model in ipairs(models) do
                table.insert(modelRows,
                    ui.row({ justify = "space_between" }, {
                        ui.label({
                            text = "└── " .. model.name,
                        }),
                    })
                )
            end
        else
            table.insert(modelRows,
                ui.label({text = "No models installed... :("})
            )
        end
    end

    populateModelRows(models, modelRows)

    panel.render(
        ui.column({ flexGrow = 1 }, {
            -- header
            ui.row({ justify = "space_between" }, {
                ui.row({ gap = 8, align = "center" }, {
                    ui.glyph({ name = stageIcon, color = "primary"}),
                    ui.label({ text = "Llamanager", fontSize = 18, fontWeight = "bold", color = "on_surface",}),
                }),
                ui.row({ gap = 8, align = "center" }, {
                    ui.button({ glyph = "activity", onClick = "onRuntimeButtonClick", tooltip = "Runtime Dashboard",}),
                    ui.button({ glyph = "refresh", onClick = "onRefreshButtonClick" }),
                }),
            }),
    
            ui.scroll({ flexGrow = 1 }, {
                ui.label({ text = "Model List", fontWeight = "bold", color = "primary" }),
                ui.spacer({ height = 8 }),
                ui.column({ gap = 6 }, modelRows),
                ui.spacer({ height = 8 }),
                
                ui.label({ text = "Modelfile Editor", fontWeight = "bold", color = "primary",}),
                ui.spacer({ height = 8 }),
                ui.button({ text = "Open Editor", onClick = "onEditorButtonClick" }),
                ui.spacer({ height = 8 }),
                ui.label({ text = "Model Downloader ", color = "primary", fontWeight = "bold"}),
                ui.spacer({ height = 8 }),

                ui.row({ gap=8 }, {
                    ui.input({ flexGrow = 1, placeholder="llama3.1:8b, deepseek-r1:8b, ...", onChange="changeDownloadModelField"}),
                    ui.button({ glyph="download", onClick = "onDownloadButtonClick" }),
                }),
            }),

            -- footer
            ui.column({ gap = 8 }, {
                ui.row({ gap = 8, justify = "end"}, {
                    ui.select({ placeholder = "Model", flexGrow=1, options = getModelOptions(), onChange = "changeSelectedIndexModel" }),
                    ui.button({ glyph = "rocket", onClick = "onLaunchButtonClick" }),
                }),
            }),
        })
    )
end

local function renderRuntimeView(ollama)
    local ollamaRows = {}
    local runtimeRows = {}

    local function populateRuntimeRows(runtime, runtimeRows)
        for i, model in ipairs(runtime) do
            if next(model) ~= nil then
                local date, time = "-", "-"
                if model.expires then
                    date, time = model.expires:match("(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d:%d%d)")
                end

                table.insert(runtimeRows,
                    ui.column({gap = 6 }, {
                        ui.label({ text = "[" .. i .. "] " .. model.name , color = "primary" }),
                        ui.label({ text = "Parameters\t" .. (model.parameterSize or "-") }),
                        ui.label({ text = "Quantization\t" .. (model.quantization or "-") }),
                        ui.label({ text = "Context\t\t" .. tostring(model.context or "-") }),
                        ui.label({ text = "Expires\t\t" .. date .. " | ".. time}),
                    })
                )
            end
        end
        
        if next(runtimeRows) == nil then
            table.insert(runtimeRows,
                ui.column({}, {
                    ui.label({text = "No models are currently running :)"})
                }))
        end
    end

    local function populateOllamaRows(server, ollamaRows)
        table.insert(ollamaRows,
            ui.column({ gap = 6 }, {
                ui.label({ text = "Installed:\t" .. tostring(server.installed)}),
                ui.label({ text = "Version:\t" .. tostring(server.version)}),
                ui.label({ text = "Executable:\t" .. server.executable}),
                ui.label({ text = "Endpoint:\t" .. server.endpoint}),
                ui.label({ text = "API Connected:\t" .. tostring(server.api_connected)}),
            })
        )    
    end

    populateRuntimeRows(ollama.runtime, runtimeRows)
    populateOllamaRows(ollama.server, ollamaRows)

    -- runtime dashboard
    panel.render(
        ui.column({flexGrow=1, justify="space_between"}, {
            -- header
            ui.row({ justify = "space_between" }, {
                ui.row({ gap = 8, align = "center" }, {
                    ui.glyph({ name = stageIcon, color = "primary"}),
                    ui.label({ text = "Llamanager", fontSize = 18, fontWeight = "bold", color = "on_surface" }),
                }),
                ui.row({ gap = 8, align = "center" }, {
                    ui.button({ glyph = "arrow-left", onClick = "onBackButtonClick" }),
                    ui.button({ glyph = "refresh", onClick = "onRefreshButtonClick" }),
                }),
            }),

            ui.scroll({ flexGrow = 1}, {
                ui.label({ text = "Runtime Dashboard", fontWeight = "bold", color = "primary" }),
                ui.spacer({ height = 8 }),

                ui.label({ text = "Ollama", color = "primary" }),
                ui.column({ gap = 6 }, ollamaRows),
                
                ui.separator({spacing = 8,}),

                ui.label({ text = "Active Models", color = "primary" }),
                ui.label({text = "Installed: " .. #ollama.models,}),
                ui.spacer({height = 8,}),

                ui.column({ gap = 6 }, runtimeRows),
            }),
        })
    )
end

local function renderEditorView()
    local modelDirRows = {}
    local function populateModelDirRows(modelDirRows)
        local dirs = noctalia.state.get("llamanager.modelfilePaths")
        for i, dir in ipairs(dirs) do
            table.insert(modelDirRows,
                ui.row({ justify = "space_between" }, {
                    ui.label({
                        text = "└── " .. dir,
                    }),
                })
            )
        end
    end

    populateModelDirRows(modelDirRows)

    panel.render(
        ui.column({flexGrow=1, justify="space_between"}, {
            -- header
            ui.row({ justify = "space_between" }, {
                ui.row({ gap = 8, align = "center" }, {
                    ui.glyph({ name = stageIcon, color = "primary"}),
                    ui.label({ text = "Llamanager", fontSize = 18, fontWeight = "bold", color = "on_surface", }),
                }),
                ui.row({ gap = 8, align = "center" }, {
                    ui.button({ glyph = "arrow-left", onClick = "onBackButtonClick" }),
                    ui.button({ glyph = "refresh", onClick = "onRefreshButtonClick" }),
                }),
            }),

            -- body
            ui.scroll({ flexGrow = 1 }, {
                ui.label({ text = "Modelfiles", fontWeight = "bold", color = "primary",}),
                ui.label({text = "Modelfile Path: " .. modelfilePath,}),
                ui.spacer({height = 8,}),
                ui.column({}, modelDirRows)
            }),

            -- foot
            ui.row({ gap = 8 }, {
                ui.button({ glyph = "file-code", onClick = "onLoadOllamaButtonClick", tooltip="Load to Ollama" }),
                ui.input({ flexGrow = 1, placeholder = "Modelfile Name", onChange = "changeModelfileName" }),
                ui.button({ glyph = "plus", onClick = "onCreateButtonClick", tooltip="Create" }),
                ui.button({ glyph = "edit", onClick = "onEditButtonClick", tooltip="Edit" }),
                ui.button({ glyph = "trash", onClick = "onDeleteButtonClick", tooltip="Delete"}),
            }),
        })
    )
end

local function renderModelfileEditorView()
    local path = modelfilePath .. noctalia.state.get("llamanager.modelfileNameField") .. ".modelfile"
    content = noctalia.readFile(path)

    panel.render(
        ui.column({}, {
            -- header
            ui.row({ justify = "space_between" }, {
                ui.row({ gap = 8, align = "center" }, {
                    ui.glyph({ name = stageIcon, color = "primary"}),
                    ui.label({ text = "Llamanager", fontSize = 18, fontWeight = "bold", color = "on_surface" }),
                }),
                ui.row({ gap = 8, align = "center" }, {
                    ui.button({ glyph = "arrow-left", onClick = "onBackButtonClick" }),
                    ui.button({ glyph = "refresh", onClick = "onRefreshButtonClick" }),
                }),
            }),
            ui.label({ text = "Editing " .. path }),
            ui.spacer({ height = 2, flexGrow = 0}),
            -- body
            ui.input({ value = content, flexGrow = 1, placeholder = "Modelfile", onChange = "changeModelfileContent", multiline = true}),
        })
    )
end

-- main

function onOpen(_context)
    modelfilePath = noctalia.expandPath(noctalia.getConfig("modelfile_path"))
    
    if not modelfilePath or modelfilePath == "" or not noctalia.fileExists(modelfilePath) then
        pathSet = false
    else
        if modelfilePath:sub(-1) ~= "/" then
            modelfilePath = modelfilePath .. "/"
        end
        pathSet = true
    end
    
    -- trigger initial load
    noctalia.state.set("llamanager.view", "modelsView")
    noctalia.state.set("llamanager.nextCommand", "refresh")
end

local function render()
    local ollama = noctalia.state.get("llamanager.ollama") or {}
    local view = noctalia.state.get("llamanager.view")

    if view == "modelsView" then
        renderModelsView(ollama.models or {})
    elseif view == "runtimeView" then
        renderRuntimeView(ollama or {})
    elseif view == "editorView" and pathSet then
        renderEditorView()
    elseif view == "modelfileEditorView" then
        renderModelfileEditorView()
    end
end

-- UI updates
noctalia.state.watch("llamanager.view", render)
noctalia.state.watch("llamanager.ollama", render)