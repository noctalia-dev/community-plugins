local currentPageIndex = 0

local function uuid()
	local array = {}
	for i = 1, 32 do
		array[i] = string.format("%x", math.random(0, 15))
	end

	array[13] = "4"
    array[17] = string.format("%x", math.random(8, 11))

    local hex = table.concat(array)

    return hex:sub(1,8) .. "-" .. hex:sub(9,12) .. "-" .. hex:sub(13,16) .. "-" .. hex:sub(17,20) .. "-" .. hex:sub(21,32)
end

local pokemonData = {}
local registeredPokemons = 0

local function loadPokemonData()
    local fileContent = noctalia.readFile("./data/pokemon.json")

    if fileContent == nil then
        noctalia.notifyError("Failed to load pokémon data file.")
        
        return
    end

    local fileData = noctalia.json.decode(fileContent)

    if fileData == nil then
        noctalia.notifyError("Invalid pokémon data file.")

        return
    end

    for _, pokemon in ipairs(fileData) do
        pokemonData[pokemon.id] = pokemon.name
    end

    registeredPokemons = fileData[#fileData].id
    print(registeredPokemons)
end

loadPokemonData()

local randomPokemonId = 0

local playerAnswer = ""
local isPlayerAnswerCorrect = nil

function onPlayBtnClicked()
    currentPageIndex = 1

    render()
end

function onCloseBtnClicked()
    panel.close()
end

function renderMenu()
    panel.render(
        ui.column({ flexGrow = 1, gap = 16 }, {
            ui.row({ align = "center", justify = "space_between", gap = 8}, {
                ui.label({ text = "Whos That Pokémon", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
                ui.button({ glyph = "close", controlSize = "sm",
                    onClick = "onCloseBtnClicked"
                })
            }),
            ui.row({ align = "center", justify = "center" }, {
                ui.image({ path = "./assets/sprites/trainerRed.png", width = 96, height = 96, fit = "contain" })
            }),
            ui.row({ align = "center", justify = "space_between" }, {
                ui.button({ text = noctalia.tr("play_btn"), flexGrow = 1,
                    onClick = "onPlayBtnClicked"
                })
            }),
            ui.row({ align = "center", justify = "center" }, {
                ui.label({ text = "v1.0.0" })
            })
        })
    )
end

function onBackToMenuBtnClicked()
    currentPageIndex = 0

    render()
end

function onPlayerAnswerInputChange(value)
    playerAnswer = value
end

function onPlayerAnswerSubmitBtnClicked()
    if string.lower(playerAnswer) == string.lower(pokemonData[randomPokemonId]) then
        isPlayerAnswerCorrect = true
    else
        isPlayerAnswerCorrect = false
    end
    
    render()
end

function onContinuePlayingBtnClicked()
    playerAnswer = ""
    isPlayerAnswerCorrect = nil

    render()
end

function renderGame()
    if isPlayerAnswerCorrect == true then
        panel.render(
            ui.column({ flexGrow = 1, gap = 16 }, {
                ui.row({ align = "center", justify = "space_between", gap = 8 }, {
                    ui.label({ text = "Whos That Pokémon ?", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
                    ui.button({ key = "backToMenuBtn", glyph = "arrow-left", controlSize = "sm",
                        onClick = "onBackToMenuBtnClicked"
                    })
                }),
                ui.row({ align = "center", justify = "center" }, {
                    ui.image({ path = string.format("./assets/sprites/%d.png", randomPokemonId), width = 128, height = 128, fit = "contain" })
                }),
                ui.row({ align = "center", justify = "space_between", gap = 8 }, {
                    ui.button({ key = "goodAnswerBtn", text = noctalia.tr("good_answer_btn"), controlSize = "md", flexGrow = 1, variant = "primary" }),
                    ui.button({ key = "continuePlayingBtn", glyph = "arrow-right", controlSize = "md",
                        onClick = "onContinuePlayingBtnClicked"
                    })
                })
            })
        )
    elseif isPlayerAnswerCorrect == false then
        panel.render(
            ui.column({ flexGrow = 1, gap = 16 }, {
                ui.row({ align = "center", justify = "space_between", gap = 8 }, {
                    ui.label({ text = "Whos That Pokémon ?", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
                    ui.button({ key = "backToMenuBtn", glyph = "arrow-left", controlSize = "sm",
                        onClick = "onBackToMenuBtnClicked"
                    })
                }),
                ui.row({ align = "center", justify = "center" }, {
                    ui.image({ path = string.format("./assets/sprites/%d.png", randomPokemonId), width = 128, height = 128, fit = "contain" })
                }),
                ui.row({ align = "center", justify = "space_between", gap = 8 }, {
                    ui.button({ key = "wrongAnswerBtn", text = noctalia.tr("wrong_answer_btn") .. " " .. pokemonData[randomPokemonId], controlSize = "md", flexGrow = 1, variant = "destructive" }),
                    ui.button({ key = "continuePlayingBtn", glyph = "arrow-right", controlSize = "md",
                        onClick = "onContinuePlayingBtnClicked"
                    })
                })
            })
        )
    else
        randomPokemonId = math.random(1, registeredPokemons)

        panel.render(
            ui.column({ flexGrow = 1, gap = 16 }, {
                ui.row({ align = "center", justify = "space_between", gap = 8 }, {
                    ui.label({ text = "Whos That Pokémon ?", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
                    ui.button({ key = "backToMenuBtn", glyph = "arrow-left", controlSize = "sm",
                        onClick = "onBackToMenuBtnClicked"
                    })
                }),
                ui.row({ align = "center", justify = "center" }, {
                    ui.image({ path = string.format("./assets/sprites/%d.png", randomPokemonId), width = 128, height = 128, fit = "contain" })
                }),
                ui.row({ align = "center", justify = "space_between", gap = 8 }, {
                    ui.input({ key = uuid(), placeholder = noctalia.tr("player_answer_input"), controlSize = "md", flexGrow = 1,
                        onChange = "onPlayerAnswerInputChange",
                        onSubmit = "onPlayerAnswerSubmitBtnClicked"
                    }),
                    ui.button({ key = "submitPlayerAnswerBtn", glyph = "send-2", controlSize = "md", flexGrow = 0,
                        onClick = "onPlayerAnswerSubmitBtnClicked"
                    })
                })
            })
        )  
    end
end

local pages = {
    [0] = renderMenu,
    [1] = renderGame
}

function render()
    local page = pages[currentPageIndex]

    if page then
        page()
    end
end

function onOpen()
    render()
end