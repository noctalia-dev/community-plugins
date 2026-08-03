local currentText = ""
local genCount = 0
local errorMessage = nil
local imagePath = nil
local status = "idle"

local imageSize = 400

local generateButton = noctalia.getConfig("generate_button")
local notifyConf = noctalia.getConfig("notify")

local function notify(text, error)
    local cmd = error and noctalia.notifyError or noctalia.notify
    cmd("QR Code encoder", text)
end

local function statusText()
    if status == "generating" then 
        return noctalia.tr("panel.status.generating")
    elseif status == "error" then 
        return noctalia.tr("panel.status.error", { message = errorMessage })
    elseif status == "ready" then 
        return noctalia.tr("panel.status.ready")
    elseif status == "copied" then 
        return noctalia.tr("panel.status.copied")
    else
        return noctalia.tr(generateButton and "panel.status.idle" or "panel.status.idlebis")
    end
end

local function render()
    local rowContent = {
        ui.input({
            flexGrow = 1,
            focus = true,
            placeholder = noctalia.tr("panel.placeholder"),
            onChange = "onTextChange",
            onSubmit = "onTextSubmit",
        })
    }

    if generateButton then
        table.insert(
            rowContent,
            ui.button({
                text = "Generate",
                variant = "primary",
                enabled = status ~= "generating",
                onClick = "onGenerateClick",
            })
        )
    end

    local content = {
        ui.row({ gap = 8 }, rowContent),
        ui.label({
            flexGrow = 1,
            textAlign = "center",
            text = statusText(),
            color = status == "error" and "error" or "on_surface/0.75",
        })
    }

    if (status == "ready" 
        or status == "copied"
        or (status == "error" and errorMessage == noctalia.tr("panel.error.copy_failed")))
        and imagePath ~= nil then
        table.insert(
            content,
            ui.row({ justify = "center" }, {
                ui.image({
                    path = imagePath,
                    width = imageSize,
                    height = imageSize,
                    radius = 24,
                    onClick = "onImageClick",
                })
            })
        )
    end

    if noctalia.getConfig("titlebar") then
        imageSize = 350
        table.insert(
            content, 1,
            ui.row({ align = "center", justify = "space_between", gap = 8 }, {
                ui.label({ text = "QR Code Encoder", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
                ui.button({ glyph = "settings", onClick = noctalia.openSettings }),
                ui.button({ glyph = "close", onClick = "onCloseClicked" }),
            })
        )
    end

    panel.render(ui.column({ flexGrow = 1, gap = 16 }, content))
end

local function shellEscape(raw)
    return "'" .. raw:gsub("'", "'\\''") .. "'"
end

local function generate(text)
    if status == "generating" then
        return
    end

    text = noctalia.string.trim(text or "")

    if text == "" then
        if imagePath ~= nil then
            noctalia.removeFile(imagePath)
        end
        status = "idle"
        errorMessage = nil
        imagePath = nil
        render()
        return
    end

    if not noctalia.commandExists("qrencode") then
        status = "error"
        errorMessage = noctalia.tr("panel.error.missing_qrencode")

        if notifyConf == "all" then
            notify(statusText(), status == "error")
        end

        render()
        return
    end

    status = "generating"
    render()

    local dir = noctalia.pluginDir()
    local outputPath = string.format("%s/qr-%s.png", dir, genCount)
    local previousPath = imagePath
    genCount += 1

    local size = noctalia.getConfig("size") or 8
    local correctionLevel = noctalia.getConfig("correction_level") or "M"

    local cmd = string.format(
        'qrencode %s -o %s -s %s -l %s',
        shellEscape(text),
        outputPath,
        size,
        correctionLevel
    )

    noctalia.runAsync(
        cmd,
        function(result)
            if result.exitCode == 0 and noctalia.fileExists(outputPath) then
                imagePath = outputPath
                status = "ready"
                if previousPath ~= nil then
                    noctalia.removeFile(previousPath)
                end
            else
                status = "error"
                errorMessage = noctalia.tr("panel.error.generate_failed")
            end

            if notifyConf == "all" then
                notify(statusText(), status == "error")
            end

            render()
        end
    )
end

function onOpen(_context)
    status = "idle"
    render()
end

function onTextChange(value)
    currentText = value
end

function onTextSubmit(value)
    currentText = value
    generate(currentText)
end

function onGenerateClick()
    generate(currentText)
end

function onImageClick()
    local bytes, err = noctalia.readFile(imagePath)
    errorMessage = noctalia.tr("panel.error.copy_failed")

    if bytes == nil then
        status = "error"
    else
        local ok = noctalia.copyToClipboard(bytes, "image/png")

        status = ok and "copied" or "error"
    end

    if notifyConf == "all" then
        notify(statusText(), status == "error")
    end

    if noctalia.getConfig("close_on_copy") then
        if notifyConf == "minimal" then
            notify(statusText(), status == "error")
        end

        panel.close()
        return
    end

    render()
end

function onCloseClicked()
    panel.close()
end

function onClose()
    if imagePath ~= nil then
        noctalia.removeFile(imagePath)
    end
end
